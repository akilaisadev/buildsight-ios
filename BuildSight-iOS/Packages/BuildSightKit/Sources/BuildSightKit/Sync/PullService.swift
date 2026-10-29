import Foundation

/// A record as the server returns it.
public struct RemoteRecord: Sendable {
    public var type: RecordType
    public var id: UUID
    public var projectID: UUID
    public var parentID: UUID?
    public var sortDate: Date
    public var updatedAt: Date
    public var serverVersion: Int
    public var payload: Data

    public init(type: RecordType, id: UUID, projectID: UUID, parentID: UUID?, sortDate: Date, updatedAt: Date, serverVersion: Int, payload: Data) {
        self.type = type
        self.id = id
        self.projectID = projectID
        self.parentID = parentID
        self.sortDate = sortDate
        self.updatedAt = updatedAt
        self.serverVersion = serverVersion
        self.payload = payload
    }
}

public protocol RemotePuller: Sendable {
    /// Everything in the project changed after `since` (nil = full download).
    /// The server applies row-level security, so a user only ever receives
    /// projects they belong to.
    func fetchChanges(projectID: UUID, since: Date?) async throws -> [RemoteRecord]
}

public struct PullReport: Equatable, Sendable {
    public var applied = 0
    public var skippedLocalEdits = 0
    public var skippedStale = 0
    public var latestUpdate: Date?
}

/// Applies server changes to the local store without trampling offline work.
public struct PullService: Sendable {
    private let store: LocalStore
    private let remote: RemotePuller

    public init(store: LocalStore, remote: RemotePuller) {
        self.store = store
        self.remote = remote
    }

    public func pull(projectID: UUID, since: Date?) async throws -> PullReport {
        let changes = try await remote.fetchChanges(projectID: projectID, since: since)
        // Records with a queued local edit are left alone: the push path merges
        // them against the server copy with the conflict resolver instead.
        let pendingIDs = Set(try await store.pendingOperations().map(\.recordID))
        var report = PullReport()
        var writes: [RecordWrite] = []

        for change in changes where change.projectID == projectID {   // never accept another project's rows
            report.latestUpdate = max(report.latestUpdate ?? change.updatedAt, change.updatedAt)
            if pendingIDs.contains(change.id) { report.skippedLocalEdits += 1; continue }
            if let known = try await store.knownVersion(type: change.type, id: change.id), known >= change.serverVersion {
                report.skippedStale += 1; continue
            }
            writes.append(RecordWrite(remote: change))
        }
        if !writes.isEmpty { try await store.commit(writes) }
        report.applied = writes.count
        return report
    }
}
