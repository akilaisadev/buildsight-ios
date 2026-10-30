import Testing
import Foundation
@testable import BuildSightKit

@Suite("Discarding a queued change")
struct DiscardTests {
    private func firstOperationID(_ store: CoreDataLocalStore) async throws -> UUID {
        try #require(try await store.pendingOperations().first).id
    }

    @Test("A brand-new record that never reached the server is removed")
    func newRecordIsRemoved() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let issue = Fixture.issue()
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt)])
        try await store.discardOperation(try await firstOperationID(store))
        #expect(try await store.record(Issue.self, id: issue.id) == nil)
        #expect(try await store.pendingOperations().isEmpty)
        #expect(try await store.syncSummary(projectID: nil).total == 0)
    }

    @Test("An edit goes back to what the server last confirmed")
    func editIsReverted() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        var confirmed = Fixture.issue()
        confirmed.serverVersion = 3
        try await store.commit([try RecordWrite(confirmed, sortDate: confirmed.createdAt, enqueue: false)])

        var edited = confirmed
        edited.title = "Edited offline"
        try await store.commit([try RecordWrite(edited, sortDate: edited.createdAt, previous: confirmed)])
        #expect(try await store.record(Issue.self, id: confirmed.id)?.title == "Edited offline")
        #expect(try await store.syncState(of: confirmed.id) == .pending)

        try await store.discardOperation(try await firstOperationID(store))
        let back = try #require(try await store.record(Issue.self, id: confirmed.id))
        #expect(back.title == confirmed.title)
        #expect(back.serverVersion == 3)
        #expect(try await store.syncState(of: confirmed.id) == .synced)
        #expect(try await store.syncSummary(projectID: nil).total == 0)
    }

    @Test("Five offline edits are all undone together")
    func manyEditsUndone() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        var confirmed = Fixture.issue(); confirmed.serverVersion = 1
        try await store.commit([try RecordWrite(confirmed, sortDate: confirmed.createdAt, enqueue: false)])
        var current = confirmed
        for n in 1...5 {
            var next = current; next.title = "Edit \(n)"
            try await store.commit([try RecordWrite(next, sortDate: next.createdAt, previous: current)])
            current = next
        }
        try await store.discardOperation(try await firstOperationID(store))
        #expect(try await store.record(Issue.self, id: confirmed.id)?.title == confirmed.title)
    }

    @Test("Only the discarded change is undone; other pending changes stay queued")
    func othersUntouched() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let first = Fixture.issue(), second = Fixture.issue()
        try await store.commit([try RecordWrite(first, sortDate: first.createdAt), try RecordWrite(second, sortDate: second.createdAt)])
        let target = try #require(try await store.pendingOperations().first { $0.recordID == first.id })
        try await store.discardOperation(target.id)
        #expect(try await store.record(Issue.self, id: first.id) == nil)
        #expect(try await store.record(Issue.self, id: second.id) != nil)
        #expect(try await store.pendingOperations().map(\.recordID) == [second.id])
        #expect(try await store.syncState(of: second.id) == .pending)
    }

    @Test("Discarding an unknown change changes nothing")
    func unknownIsHarmless() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let issue = Fixture.issue()
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt)])
        try await store.discardOperation(UUID())
        #expect(try await store.record(Issue.self, id: issue.id) != nil)
        #expect(try await store.pendingOperations().count == 1)
    }

    @Test("A change the server rejected can be discarded too")
    func failedChange() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let issue = Fixture.issue()
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt)])
        let engine = SyncEngine(store: store, backend: FakeBackend([.fail(.rejected("no"))]), clock: { Fixture.now })
        _ = await engine.drain()
        #expect(try await store.syncSummary(projectID: nil).failed == 1)
        try await store.discardOperation(try await firstOperationID(store))
        #expect(try await store.syncSummary(projectID: nil).total == 0)
        #expect(try await store.record(Issue.self, id: issue.id) == nil)
    }

    @Test("After discarding there is nothing left to send")
    func nothingToSend() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let issue = Fixture.issue()
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt)])
        try await store.discardOperation(try await firstOperationID(store))
        let backend = FakeBackend([])
        let report = await SyncEngine(store: store, backend: backend, clock: { Fixture.now }).drain()
        #expect(report.completed == 0 && backend.upserts.isEmpty)
    }

    @Test("The store tells listeners when a change was discarded")
    func broadcasts() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let issue = Fixture.issue()
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt)])
        let id = try await firstOperationID(store)
        let heard = Task { () -> Bool in
            for await _ in store.changes() { return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(100))
        try await store.discardOperation(id)
        let got = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await heard.value }
            group.addTask { try? await Task.sleep(for: .seconds(2)); heard.cancel(); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(got)
    }
}
