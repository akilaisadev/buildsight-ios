import Foundation

public enum ChecklistResult: String, Codable, CaseIterable, Sendable {
    case pass, fail, notApplicable

    public var displayName: String {
        switch self {
        case .pass: "Pass"
        case .fail: "Fail"
        case .notApplicable: "N/A"
        }
    }
}

public struct ChecklistTemplate: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var itemTitles: [String]

    public init(id: UUID = UUID(), name: String, itemTitles: [String]) {
        self.id = id
        self.name = name
        self.itemTitles = itemTitles
    }
}

public struct InspectionItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var result: ChecklistResult?
    public var note: String
    public var photoIDs: [UUID]

    public init(id: UUID = UUID(), title: String, result: ChecklistResult? = nil, note: String = "", photoIDs: [UUID] = []) {
        self.id = id
        self.title = title
        self.result = result
        self.note = note
        self.photoIDs = photoIDs
    }
}

/// Digital stop-work notice. It notifies supervisors, creates a Critical issue
/// and shows a banner for the area until cleared. It does NOT control any
/// equipment; the UI says so wherever the flag is raised.
public struct EmergencyStop: Codable, Hashable, Sendable {
    public var raisedAt: Date
    public var reason: String
    public var clearedAt: Date?
    public var clearedByID: UUID?
    public var raisedIssueID: UUID?

    public init(raisedAt: Date, reason: String, clearedAt: Date? = nil, clearedByID: UUID? = nil, raisedIssueID: UUID? = nil) {
        self.raisedAt = raisedAt
        self.reason = reason
        self.clearedAt = clearedAt
        self.clearedByID = clearedByID
        self.raisedIssueID = raisedIssueID
    }

    public var isActive: Bool { clearedAt == nil }
}

public struct Inspection: SyncableRecord {
    public static let recordType: RecordType = .inspection

    public enum Status: String, Codable, Sendable { case inProgress, completed }
    public enum Outcome: String, Codable, Sendable { case passed, failed }

    public var id: UUID
    public var projectID: UUID
    public var areaID: UUID
    public var templateName: String
    public var inspectorID: UUID
    public var startedAt: Date
    public var completedAt: Date?
    public var dueDate: Date?
    public var items: [InspectionItem]
    public var location: LocationFix
    public var emergencyStop: EmergencyStop?
    public var updatedAt: Date
    public var serverVersion: Int

    public init(id: UUID = UUID(), projectID: UUID, areaID: UUID, templateName: String, inspectorID: UUID, startedAt: Date, completedAt: Date? = nil, dueDate: Date? = nil, items: [InspectionItem], location: LocationFix, emergencyStop: EmergencyStop? = nil, serverVersion: Int = 0) {
        self.id = id
        self.projectID = projectID
        self.areaID = areaID
        self.templateName = templateName
        self.inspectorID = inspectorID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.dueDate = dueDate
        self.items = items
        self.location = location
        self.emergencyStop = emergencyStop
        self.updatedAt = completedAt ?? startedAt
        self.serverVersion = serverVersion
    }

    public var status: Status { completedAt == nil ? .inProgress : .completed }

    public var answeredCount: Int { items.filter { $0.result != nil }.count }

    /// Only meaningful once completed: any failed item fails the inspection.
    public var outcome: Outcome? {
        guard status == .completed else { return nil }
        return items.contains { $0.result == .fail } ? .failed : .passed
    }
}
