import Foundation

/// The signed-in person acting inside one project. View models receive this
/// instead of reaching for a global session, which keeps them testable and
/// makes it impossible to act in a project the user has no role in.
public struct ActingUser: Equatable, Sendable {
    public var userID: UUID
    public var displayName: String
    public var role: Role
    public var projectID: UUID

    public init(userID: UUID, displayName: String, role: Role, projectID: UUID) {
        self.userID = userID
        self.displayName = displayName
        self.role = role
        self.projectID = projectID
    }

    /// Nil if the profile has no membership in the project.
    public init?(profile: UserProfile, projectID: UUID) {
        guard let role = profile.role(in: projectID) else { return nil }
        self.init(userID: profile.id, displayName: profile.displayName, role: role, projectID: projectID)
    }
}

public enum LocationPermission: Equatable, Sendable {
    case notDetermined, denied, restricted, whenInUse, always
    /// iOS 14+: user allowed location but only to an approximate area.
    case approximateOnly
}

public protocol LocationProviding: Sendable {
    var permission: LocationPermission { get }
    /// Best fix available within `timeout`; `.unavailable(reason)` otherwise.
    /// Never returns invented coordinates.
    func currentFix(timeout: TimeInterval) async -> LocationFix
}

public struct SavedEvidence: Equatable, Sendable {
    public var filename: String
    public var pixelWidth: Int
    public var pixelHeight: Int
}

public protocol EvidenceFileStoring: Sendable {
    /// Stores the ORIGINAL image (upright, never annotated).
    func save(jpeg: Data, photoID: UUID) throws -> SavedEvidence
    func url(forFilename filename: String) -> URL
    func delete(filename: String)
}

/// Lets view models ask for a sync after a local change without knowing how
/// or when it is scheduled.
public protocol SyncTriggering: Sendable {
    func requestSync() async
}

public struct NoopSyncTrigger: SyncTriggering {
    public init() {}
    public func requestSync() async {}
}
