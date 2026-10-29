import Foundation

public enum TimelineKind: String, CaseIterable, Codable, Sendable {
    case photo, issue, inspection, task, helmetFlag

    public var displayName: String {
        switch self {
        case .photo: "Photo"
        case .issue: "Issue"
        case .inspection: "Inspection"
        case .task: "Task"
        case .helmetFlag: "Helmet flag"
        }
    }
}

/// Points at the underlying record so a tap always opens the right screen.
public struct RecordRef: Hashable, Sendable {
    public var kind: TimelineKind
    public var id: UUID
}

public struct TimelineEvent: Identifiable, Hashable, Sendable {
    public var id: String { "\(ref.kind.rawValue)-\(ref.id.uuidString)" }
    public var ref: RecordRef
    public var at: Date
    public var title: String
    public var statusLabel: String
    public var areaID: UUID?
    public var personID: UUID
}

public struct TimelineFilter: Equatable, Sendable {
    public var dateRange: ClosedRange<Date>?
    public var areaIDs: Set<UUID> = []
    public var kinds: Set<TimelineKind> = []
    public var personID: UUID?
    public var statusLabel: String?

    public init(dateRange: ClosedRange<Date>? = nil, areaIDs: Set<UUID> = [], kinds: Set<TimelineKind> = [], personID: UUID? = nil, statusLabel: String? = nil) {
        self.dateRange = dateRange
        self.areaIDs = areaIDs
        self.kinds = kinds
        self.personID = personID
        self.statusLabel = statusLabel
    }

    public var isActive: Bool { self != TimelineFilter() }
}

public struct TimelineSection: Identifiable, Equatable, Sendable {
    public var id: Date { day }
    public var day: Date
    public var events: [TimelineEvent]
}

public enum TimelineBuilder {
    /// Events come straight from stored records, so the timeline can never
    /// disagree with the lists. A helmet-generated issue appears once, as a
    /// helmet flag, rather than also as an ordinary issue.
    public static func events(projectID: UUID, photos: [EvidencePhoto], issues: [Issue], inspections: [Inspection], tasks: [TaskItem]) -> [TimelineEvent] {
        var out: [TimelineEvent] = []
        out += photos.filter { $0.projectID == projectID }.map {
            TimelineEvent(ref: RecordRef(kind: .photo, id: $0.id), at: $0.capturedAt, title: $0.note.isEmpty ? "Photo captured" : $0.note, statusLabel: $0.category.rawValue.capitalized, areaID: $0.areaID, personID: $0.creatorID)
        }
        out += issues.filter { $0.projectID == projectID }.map { issue in
            TimelineEvent(
                ref: RecordRef(kind: issue.isMachineGenerated ? .helmetFlag : .issue, id: issue.id),
                at: issue.createdAt, title: issue.title,
                statusLabel: issue.isMachineGenerated ? reviewLabel(issue.review) : issue.status.displayName,
                areaID: issue.areaID, personID: issue.reporterID)
        }
        out += inspections.filter { $0.projectID == projectID }.map {
            TimelineEvent(ref: RecordRef(kind: .inspection, id: $0.id), at: $0.completedAt ?? $0.startedAt, title: $0.templateName, statusLabel: $0.outcome.map { $0 == .passed ? "Passed" : "Failed" } ?? "In Progress", areaID: $0.areaID, personID: $0.inspectorID)
        }
        out += tasks.filter { $0.projectID == projectID }.map {
            TimelineEvent(ref: RecordRef(kind: .task, id: $0.id), at: $0.createdAt, title: $0.title, statusLabel: taskLabel($0.status), areaID: $0.areaID, personID: $0.creatorID)
        }
        return out
    }

    public static func reviewLabel(_ r: HumanReviewStatus) -> String {
        switch r {
        case .awaitingReview: "Awaiting review"
        case .confirmed: "Confirmed"
        case .corrected: "Corrected"
        case .dismissed: "Dismissed"
        case .notRequired: "Flag"
        }
    }

    static func taskLabel(_ s: TaskItem.Status) -> String {
        switch s { case .notStarted: "Not Started"; case .inProgress: "In Progress"; case .completed: "Completed" }
    }

    public static func sections(_ events: [TimelineEvent], filter: TimelineFilter, calendar: Calendar = .current) -> [TimelineSection] {
        let filtered = events.filter { e in
            if let r = filter.dateRange, !r.contains(e.at) { return false }
            if !filter.areaIDs.isEmpty, !(e.areaID.map(filter.areaIDs.contains) ?? false) { return false }
            if !filter.kinds.isEmpty, !filter.kinds.contains(e.ref.kind) { return false }
            if let p = filter.personID, e.personID != p { return false }
            if let s = filter.statusLabel, e.statusLabel != s { return false }
            return true
        }
        return Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.at) }
            .map { TimelineSection(day: $0.key, events: $0.value.sorted { $0.at > $1.at }) }
            .sorted { $0.day > $1.day }
    }
}

// MARK: - Map

public struct MapItem: Identifiable, Hashable, Sendable {
    public var id: String { "\(ref.kind.rawValue)-\(ref.id.uuidString)" }
    public var ref: RecordRef
    public var title: String
    public var point: GeoPoint
    public var isApproximate: Bool
}

public struct MapProjection: Equatable, Sendable {
    public var items: [MapItem]
    /// Records that exist but have no usable GPS, listed separately so they are
    /// never silently missing from the map or pinned at a made-up position.
    public var withoutLocation: [RecordRef]
}

public enum MapProjector {
    /// Tasks have no GPS of their own. A task is pinned only when it links to an
    /// issue that has a real fix; otherwise it is listed as "without location".
    public static func project(projectID: UUID, photos: [EvidencePhoto], issues: [Issue], inspections: [Inspection], tasks: [TaskItem] = []) -> MapProjection {
        var items: [MapItem] = []
        var missing: [RecordRef] = []

        func add(_ kind: TimelineKind, id: UUID, title: String, location: LocationFix) {
            let ref = RecordRef(kind: kind, id: id)
            if let p = location.point { items.append(MapItem(ref: ref, title: title, point: p, isApproximate: location.isApproximate)) }
            else { missing.append(ref) }
        }
        for p in photos where p.projectID == projectID { add(.photo, id: p.id, title: p.note.isEmpty ? "Photo" : p.note, location: p.location) }
        for i in issues where i.projectID == projectID { add(i.isMachineGenerated ? .helmetFlag : .issue, id: i.id, title: i.title, location: i.location) }
        for i in inspections where i.projectID == projectID { add(.inspection, id: i.id, title: i.templateName, location: i.location) }
        let issueLocations = Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0.location) })
        for t in tasks where t.projectID == projectID {
            add(.task, id: t.id, title: t.title, location: t.relatedIssueID.flatMap { issueLocations[$0] } ?? .unavailable(.noFixYet))
        }
        return MapProjection(items: items, withoutLocation: missing)
    }
}
