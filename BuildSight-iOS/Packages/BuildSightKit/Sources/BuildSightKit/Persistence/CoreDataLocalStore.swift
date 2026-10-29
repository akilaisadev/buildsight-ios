import Foundation
import CoreData

/// Core Data implementation of `LocalStore`.
///
/// Design choice worth defending in the viva: records are stored as a Codable
/// payload plus a handful of indexed columns (type, project, parent, sort date,
/// sync state), instead of one Core Data entity per record type. Every query the
/// app needs filters on those columns, the payload decodes into the same Swift
/// types the rest of the app uses, and adding a field to a record needs no
/// store migration. The cost is that Core Data cannot join across records, so
/// relationships are explicit IDs resolved in repositories.
///
/// The managed object model is built in code (not an .xcdatamodeld) so the
/// package compiles and is testable with plain `swiftc`/SwiftPM.
public final class CoreDataLocalStore: LocalStore, @unchecked Sendable {
    private let container: NSPersistentContainer
    private let broadcaster = ChangeBroadcaster()

    /// - Parameter storeURL: nil gives an in-memory store (tests, previews).
    ///   Production passes a per-account file, so one account's records are
    ///   physically separate from another's on a shared device.
    public init(storeURL: URL?) throws {
        let model = Self.makeModel()
        container = NSPersistentContainer(name: "BuildSight", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        if let storeURL {
            description.url = storeURL
            description.type = NSSQLiteStoreType
            // Evidence metadata is not secret on its own, but records should not
            // be readable while the device is locked and the app is backgrounded.
            #if os(iOS)
            description.setOption(FileProtectionType.completeUntilFirstUserAuthentication as NSObject, forKey: NSPersistentStoreFileProtectionKey)
            #endif
        } else {
            description.type = NSInMemoryStoreType
        }
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    // MARK: - Model

    private enum E {
        static let record = "RecordEntity"
        static let operation = "OperationEntity"
        static let draft = "DraftEntity"
    }

    private static func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false, default value: Any? = nil) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = type
        a.isOptional = optional
        a.defaultValue = value
        return a
    }

    static func makeModel() -> NSManagedObjectModel {
        let record = NSEntityDescription()
        record.name = E.record
        record.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        record.properties = [
            attribute("type", .stringAttributeType),
            attribute("id", .UUIDAttributeType),
            attribute("projectID", .UUIDAttributeType),
            attribute("parentID", .UUIDAttributeType, optional: true),
            attribute("sortDate", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
            attribute("syncState", .stringAttributeType, default: SyncState.pending.rawValue),
            attribute("serverVersion", .integer64AttributeType, default: 0),
            attribute("payload", .binaryDataAttributeType),
        ]
        let byProject = NSFetchIndexDescription(name: "byTypeProjectDate", elements: ["type", "projectID", "sortDate"].map {
            NSFetchIndexElementDescription(property: record.propertiesByName[$0]!, collationType: .binary)
        })
        let byParent = NSFetchIndexDescription(name: "byTypeParent", elements: ["type", "parentID"].map {
            NSFetchIndexElementDescription(property: record.propertiesByName[$0]!, collationType: .binary)
        })
        record.indexes = [byProject, byParent]
        record.uniquenessConstraints = [["type", "id"]]

        let operation = NSEntityDescription()
        operation.name = E.operation
        operation.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        operation.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("createdAt", .dateAttributeType),
            attribute("recordID", .UUIDAttributeType),
            attribute("projectID", .UUIDAttributeType),
            attribute("body", .binaryDataAttributeType),   // the full PendingOperation, JSON
        ]
        operation.uniquenessConstraints = [["id"]]

        let draft = NSEntityDescription()
        draft.name = E.draft
        draft.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        draft.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("projectID", .UUIDAttributeType),
            attribute("savedAt", .dateAttributeType),
            attribute("body", .binaryDataAttributeType),
        ]
        draft.uniquenessConstraints = [["id"]]

        let model = NSManagedObjectModel()
        model.entities = [record, operation, draft]
        return model
    }

    // MARK: - Helpers

    private func perform<T>(_ work: @escaping @Sendable (NSManagedObjectContext) throws -> T) async throws -> T {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        return try await context.perform { try work(context) }
    }

    private func recordObject(type: RecordType, id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: E.record)
        request.predicate = NSPredicate(format: "type == %@ AND id == %@", type.rawValue, id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func operationObject(id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: E.operation)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func decodeOperation(_ object: NSManagedObject) throws -> PendingOperation {
        guard let body = object.value(forKey: "body") as? Data else { throw StoreError.corrupt }
        return try RecordCodec.makeDecoder().decode(PendingOperation.self, from: body)
    }

    private func write(_ operation: PendingOperation, to object: NSManagedObject) throws {
        object.setValue(operation.id, forKey: "id")
        object.setValue(operation.createdAt, forKey: "createdAt")
        object.setValue(operation.recordID, forKey: "recordID")
        object.setValue(operation.projectID, forKey: "projectID")
        object.setValue(try RecordCodec.makeEncoder().encode(operation), forKey: "body")
    }

    public enum StoreError: Error { case corrupt, missingRecord }

    // MARK: - LocalStore

    public func commit(_ writes: [RecordWrite]) async throws {
        try await perform { context in
            for w in writes {
                let object = try self.recordObject(type: w.recordType, id: w.recordID, in: context)
                    ?? NSEntityDescription.insertNewObject(forEntityName: E.record, into: context)
                object.setValue(w.recordType.rawValue, forKey: "type")
                object.setValue(w.recordID, forKey: "id")
                object.setValue(w.projectID, forKey: "projectID")
                object.setValue(w.parentID, forKey: "parentID")
                object.setValue(w.sortDate, forKey: "sortDate")
                object.setValue(w.updatedAt, forKey: "updatedAt")
                object.setValue(w.payload, forKey: "payload")
                object.setValue(Int64(w.serverVersion), forKey: "serverVersion")
                object.setValue((w.enqueue ? SyncState.pending : SyncState.synced).rawValue, forKey: "syncState")

                guard w.enqueue else { continue }
                try self.enqueue(w, in: context)
            }
            try context.save()
        }
        broadcaster.send()
    }

    /// Coalesces with a not-yet-started operation for the same record: the
    /// latest payload replaces the old one but the ORIGINAL base snapshot is
    /// kept, so a record edited five times offline syncs once, and the merge
    /// still compares against what the server last confirmed.
    private func enqueue(_ w: RecordWrite, in context: NSManagedObjectContext) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: E.operation)
        request.predicate = NSPredicate(format: "recordID == %@", w.recordID as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let existing = try context.fetch(request)
            .compactMap { obj in (try? decodeOperation(obj)).map { (obj, $0) } }
            .first { $0.1.state == .pending || $0.1.state == .failed }

        if let (object, existingOp) = existing {
            var op = existingOp
            op.payload = w.payload
            op.parentID = w.parentID
            op.sortDate = w.sortDate
            op.state = .pending
            op.nextAttemptAt = nil
            op.lastError = nil
            op.attempts = 0
            try write(op, to: object)
        } else {
            let op = PendingOperation(
                recordType: w.recordType, recordID: w.recordID, projectID: w.projectID,
                payload: w.payload, baseSnapshot: w.baseSnapshot, baseVersion: w.serverVersion,
                createdAt: w.updatedAt, localFilename: w.localFilename,
                parentID: w.parentID, sortDate: w.sortDate
            )
            try write(op, to: NSEntityDescription.insertNewObject(forEntityName: E.operation, into: context))
        }
    }

    public func record<T: SyncableRecord>(_ type: T.Type, id: UUID) async throws -> T? {
        try await perform { context in
            guard let object = try self.recordObject(type: T.recordType, id: id, in: context),
                  let payload = object.value(forKey: "payload") as? Data else { return nil }
            return try RecordCodec.makeDecoder().decode(T.self, from: payload)
        }
    }

    public func records<T: SyncableRecord>(_ type: T.Type, projectID: UUID, parentID: UUID?) async throws -> [T] {
        try await perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: E.record)
            var format = "type == %@ AND projectID == %@"
            var args: [Any] = [T.recordType.rawValue, projectID as CVarArg]
            if let parentID { format += " AND parentID == %@"; args.append(parentID as CVarArg) }
            request.predicate = NSPredicate(format: format, argumentArray: args)
            request.sortDescriptors = [NSSortDescriptor(key: "sortDate", ascending: false)]
            let decoder = RecordCodec.makeDecoder()
            return try context.fetch(request).compactMap { obj in
                (obj.value(forKey: "payload") as? Data).flatMap { try? decoder.decode(T.self, from: $0) }
            }
        }
    }

    public func syncState(of recordID: UUID) async throws -> SyncState? {
        try await perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: E.record)
            request.predicate = NSPredicate(format: "id == %@", recordID as CVarArg)
            request.fetchLimit = 1
            return (try context.fetch(request).first?.value(forKey: "syncState") as? String).flatMap(SyncState.init(rawValue:))
        }
    }

    public func knownVersion(type: RecordType, id: UUID) async throws -> Int? {
        try await perform { context in
            (try self.recordObject(type: type, id: id, in: context)?.value(forKey: "serverVersion") as? Int64).map(Int.init)
        }
    }

    public func syncSummary(projectID: UUID?) async throws -> SyncSummary {
        try await perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: E.record)
            if let projectID { request.predicate = NSPredicate(format: "projectID == %@ AND syncState != %@", projectID as CVarArg, SyncState.synced.rawValue) }
            else { request.predicate = NSPredicate(format: "syncState != %@", SyncState.synced.rawValue) }
            var summary = SyncSummary()
            for obj in try context.fetch(request) {
                switch (obj.value(forKey: "syncState") as? String).flatMap(SyncState.init(rawValue:)) {
                case .pending: summary.pending += 1
                case .uploading: summary.uploading += 1
                case .failed: summary.failed += 1
                default: break
                }
            }
            return summary
        }
    }

    // MARK: - SyncQueueStore

    public func pendingOperations() async throws -> [PendingOperation] {
        try await perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: E.operation)
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            return try context.fetch(request).map { try self.decodeOperation($0) }
        }
    }

    public func update(_ operation: PendingOperation) async throws {
        try await perform { context in
            guard let object = try self.operationObject(id: operation.id, in: context) else { return }
            try self.write(operation, to: object)
            try context.save()
        }
        broadcaster.send()
    }

    public func complete(_ operation: PendingOperation, serverVersion: Int) async throws {
        try await perform { context in
            if let object = try self.operationObject(id: operation.id, in: context) { context.delete(object) }
            if let record = try self.recordObject(type: operation.recordType, id: operation.recordID, in: context) {
                // A newer local edit may have queued another operation for this
                // record while this one was in flight; only mark Synced if none remain.
                let request = NSFetchRequest<NSManagedObject>(entityName: E.operation)
                request.predicate = NSPredicate(format: "recordID == %@ AND id != %@", operation.recordID as CVarArg, operation.id as CVarArg)
                let stillQueued = try context.count(for: request) > 0
                if !stillQueued {
                    record.setValue(SyncState.synced.rawValue, forKey: "syncState")
                    record.setValue(Int64(serverVersion), forKey: "serverVersion")
                    // Keep the payload's own serverVersion consistent with the column.
                    if let data = record.value(forKey: "payload") as? Data, var json = try? JSONValue.parse(data).objectValue {
                        json["serverVersion"] = .number(Double(serverVersion))
                        record.setValue(try JSONValue.object(json).data(), forKey: "payload")
                    }
                }
            }
            try context.save()
        }
        broadcaster.send()
    }

    public func applyMerge(for operation: PendingOperation, mergedPayload: Data, serverVersion: Int, conflictedFields: [String]) async throws {
        try await perform { context in
            if let object = try self.operationObject(id: operation.id, in: context) { context.delete(object) }
            if let record = try self.recordObject(type: operation.recordType, id: operation.recordID, in: context) {
                var payload = mergedPayload
                if var json = try? JSONValue.parse(mergedPayload).objectValue {
                    json["serverVersion"] = .number(Double(serverVersion))   // the ack, not the pre-merge copy
                    payload = try JSONValue.object(json).data()
                }
                record.setValue(payload, forKey: "payload")
                record.setValue(Int64(serverVersion), forKey: "serverVersion")
                record.setValue(SyncState.synced.rawValue, forKey: "syncState")
            }
            try context.save()
        }
        broadcaster.send()
    }

    public func markRecordState(_ operation: PendingOperation, state: SyncState) async throws {
        try await perform { context in
            guard let record = try self.recordObject(type: operation.recordType, id: operation.recordID, in: context) else { return }
            record.setValue(state.rawValue, forKey: "syncState")
            try context.save()
        }
        broadcaster.send()
    }

    public func discardOperation(_ operationID: UUID) async throws {
        try await perform { context in
            if let object = try self.operationObject(id: operationID, in: context) { context.delete(object) }
            try context.save()
        }
        broadcaster.send()
    }

    // MARK: - Drafts

    public func saveDraft(_ draft: IssueDraft) async throws {
        try await perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: E.draft)
            request.predicate = NSPredicate(format: "id == %@", draft.id as CVarArg)
            let object = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(forEntityName: E.draft, into: context)
            object.setValue(draft.id, forKey: "id")
            object.setValue(draft.projectID, forKey: "projectID")
            object.setValue(draft.savedAt, forKey: "savedAt")
            object.setValue(try RecordCodec.makeEncoder().encode(draft), forKey: "body")
            try context.save()
        }
        broadcaster.send()
    }

    public func drafts(projectID: UUID) async throws -> [IssueDraft] {
        try await perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: E.draft)
            request.predicate = NSPredicate(format: "projectID == %@", projectID as CVarArg)
            request.sortDescriptors = [NSSortDescriptor(key: "savedAt", ascending: false)]
            let decoder = RecordCodec.makeDecoder()
            return try context.fetch(request).compactMap { ($0.value(forKey: "body") as? Data).flatMap { try? decoder.decode(IssueDraft.self, from: $0) } }
        }
    }

    public func deleteDraft(_ id: UUID) async throws {
        try await perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: E.draft)
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            for object in try context.fetch(request) { context.delete(object) }
            try context.save()
        }
        broadcaster.send()
    }

    public func changes() -> AsyncStream<Void> { broadcaster.stream() }
}

/// Fan-out of "something changed" signals to any number of observers.
final class ChangeBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    func stream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock(); continuations[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock(); self?.continuations[id] = nil; self?.lock.unlock()
            }
        }
    }

    func send() {
        lock.lock(); let all = Array(continuations.values); lock.unlock()
        all.forEach { $0.yield() }
    }
}
