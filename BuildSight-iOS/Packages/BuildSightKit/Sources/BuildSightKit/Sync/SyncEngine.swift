import Foundation

/// Sends the queued operations to the backend. An actor, so two triggers can't run
/// overlapping drains and send the same operation twice.
public actor SyncEngine {
    private let store: SyncQueueStore
    private let backend: RemoteBackend
    private let clock: @Sendable () -> Date
    private var isDraining = false

    /// Backoff: 5 s, 10 s, 20 s … capped at 15 minutes.
    static func backoff(afterAttempt attempt: Int) -> TimeInterval {
        min(5 * pow(2, Double(max(0, attempt - 1))), 15 * 60)
    }

    public init(store: SyncQueueStore, backend: RemoteBackend, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.backend = backend
        self.clock = clock
    }

    /// Processes everything that is due. Safe to call repeatedly.
    @discardableResult
    public func drain() async -> SyncReport {
        var report = SyncReport()
        guard !isDraining else { return report }
        isDraining = true
        defer { isDraining = false }

        let operations: [PendingOperation]
        do { operations = try await store.pendingOperations().sorted { $0.createdAt < $1.createdAt } }
        catch { return report }

        // Operations for one record keep their order; a record whose earlier
        // operation failed must not have a later one overtake it.
        var blockedRecords = Set<UUID>()

        for var op in operations {
            if op.state == .failed || blockedRecords.contains(op.recordID) { continue }
            if let due = op.nextAttemptAt, due > clock() { blockedRecords.insert(op.recordID); continue }

            op.state = .inFlight
            try? await store.update(op)
            try? await store.markRecordState(op, state: .uploading)

            do {
                try await send(&op)
                report.completed += 1
            } catch RemoteError.offline {
                await reschedule(&op, error: "No connection", report: &report)
                report.stoppedOffline = true
                break
            } catch RemoteError.unauthorized {
                op.state = .pending
                op.lastError = "Session expired. Sign in again to continue syncing."
                try? await store.update(op)
                try? await store.markRecordState(op, state: .pending)
                report.authExpired = true
                break
            } catch RemoteError.transient(let message) {
                await reschedule(&op, error: message, report: &report)
                blockedRecords.insert(op.recordID)
            } catch RemoteError.rejected(let message) {
                op.state = .failed
                op.lastError = message
                try? await store.update(op)
                try? await store.markRecordState(op, state: .failed)
                report.failedPermanently += 1
                blockedRecords.insert(op.recordID)
            } catch {
                await reschedule(&op, error: error.localizedDescription, report: &report)
                blockedRecords.insert(op.recordID)
            }
        }
        return report
    }

    /// Puts a permanently failed operation back in the queue (user pressed Retry).
    public func retry(_ operationID: UUID) async {
        guard var op = (try? await store.pendingOperations())?.first(where: { $0.id == operationID }) else { return }
        op.state = .pending
        op.attempts = 0
        op.nextAttemptAt = nil
        op.lastError = nil
        try? await store.update(op)
        try? await store.markRecordState(op, state: .pending)
    }

    // MARK: - One operation

    private func send(_ op: inout PendingOperation) async throws {
        // Step 1: the evidence file. Skipped on retry if it already succeeded,
        // which is how a failure between upload and upsert is recovered.
        if op.recordType == .photo, op.uploadedObjectPath == nil, let filename = op.localFilename {
            op.uploadedObjectPath = try await backend.uploadEvidence(projectID: op.projectID, photoID: op.recordID, localFilename: filename)
            try? await store.update(op)
        }

        // Step 2: the record. A conflict is merged once and re-sent; a second
        // conflict means the server is moving faster than we can reconcile, so
        // the operation is retried later rather than looping.
        do {
            let ack = try await backend.upsert(op, objectPath: op.uploadedObjectPath)
            try await store.complete(op, serverVersion: ack.serverVersion)
        } catch RemoteError.conflict(let serverRecord, let serverVersion) {
            try await resolveConflict(&op, serverRecord: serverRecord, serverVersion: serverVersion)
        }
    }

    private func resolveConflict(_ op: inout PendingOperation, serverRecord: Data, serverVersion: Int) async throws {
        let local = try JSONValue.parse(op.payload)
        let remote = try JSONValue.parse(serverRecord)
        let base = try op.baseSnapshot.map { try JSONValue.parse($0) }
        guard let outcome = ConflictResolver.merge(base: base, local: local, remote: remote) else {
            throw RemoteError.rejected("Conflicting record could not be merged")
        }
        let mergedData = try outcome.merged.data()
        op.payload = mergedData
        op.baseVersion = serverVersion
        op.baseSnapshot = serverRecord
        try? await store.update(op)

        let ack = try await backend.upsert(op, objectPath: op.uploadedObjectPath)
        try await store.applyMerge(for: op, mergedPayload: mergedData, serverVersion: ack.serverVersion, conflictedFields: outcome.conflictedFields)
    }

    private func reschedule(_ op: inout PendingOperation, error: String, report: inout SyncReport) async {
        op.attempts += 1
        op.state = .pending
        op.lastError = error
        op.nextAttemptAt = clock().addingTimeInterval(Self.backoff(afterAttempt: op.attempts))
        try? await store.update(op)
        try? await store.markRecordState(op, state: .failed)
        report.retryScheduled += 1
    }
}
