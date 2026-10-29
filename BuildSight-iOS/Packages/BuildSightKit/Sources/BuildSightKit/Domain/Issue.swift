import Foundation

public enum IssueStatus: String, Codable, CaseIterable, Sendable {
    case open, inProgress, resolved, verified, closed

    public var displayName: String {
        switch self {
        case .open: "Open"
        case .inProgress: "In Progress"
        case .resolved: "Resolved"
        case .verified: "Verified"
        case .closed: "Closed"
        }
    }

    /// Open work is anything not yet signed off by a second person.
    public var isOpenWork: Bool { self == .open || self == .inProgress || self == .resolved }
}

public enum IssueCategory: String, Codable, CaseIterable, Sendable {
    case structural, electrical, plumbing, safety, quality, other

    public var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Machine-generated issues are labelled as such and carry a review state, so
/// nobody mistakes a detector hint for a confirmed finding.
public enum IssueOrigin: Codable, Hashable, Sendable {
    case manual
    case helmetDetection(analysisID: UUID)
}

public enum HumanReviewStatus: String, Codable, Sendable {
    case notRequired
    case awaitingReview
    case confirmed
    /// Reviewer agreed something was wrong but corrected the detector's detail
    /// (for example the number of workers affected).
    case corrected
    case dismissed
}

public struct Issue: SyncableRecord {
    public static let recordType: RecordType = .issue

    public var id: UUID
    public var projectID: UUID
    public var areaID: UUID
    public var title: String
    public var details: String
    public var category: IssueCategory
    public var priority: Priority
    public var status: IssueStatus
    public var assigneeID: UUID?
    public var reporterID: UUID
    /// The person who last moved the issue to Resolved; the verifier must differ.
    public var resolvedByID: UUID?
    public var dueDate: Date?
    public var createdAt: Date
    public var evidencePhotoIDs: [UUID]
    public var location: LocationFix
    public var origin: IssueOrigin
    public var review: HumanReviewStatus
    public var updatedAt: Date
    public var serverVersion: Int

    public init(id: UUID = UUID(), projectID: UUID, areaID: UUID, title: String, details: String, category: IssueCategory, priority: Priority, status: IssueStatus = .open, assigneeID: UUID? = nil, reporterID: UUID, resolvedByID: UUID? = nil, dueDate: Date? = nil, createdAt: Date, evidencePhotoIDs: [UUID] = [], location: LocationFix, origin: IssueOrigin = .manual, review: HumanReviewStatus = .notRequired, updatedAt: Date? = nil, serverVersion: Int = 0) {
        self.id = id
        self.projectID = projectID
        self.areaID = areaID
        self.title = title
        self.details = details
        self.category = category
        self.priority = priority
        self.status = status
        self.assigneeID = assigneeID
        self.reporterID = reporterID
        self.resolvedByID = resolvedByID
        self.dueDate = dueDate
        self.createdAt = createdAt
        self.evidencePhotoIDs = evidencePhotoIDs
        self.location = location
        self.origin = origin
        self.review = review
        self.updatedAt = updatedAt ?? createdAt
        self.serverVersion = serverVersion
    }

    public var isMachineGenerated: Bool {
        if case .helmetDetection = origin { return true }
        return false
    }

    public var sourceAnalysisID: UUID? {
        if case .helmetDetection(let id) = origin { return id }
        return nil
    }
}

/// Append-only audit trail. Events are never edited, which also makes them
/// trivially mergeable when two devices touch the same issue offline.
public struct IssueEvent: SyncableRecord {
    public static let recordType: RecordType = .issueEvent

    public enum Kind: Codable, Hashable, Sendable {
        case created
        case statusChanged(from: IssueStatus, to: IssueStatus)
        case assigned(to: UUID?)
        case priorityChanged(from: Priority, to: Priority)
        case commented
        case photoAttached(photoID: UUID)
        case machineReview(HumanReviewStatus)
        case reanalysed
    }

    public var id: UUID
    public var projectID: UUID
    public var issueID: UUID
    public var actorID: UUID
    public var at: Date
    public var kind: Kind
    /// Comment text, or the reason for a rework / reopen / dismissal.
    public var note: String?
    public var updatedAt: Date
    public var serverVersion: Int

    public init(id: UUID = UUID(), projectID: UUID, issueID: UUID, actorID: UUID, at: Date, kind: Kind, note: String? = nil, serverVersion: Int = 0) {
        self.id = id
        self.projectID = projectID
        self.issueID = issueID
        self.actorID = actorID
        self.at = at
        self.kind = kind
        self.note = note
        self.updatedAt = at
        self.serverVersion = serverVersion
    }
}

/// An unsaved report. Drafts stay on the device and are not synced, so a
/// half-written report never shows up on a supervisor's dashboard.
public struct IssueDraft: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var areaID: UUID?
    public var title: String
    public var details: String
    public var category: IssueCategory
    public var priority: Priority
    public var assigneeID: UUID?
    public var dueDate: Date?
    public var photoIDs: [UUID]
    public var savedAt: Date

    public init(id: UUID = UUID(), projectID: UUID, areaID: UUID? = nil, title: String = "", details: String = "", category: IssueCategory = .other, priority: Priority = .medium, assigneeID: UUID? = nil, dueDate: Date? = nil, photoIDs: [UUID] = [], savedAt: Date) {
        self.id = id
        self.projectID = projectID
        self.areaID = areaID
        self.title = title
        self.details = details
        self.category = category
        self.priority = priority
        self.assigneeID = assigneeID
        self.dueDate = dueDate
        self.photoIDs = photoIDs
        self.savedAt = savedAt
    }
}
