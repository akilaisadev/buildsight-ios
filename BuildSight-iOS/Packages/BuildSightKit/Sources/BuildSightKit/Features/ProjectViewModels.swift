import Foundation
import Observation

/// Which project the whole app is scoped to. Changing it is the only way
/// other view models see different data; none of them can ask for another project.
@MainActor
@Observable
public final class ProjectSelection {
    public private(set) var projects: [Project] = []
    public private(set) var activeProjectID: UUID?
    public private(set) var actor: ActingUser?

    private let profile: UserProfile
    private let repository: ProjectRepository
    private let defaults: UserDefaults
    private var selectionKey: String { "project.selection.\(profile.id.uuidString)" }

    public init(profile: UserProfile, repository: ProjectRepository, defaults: UserDefaults = .standard) {
        self.profile = profile
        self.repository = repository
        self.defaults = defaults
    }

    public func load() async {
        projects = (try? await repository.projects(for: profile)) ?? []
        let remembered = defaults.string(forKey: selectionKey).flatMap(UUID.init(uuidString:))
        // A remembered project the user no longer belongs to is ignored.
        let valid = projects.first { $0.id == remembered }?.id ?? projects.first?.id
        select(valid)
    }

    public func select(_ id: UUID?) {
        guard let id, projects.contains(where: { $0.id == id }) else { activeProjectID = nil; actor = nil; return }
        activeProjectID = id
        actor = ActingUser(profile: profile, projectID: id)
        defaults.set(id.uuidString, forKey: selectionKey)
    }

    public var activeProject: Project? { projects.first { $0.id == activeProjectID } }
}

/// Shared loading behaviour: reload whenever the store changes, so every screen
/// reflects a transition made on any other screen without manual refresh calls.
@MainActor
@Observable
public final class ProjectDataModel {
    public private(set) var snapshot: ProjectSnapshot?
    public private(set) var loadError: String?

    private let repository: ProjectRepository
    private let projectID: UUID

    public init(projectID: UUID, repository: ProjectRepository) {
        self.projectID = projectID
        self.repository = repository
    }

    public func reload() async {
        do {
            snapshot = try await repository.snapshot(projectID: projectID)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Runs for the lifetime of the screen; cancelled by SwiftUI's `.task`.
    public func observe() async {
        await reload()
        for await _ in repository.store.changes() {
            if Task.isCancelled { break }
            await reload()
        }
    }
}

// MARK: - Dashboard

public struct DashboardTile: Identifiable, Equatable, Sendable {
    public enum Destination: Equatable, Sendable {
        case issues(IssueFilter)
        case tasks(TaskBucket)
        case inspections
        case timelineToday
        case helmetFlags(unreviewedOnly: Bool)
        case map
    }
    public var id: String
    public var title: String
    public var value: Int
    public var caption: String
    public var destination: Destination
}

@MainActor
@Observable
public final class DashboardViewModel {
    public private(set) var summary: DashboardSummary?
    public private(set) var tiles: [DashboardTile] = []
    public private(set) var recentActivity: [TimelineEvent] = []
    public private(set) var stopWorkAreaNames: [String] = []

    private let clock: @Sendable () -> Date
    private let calendar: Calendar

    public init(clock: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.clock = clock
        self.calendar = calendar
    }

    public func update(from snapshot: ProjectSnapshot) {
        let now = clock()
        let s = DashboardCalculator.summary(projectID: snapshot.project.id, issues: snapshot.issues, tasks: snapshot.tasks, inspections: snapshot.inspections, now: now, calendar: calendar)
        summary = s
        let critical = s.openIssuesByPriority[.critical] ?? 0
        let high = s.openIssuesByPriority[.high] ?? 0
        tiles = [
            DashboardTile(id: "open", title: "Open issues", value: s.openIssueTotal, caption: "\(critical) critical, \(high) high", destination: .issues(IssueFilter(openOnly: true))),
            DashboardTile(id: "inspections", title: "Inspections due", value: s.inspectionsDue, caption: "Due today or unfinished", destination: .inspections),
            DashboardTile(id: "tasks", title: "Tasks today", value: s.taskCounts[.today] ?? 0, caption: "\(s.taskCounts[.overdue] ?? 0) overdue", destination: .tasks(.today)),
            DashboardTile(id: "activity", title: "Activity today", value: s.activityToday, caption: "Records created today", destination: .timelineToday),
            DashboardTile(id: "flags", title: "Helmet flags to review", value: s.helmet.unreviewed, caption: "\(s.helmet.confirmed) confirmed, \(s.helmet.dismissed) dismissed", destination: .helmetFlags(unreviewedOnly: true)),
        ]
        let events = TimelineBuilder.events(projectID: snapshot.project.id, photos: snapshot.photos, issues: snapshot.issues, inspections: snapshot.inspections, tasks: snapshot.tasks)
        recentActivity = Array(events.sorted { $0.at > $1.at }.prefix(5))
        let stopAreas = InspectionRules.areasUnderStopWork(snapshot.inspections)
        stopWorkAreaNames = snapshot.areas.filter { stopAreas.contains($0.id) }.map(\.displayName)
    }
}

// MARK: - Issue list

public struct IssueFilter: Equatable, Hashable, Sendable {
    public var statuses: Set<IssueStatus> = []
    public var priorities: Set<Priority> = []
    public var areaID: UUID?
    public var openOnly = false
    public var machineGeneratedOnly = false
    public var unreviewedOnly = false
    public var assigneeID: UUID?

    public init(statuses: Set<IssueStatus> = [], priorities: Set<Priority> = [], areaID: UUID? = nil, openOnly: Bool = false, machineGeneratedOnly: Bool = false, unreviewedOnly: Bool = false, assigneeID: UUID? = nil) {
        self.statuses = statuses
        self.priorities = priorities
        self.areaID = areaID
        self.openOnly = openOnly
        self.machineGeneratedOnly = machineGeneratedOnly
        self.unreviewedOnly = unreviewedOnly
        self.assigneeID = assigneeID
    }

    public func matches(_ issue: Issue) -> Bool {
        if openOnly, !(issue.status.isOpenWork && issue.review != .dismissed) { return false }
        if !statuses.isEmpty, !statuses.contains(issue.status) { return false }
        if !priorities.isEmpty, !priorities.contains(issue.priority) { return false }
        if let areaID, issue.areaID != areaID { return false }
        if machineGeneratedOnly, !issue.isMachineGenerated { return false }
        if unreviewedOnly, issue.review != .awaitingReview { return false }
        if let assigneeID, issue.assigneeID != assigneeID { return false }
        return true
    }
}

public enum IssueSort: String, CaseIterable, Sendable { case newest, priority }

@MainActor
@Observable
public final class IssueListViewModel {
    public var filter: IssueFilter
    public var search = ""
    public var sort: IssueSort = .priority

    public init(filter: IssueFilter = IssueFilter()) { self.filter = filter }

    public func issues(in snapshot: ProjectSnapshot) -> [Issue] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matched = snapshot.issues.filter { filter.matches($0) && (q.isEmpty || $0.title.lowercased().contains(q) || $0.details.lowercased().contains(q)) }
        switch sort {
        case .newest: return matched.sorted { $0.createdAt > $1.createdAt }
        case .priority: return matched.sorted { ($0.priority, $0.createdAt) > ($1.priority, $1.createdAt) }
        }
    }
}
