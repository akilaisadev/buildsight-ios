import Foundation

/// Where a record stands against the backend. "synced" is only ever set after
/// the remote call returned success, never optimistically.
public enum SyncState: String, Codable, Sendable {
    case pending
    case uploading
    case synced
    case failed
}

/// Every record that is created offline and later pushed to the server.
/// IDs are client-generated UUIDs so a retried create cannot make a duplicate.
public protocol SyncableRecord: Codable, Identifiable, Equatable, Sendable where ID == UUID {
    static var recordType: RecordType { get }
    var id: UUID { get }
    var projectID: UUID { get }
    var updatedAt: Date { get set }
    /// Last server version this device has seen; used for conflict detection.
    var serverVersion: Int { get set }
}

public enum RecordType: String, Codable, CaseIterable, Sendable {
    case photo
    case issue
    case issueEvent
    case inspection
    case task
    case helmetAnalysis
    case notification
    // Reference data: downloaded, cached, never pushed.
    case project
    case siteArea
    case teamMember
}

public struct Project: SyncableRecord, Hashable {
    public static let recordType: RecordType = .project
    public enum Status: String, Codable, Sendable { case planning, active, completed }

    public var id: UUID
    public var name: String
    public var locationName: String
    public var status: Status
    public var startDate: Date
    public var endDate: Date
    public var managerName: String
    /// Rough centre used to frame the map when no record has GPS yet.
    public var centre: GeoPoint?
    public var updatedAt: Date
    public var serverVersion: Int
    public var projectID: UUID { id }

    public init(id: UUID, name: String, locationName: String, status: Status, startDate: Date, endDate: Date, managerName: String, centre: GeoPoint?, updatedAt: Date = Date(timeIntervalSince1970: 0), serverVersion: Int = 0) {
        self.updatedAt = updatedAt
        self.serverVersion = serverVersion
        self.id = id
        self.name = name
        self.locationName = locationName
        self.status = status
        self.startDate = startDate
        self.endDate = endDate
        self.managerName = managerName
        self.centre = centre
    }
}

public struct SiteArea: SyncableRecord, Hashable {
    public static let recordType: RecordType = .siteArea
    public var updatedAt = Date(timeIntervalSince1970: 0)
    public var serverVersion = 0
    public var id: UUID
    public var projectID: UUID
    public var name: String
    public var level: String

    public init(id: UUID, projectID: UUID, name: String, level: String) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.level = level
    }

    public var displayName: String { "\(name) • \(level)" }
}

/// Directory entry for assignee pickers and "created by" labels. `id` is the
/// membership row (unique per user-and-project, so one person can appear on
/// several sites without rows overwriting each other); `userID` is the person.
public struct TeamMember: SyncableRecord, Hashable {
    public static let recordType: RecordType = .teamMember
    public var id: UUID
    public var userID: UUID
    public var projectID: UUID
    public var displayName: String
    public var role: Role
    public var updatedAt = Date(timeIntervalSince1970: 0)
    public var serverVersion = 0

    public init(userID: UUID, projectID: UUID, displayName: String, role: Role) {
        self.id = DeterministicID.make(namespace: "membership.\(projectID.uuidString)", from: userID)
        self.userID = userID
        self.projectID = projectID
        self.displayName = displayName
        self.role = role
    }
}

public enum Priority: Int, Codable, CaseIterable, Comparable, Sendable {
    case low = 0, medium, high, critical

    public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .critical: "Critical"
        }
    }
}

// MARK: - Evidence photo

public enum PhotoCategory: String, Codable, CaseIterable, Sendable {
    case progress, issue, safety, inspection
}

/// The original JPEG lives on disk untouched. Bounding boxes and labels are
/// drawn at display time from `HelmetAnalysis`, so evidence is never altered.
public struct EvidencePhoto: SyncableRecord {
    public static let recordType: RecordType = .photo

    public var id: UUID
    public var projectID: UUID
    public var areaID: UUID
    public var creatorID: UUID
    public var capturedAt: Date
    public var location: LocationFix
    public var category: PhotoCategory
    public var note: String
    public var localFilename: String
    public var remoteObjectPath: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var updatedAt: Date
    public var serverVersion: Int

    public init(id: UUID = UUID(), projectID: UUID, areaID: UUID, creatorID: UUID, capturedAt: Date, location: LocationFix, category: PhotoCategory, note: String, localFilename: String, remoteObjectPath: String? = nil, pixelWidth: Int, pixelHeight: Int, updatedAt: Date? = nil, serverVersion: Int = 0) {
        self.id = id
        self.projectID = projectID
        self.areaID = areaID
        self.creatorID = creatorID
        self.capturedAt = capturedAt
        self.location = location
        self.category = category
        self.note = note
        self.localFilename = localFilename
        self.remoteObjectPath = remoteObjectPath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.updatedAt = updatedAt ?? capturedAt
        self.serverVersion = serverVersion
    }
}

// MARK: - Tasks

public struct TaskItem: SyncableRecord {
    public static let recordType: RecordType = .task

    public enum Status: String, Codable, Sendable { case notStarted, inProgress, completed }

    public var id: UUID
    public var projectID: UUID
    public var areaID: UUID?
    public var title: String
    public var details: String
    public var assigneeID: UUID
    public var creatorID: UUID
    public var priority: Priority
    public var status: Status
    public var dueDate: Date
    public var relatedIssueID: UUID?
    public var createdAt: Date
    public var completedAt: Date?
    public var updatedAt: Date
    public var serverVersion: Int

    public init(id: UUID = UUID(), projectID: UUID, areaID: UUID? = nil, title: String, details: String = "", assigneeID: UUID, creatorID: UUID, priority: Priority, status: Status = .notStarted, dueDate: Date, relatedIssueID: UUID? = nil, createdAt: Date, completedAt: Date? = nil, updatedAt: Date? = nil, serverVersion: Int = 0) {
        self.id = id
        self.projectID = projectID
        self.areaID = areaID
        self.title = title
        self.details = details
        self.assigneeID = assigneeID
        self.creatorID = creatorID
        self.priority = priority
        self.status = status
        self.dueDate = dueDate
        self.relatedIssueID = relatedIssueID
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.updatedAt = updatedAt ?? createdAt
        self.serverVersion = serverVersion
    }
}

// MARK: - Notifications

public struct AppNotification: SyncableRecord {
    public static let recordType: RecordType = .notification

    public enum Kind: String, Codable, Sendable {
        case issueAssigned, issueStatusChanged, taskOverdue, inspectionDue, helmetFlag, emergencyStop, syncConflict
    }

    public var id: UUID
    public var projectID: UUID
    public var kind: Kind
    public var title: String
    public var body: String
    public var createdAt: Date
    public var readAt: Date?
    public var deepLink: DeepLink?
    public var updatedAt: Date
    public var serverVersion: Int

    public init(id: UUID = UUID(), projectID: UUID, kind: Kind, title: String, body: String, createdAt: Date, readAt: Date? = nil, deepLink: DeepLink? = nil, serverVersion: Int = 0) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.readAt = readAt
        self.deepLink = deepLink
        self.updatedAt = createdAt
        self.serverVersion = serverVersion
    }

    public var isRead: Bool { readAt != nil }
}
