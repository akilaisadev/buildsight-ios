import Foundation

public enum OperationState: Codable, Hashable, Sendable {
    case pending
    case inFlight
    /// Rejected for a reason retrying will not fix (validation, permission).
    /// Stays in the queue so the user sees it and can retry or discard.
    case failed
}

/// One queued change. Its `id` doubles as the idempotency key sent to the
/// server, so replaying the same operation after a lost response is safe.
public struct PendingOperation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var recordType: RecordType
    public var recordID: UUID
    public var projectID: UUID
    public var payload: Data
    /// Record as the server last confirmed it, before any local edits. Needed
    /// for three-way merging if the server copy moved in the meantime.
    public var baseSnapshot: Data?
    public var baseVersion: Int
    public var createdAt: Date
    public var attempts: Int
    public var state: OperationState
    public var lastError: String?
    public var nextAttemptAt: Date?
    /// Evidence photos upload their file first; once it succeeds the object
    /// path is stored here so a retry after a failed record upsert skips it.
    public var localFilename: String?
    public var uploadedObjectPath: String?
    /// Column values the server stores beside the payload.
    public var parentID: UUID?
    public var sortDate: Date?

    public init(id: UUID = UUID(), recordType: RecordType, recordID: UUID, projectID: UUID, payload: Data, baseSnapshot: Data? = nil, baseVersion: Int = 0, createdAt: Date, attempts: Int = 0, state: OperationState = .pending, lastError: String? = nil, nextAttemptAt: Date? = nil, localFilename: String? = nil, uploadedObjectPath: String? = nil, parentID: UUID? = nil, sortDate: Date? = nil) {
        self.parentID = parentID
        self.sortDate = sortDate
        self.id = id
        self.recordType = recordType
        self.recordID = recordID
        self.projectID = projectID
        self.payload = payload
        self.baseSnapshot = baseSnapshot
        self.baseVersion = baseVersion
        self.createdAt = createdAt
        self.attempts = attempts
        self.state = state
        self.lastError = lastError
        self.nextAttemptAt = nextAttemptAt
        self.localFilename = localFilename
        self.uploadedObjectPath = uploadedObjectPath
    }
}

public struct RemoteAck: Sendable, Equatable {
    public var serverVersion: Int
    public init(serverVersion: Int) { self.serverVersion = serverVersion }
}

public enum RemoteError: Error, Equatable, Sendable {
    /// No connectivity. Stops the whole drain: the next record would fail too.
    case offline
    /// 5xx / timeout. Retry this operation later; others may still succeed.
    case transient(String)
    /// Session expired or revoked. Drain halts until the user signs in again.
    case unauthorized
    /// The server copy changed since `baseVersion`.
    case conflict(serverRecord: Data, serverVersion: Int)
    /// 4xx other than auth/conflict: validation or row-level security denial.
    case rejected(String)
}

/// The network boundary. The production implementation talks to the REST API;
/// tests inject a scripted fake, so sync behaviour is verified without a server.
public protocol RemoteBackend: Sendable {
    /// Idempotent upsert keyed by the record id; `idempotencyKey` is the operation id.
    func upsert(_ operation: PendingOperation, objectPath: String?) async throws -> RemoteAck
    /// Uploads the original evidence file. The object path is derived from the
    /// project and photo ids, so re-uploading overwrites instead of duplicating.
    func uploadEvidence(projectID: UUID, photoID: UUID, localFilename: String) async throws -> String
}

/// What the engine needs from local storage.
public protocol SyncQueueStore: Sendable {
    func pendingOperations() async throws -> [PendingOperation]
    func update(_ operation: PendingOperation) async throws
    /// Removes the operation and marks the record synced at `serverVersion`.
    func complete(_ operation: PendingOperation, serverVersion: Int) async throws
    /// Replaces local record content with a merged version and re-queues it.
    func applyMerge(for operation: PendingOperation, mergedPayload: Data, serverVersion: Int, conflictedFields: [String]) async throws
    func markRecordState(_ operation: PendingOperation, state: SyncState) async throws
}

public struct SyncReport: Equatable, Sendable {
    public var completed = 0
    public var failedPermanently = 0
    public var retryScheduled = 0
    public var merged = 0
    public var stoppedOffline = false
    public var authExpired = false
}
