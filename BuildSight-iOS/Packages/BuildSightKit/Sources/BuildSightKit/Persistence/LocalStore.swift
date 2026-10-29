import Foundation
import CoreData

/// A record write, plus whether it must be pushed to the server. Records that
/// arrive FROM the server are saved with `enqueue: false`.
public struct RecordWrite: Sendable {
    public var recordType: RecordType
    public var recordID: UUID
    public var projectID: UUID
    /// Optional owning record (issue for an event, photo for an analysis) so
    /// relationship queries are an indexed lookup rather than a scan.
    public var parentID: UUID?
    public var sortDate: Date
    public var updatedAt: Date
    public var payload: Data
    public var serverVersion: Int
    public var enqueue: Bool
    public var baseSnapshot: Data?
    public var localFilename: String?

    /// A record received from the server: saved as Synced, never queued.
    public init(remote r: RemoteRecord) {
        recordType = r.type; recordID = r.id; projectID = r.projectID; parentID = r.parentID
        sortDate = r.sortDate; updatedAt = r.updatedAt; payload = r.payload
        serverVersion = r.serverVersion; enqueue = false; baseSnapshot = nil; localFilename = nil
    }

    public init<T: SyncableRecord>(_ record: T, parentID: UUID? = nil, sortDate: Date, previous: T? = nil, enqueue: Bool = true, localFilename: String? = nil) throws {
        let encoder = RecordCodec.makeEncoder()
        self.recordType = T.recordType
        self.recordID = record.id
        self.projectID = record.projectID
        self.parentID = parentID
        self.sortDate = sortDate
        self.updatedAt = record.updatedAt
        self.payload = try encoder.encode(record)
        self.serverVersion = record.serverVersion
        self.enqueue = enqueue
        self.baseSnapshot = try previous.map { try encoder.encode($0) }
        self.localFilename = localFilename
    }
}

public struct SyncSummary: Equatable, Sendable {
    public var pending = 0
    public var uploading = 0
    public var failed = 0
    public var total: Int { pending + uploading + failed }
}

public struct SyncQueueItem: Identifiable, Equatable, Sendable {
    public var id: UUID { operation.id }
    public var operation: PendingOperation
}

/// Local-first persistence boundary. Repositories talk to this protocol; the
/// Core Data implementation below is one of two (tests use the same one with an
/// in-memory store, so there is no hand-written fake to drift from reality).
public protocol LocalStore: SyncQueueStore {
    /// Writes records and their queue entries in ONE save, so a record can
    /// never exist without the operation that will sync it.
    func commit(_ writes: [RecordWrite]) async throws
    func record<T: SyncableRecord>(_ type: T.Type, id: UUID) async throws -> T?
    func records<T: SyncableRecord>(_ type: T.Type, projectID: UUID, parentID: UUID?) async throws -> [T]
    func syncState(of recordID: UUID) async throws -> SyncState?
    /// Server version this device holds for a record, nil if unknown.
    func knownVersion(type: RecordType, id: UUID) async throws -> Int?
    func syncSummary(projectID: UUID?) async throws -> SyncSummary
    func discardOperation(_ operationID: UUID) async throws
    func saveDraft(_ draft: IssueDraft) async throws
    func drafts(projectID: UUID) async throws -> [IssueDraft]
    func deleteDraft(_ id: UUID) async throws
    /// Emits whenever data changes, so view models reload instead of polling.
    func changes() -> AsyncStream<Void>
}

public extension LocalStore {
    func records<T: SyncableRecord>(_ type: T.Type, projectID: UUID) async throws -> [T] {
        try await records(type, projectID: projectID, parentID: nil)
    }
}
