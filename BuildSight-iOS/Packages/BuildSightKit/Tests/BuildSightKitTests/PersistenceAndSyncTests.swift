import Testing
import Foundation
@testable import BuildSightKit

/// Scripted backend: each call pops the next scripted result, and every call is recorded.
final class FakeBackend: RemoteBackend, @unchecked Sendable {
    enum Step { case ok(Int), fail(RemoteError) }
    private let lock = NSLock()
    private var script: [Step]
    private(set) var upserts: [PendingOperation] = []
    private(set) var uploads: [UUID] = []
    var uploadFailures = 0

    init(_ script: [Step]) { self.script = script }

    func upsert(_ operation: PendingOperation, objectPath: String?) async throws -> RemoteAck {
        lock.lock(); defer { lock.unlock() }
        upserts.append(operation)
        let step = script.isEmpty ? .ok(1) : script.removeFirst()
        switch step {
        case .ok(let v): return RemoteAck(serverVersion: v)
        case .fail(let e): throw e
        }
    }

    func uploadEvidence(projectID: UUID, photoID: UUID, localFilename: String) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        if uploadFailures > 0 { uploadFailures -= 1; throw RemoteError.transient("upload dropped") }
        uploads.append(photoID)
        return "\(projectID)/\(photoID).jpg"
    }
}

/// Clock the engine reads, so backoff tests advance time explicitly.
final class TestClock: @unchecked Sendable {
    var now = Fixture.now
    func read() -> Date { now }
}

@Suite("Core Data persistence")
struct PersistenceTests {
    @Test("Saved records are readable back, scoped to their project")
    func roundTripAndIsolation() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let a = Fixture.issue(project: Fixture.projectA)
        let b = Fixture.issue(project: Fixture.projectB)
        try await store.commit([try RecordWrite(a, sortDate: a.createdAt), try RecordWrite(b, sortDate: b.createdAt)])

        let inA = try await store.records(Issue.self, projectID: Fixture.projectA)
        let inB = try await store.records(Issue.self, projectID: Fixture.projectB)
        #expect(inA.map(\.id) == [a.id])
        #expect(inB.map(\.id) == [b.id])
        #expect(try await store.record(Issue.self, id: a.id) == a)
    }

    @Test("Data survives closing and reopening the SQLite store")
    func survivesRelaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bs-\(UUID().uuidString).sqlite")
        defer { ["", "-shm", "-wal"].forEach { try? FileManager.default.removeItem(atPath: url.path + $0) } }
        let issue = Fixture.issue(status: .inProgress)
        do {
            let first = try CoreDataLocalStore(storeURL: url)
            try await first.commit([try RecordWrite(issue, sortDate: issue.createdAt)])
        }
        let second = try CoreDataLocalStore(storeURL: url)
        #expect(try await second.record(Issue.self, id: issue.id)?.status == .inProgress)
        #expect(try await second.pendingOperations().count == 1)   // the queue is persistent too
    }

    @Test("A write and its queue entry are created together; later edits coalesce into one operation")
    func coalescing() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        var issue = Fixture.issue()
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt)])
        let original = issue
        issue.title = "Edited once"
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt, previous: original)])
        issue.title = "Edited twice"
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt, previous: original)])

        let ops = try await store.pendingOperations()
        #expect(ops.count == 1)
        let payload = try RecordCodec.makeDecoder().decode(Issue.self, from: ops[0].payload)
        #expect(payload.title == "Edited twice")
        #expect(try await store.syncState(of: issue.id) == .pending)
    }

    @Test("Records saved from the server do not enter the queue and show as synced")
    func serverRecordsNotQueued() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let issue = Fixture.issue()
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt, enqueue: false)])
        #expect(try await store.pendingOperations().isEmpty)
        #expect(try await store.syncState(of: issue.id) == .synced)
    }

    @Test("Drafts persist separately and never enter the sync queue")
    func drafts() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let draft = IssueDraft(projectID: Fixture.projectA, title: "Half written", savedAt: Fixture.now)
        try await store.saveDraft(draft)
        #expect(try await store.drafts(projectID: Fixture.projectA).map(\.title) == ["Half written"])
        #expect(try await store.drafts(projectID: Fixture.projectB).isEmpty)
        #expect(try await store.pendingOperations().isEmpty)
        try await store.deleteDraft(draft.id)
        #expect(try await store.drafts(projectID: Fixture.projectA).isEmpty)
    }
}

@Suite("Sync engine")
struct SyncEngineTests {
    private func seeded() async throws -> (CoreDataLocalStore, Issue) {
        let store = try CoreDataLocalStore(storeURL: nil)
        let issue = Fixture.issue()
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt)])
        return (store, issue)
    }

    @Test("A successful drain empties the queue and only then marks the record Synced")
    func successMarksSynced() async throws {
        let (store, issue) = try await seeded()
        #expect(try await store.syncState(of: issue.id) == .pending)   // not synced before the call
        let engine = SyncEngine(store: store, backend: FakeBackend([.ok(7)]))
        let report = await engine.drain()
        #expect(report.completed == 1)
        #expect(try await store.syncState(of: issue.id) == .synced)
        #expect(try await store.record(Issue.self, id: issue.id)?.serverVersion == 7)
        #expect(try await store.pendingOperations().isEmpty)
    }

    @Test("Offline stops the drain, keeps the record pending-retry and never shows Synced")
    func offlineKeepsRecord() async throws {
        let (store, issue) = try await seeded()
        let clock = TestClock()
        let engine = SyncEngine(store: store, backend: FakeBackend([.fail(.offline)]), clock: { clock.read() })
        let report = await engine.drain()
        #expect(report.stoppedOffline && report.completed == 0)
        #expect(try await store.syncState(of: issue.id) == .failed)
        #expect(try await store.record(Issue.self, id: issue.id) != nil)   // the record is never lost
        let op = try #require(try await store.pendingOperations().first)
        #expect(op.attempts == 1 && op.state == .pending)
        #expect(op.nextAttemptAt == clock.now.addingTimeInterval(5))
    }

    @Test("Retries respect backoff: too early does nothing, once due it succeeds")
    func backoff() async throws {
        let (store, issue) = try await seeded()
        let clock = TestClock()
        let backend = FakeBackend([.fail(.transient("503")), .ok(2)])
        let engine = SyncEngine(store: store, backend: backend, clock: { clock.read() })
        _ = await engine.drain()
        #expect(backend.upserts.count == 1)

        clock.now.addTimeInterval(2)                          // before the 5 s backoff
        _ = await engine.drain()
        #expect(backend.upserts.count == 1)

        clock.now.addTimeInterval(10)                         // due
        let report = await engine.drain()
        #expect(report.completed == 1)
        #expect(try await store.syncState(of: issue.id) == .synced)
    }

    @Test("Backoff doubles per attempt and is capped")
    func backoffCurve() {
        #expect(SyncEngine.backoff(afterAttempt: 1) == 5)
        #expect(SyncEngine.backoff(afterAttempt: 2) == 10)
        #expect(SyncEngine.backoff(afterAttempt: 3) == 20)
        #expect(SyncEngine.backoff(afterAttempt: 30) == 900)
    }

    @Test("Retrying after a lost response resends the SAME operation id, which is the server's duplicate key")
    func idempotencyKeyStable() async throws {
        let (store, _) = try await seeded()
        let clock = TestClock()
        let backend = FakeBackend([.fail(.transient("timeout after server processed it")), .ok(1)])
        let engine = SyncEngine(store: store, backend: backend, clock: { clock.read() })
        _ = await engine.drain()
        clock.now.addTimeInterval(60)
        _ = await engine.drain()
        #expect(backend.upserts.count == 2)
        #expect(backend.upserts[0].id == backend.upserts[1].id)
        #expect(backend.upserts[0].recordID == backend.upserts[1].recordID)
    }

    @Test("A rejected record is parked as failed, not retried automatically, and can be retried by the user")
    func rejected() async throws {
        let (store, issue) = try await seeded()
        let backend = FakeBackend([.fail(.rejected("Not a member of this project")), .ok(1)])
        let engine = SyncEngine(store: store, backend: backend)
        let first = await engine.drain()
        #expect(first.failedPermanently == 1)
        #expect(try await store.syncState(of: issue.id) == .failed)
        _ = await engine.drain()
        #expect(backend.upserts.count == 1)                   // no automatic retry

        let op = try #require(try await store.pendingOperations().first)
        #expect(op.lastError == "Not a member of this project")
        await engine.retry(op.id)
        let second = await engine.drain()
        #expect(second.completed == 1)
        #expect(try await store.syncState(of: issue.id) == .synced)
    }

    @Test("Expired session halts syncing and leaves everything queued")
    func authExpiry() async throws {
        let (store, issue) = try await seeded()
        let engine = SyncEngine(store: store, backend: FakeBackend([.fail(.unauthorized)]))
        let report = await engine.drain()
        #expect(report.authExpired)
        #expect(try await store.pendingOperations().count == 1)
        #expect(try await store.syncState(of: issue.id) == .pending)
    }

    @Test("A photo whose upsert failed after the file uploaded does not upload the file again")
    func partialUploadResumes() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let photo = Fixture.photo()
        try await store.commit([try RecordWrite(photo, sortDate: photo.capturedAt, localFilename: photo.localFilename)])
        let clock = TestClock()
        let backend = FakeBackend([.fail(.transient("db down")), .ok(1)])
        let engine = SyncEngine(store: store, backend: backend, clock: { clock.read() })

        _ = await engine.drain()
        #expect(backend.uploads == [photo.id])
        #expect(try await store.pendingOperations().first?.uploadedObjectPath != nil)

        clock.now.addTimeInterval(60)
        _ = await engine.drain()
        #expect(backend.uploads == [photo.id])                // still one upload
        #expect(backend.upserts.last?.uploadedObjectPath != nil)
        #expect(try await store.syncState(of: photo.id) == .synced)
    }

    @Test("A failed file upload leaves the photo record local and retryable")
    func uploadFailure() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let photo = Fixture.photo()
        try await store.commit([try RecordWrite(photo, sortDate: photo.capturedAt, localFilename: photo.localFilename)])
        let backend = FakeBackend([])
        backend.uploadFailures = 1
        let engine = SyncEngine(store: store, backend: backend)
        let report = await engine.drain()
        #expect(report.retryScheduled == 1 && backend.upserts.isEmpty)
        #expect(try await store.record(EvidencePhoto.self, id: photo.id) != nil)
    }

    @Test("Concurrent drains do not send the same operation twice")
    func noOverlappingDrains() async throws {
        let (store, _) = try await seeded()
        let backend = FakeBackend([.ok(1)])
        let engine = SyncEngine(store: store, backend: backend)
        async let a = engine.drain()
        async let b = engine.drain()
        _ = await (a, b)
        #expect(backend.upserts.count == 1)
    }

    @Test("A conflict merges non-overlapping edits and lets the server win overlapping ones")
    func conflictMerge() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let base = Fixture.issue()
        try await store.commit([try RecordWrite(base, sortDate: base.createdAt, enqueue: false)])

        var local = base
        local.title = "Local title"            // only we change this
        local.priority = .critical             // both change this, differently
        try await store.commit([try RecordWrite(local, sortDate: local.createdAt, previous: base)])

        var remote = base
        remote.priority = .low
        remote.details = "Server details"      // only the server changes this
        remote.serverVersion = 5
        let serverJSON = try RecordCodec.makeEncoder().encode(remote)

        let backend = FakeBackend([.fail(.conflict(serverRecord: serverJSON, serverVersion: 5)), .ok(6)])
        let engine = SyncEngine(store: store, backend: backend)
        let report = await engine.drain()
        #expect(report.completed == 1)

        let merged = try #require(try await store.record(Issue.self, id: base.id))
        #expect(merged.title == "Local title")
        #expect(merged.details == "Server details")
        #expect(merged.priority == .low)
        #expect(merged.serverVersion == 6)
        #expect(try await store.syncState(of: base.id) == .synced)
        #expect(backend.upserts.last?.baseVersion == 5)
    }
}

@Suite("Conflict resolver")
struct ConflictResolverTests {
    private func obj(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }

    @Test("Three-way merge rules")
    func rules() throws {
        let base = obj(["a": .string("1"), "b": .string("1"), "c": .string("1"), "d": .string("1"), "serverVersion": .number(1)])
        let local = obj(["a": .string("L"), "b": .string("1"), "c": .string("L"), "d": .string("same"), "serverVersion": .number(1)])
        let remote = obj(["a": .string("1"), "b": .string("R"), "c": .string("R"), "d": .string("same"), "serverVersion": .number(4)])
        let out = try #require(ConflictResolver.merge(base: base, local: local, remote: remote))
        let m = try #require(out.merged.objectValue)
        #expect(m["a"] == .string("L"))       // only local changed
        #expect(m["b"] == .string("R"))       // only remote changed
        #expect(m["c"] == .string("R"))       // both changed: server wins
        #expect(m["d"] == .string("same"))    // identical change
        #expect(m["serverVersion"] == .number(4))
        #expect(out.conflictedFields == ["c"])
    }
}

struct StaticPuller: RemotePuller {
    var records: [RemoteRecord]
    func fetchChanges(projectID: UUID, since: Date?) async throws -> [RemoteRecord] { records }
}

@Suite("Pull sync")
struct PullServiceTests {
    private func remote(_ issue: Issue, version: Int) throws -> RemoteRecord {
        var copy = issue; copy.serverVersion = version
        return RemoteRecord(type: .issue, id: issue.id, projectID: issue.projectID, parentID: nil, sortDate: issue.createdAt, updatedAt: issue.updatedAt, serverVersion: version, payload: try RecordCodec.makeEncoder().encode(copy))
    }

    @Test("New server records are stored as Synced and are not queued for upload")
    func appliesNew() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let issue = Fixture.issue()
        let report = try await PullService(store: store, remote: StaticPuller(records: [try remote(issue, version: 3)])).pull(projectID: Fixture.projectA, since: nil)
        #expect(report.applied == 1)
        #expect(try await store.syncState(of: issue.id) == .synced)
        #expect(try await store.pendingOperations().isEmpty)
    }

    @Test("A record with an unsynced local edit is not overwritten by a pull")
    func protectsLocalEdits() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        var local = Fixture.issue(); local.title = "My offline edit"
        try await store.commit([try RecordWrite(local, sortDate: local.createdAt)])
        let report = try await PullService(store: store, remote: StaticPuller(records: [try remote(Fixture.issue(), version: 9).with(id: local.id)])).pull(projectID: Fixture.projectA, since: nil)
        #expect(report.skippedLocalEdits == 1 && report.applied == 0)
        #expect(try await store.record(Issue.self, id: local.id)?.title == "My offline edit")
    }

    @Test("Stale server versions are ignored and rows from another project are rejected")
    func staleAndForeign() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let issue = Fixture.issue()
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt, enqueue: false)])
        let foreign = Fixture.issue(project: Fixture.projectB)
        let puller = StaticPuller(records: [try remote(issue, version: 0), try remote(foreign, version: 1)])
        let report = try await PullService(store: store, remote: puller).pull(projectID: Fixture.projectA, since: nil)
        #expect(report.applied == 0 && report.skippedStale == 1)
        #expect(try await store.record(Issue.self, id: foreign.id) == nil)
    }
}

private extension RemoteRecord {
    func with(id: UUID) -> RemoteRecord { var r = self; r.id = id; return r }
}
