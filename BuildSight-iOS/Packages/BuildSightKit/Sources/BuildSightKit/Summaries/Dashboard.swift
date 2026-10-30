import Foundation

/// What the dashboard shows, computed from stored records. There is deliberately no "safety
/// score": one number can't honestly summarise detector output and open issues. Tiles are
/// plain counts that link to their records.
public struct DashboardSummary: Equatable, Sendable {
    public var openIssuesByPriority: [Priority: Int]
    public var openIssueTotal: Int
    /// Issues that reached Verified or Closed, out of all non-dismissed issues.
    public var issuesSignedOff: Int
    public var issuesTotal: Int
    public var inspectionsDue: Int
    public var taskCounts: [TaskBucket: Int]
    public var activityToday: Int
    public var helmet: HelmetFlagSummary
    public var areasUnderStopWork: Int
}

/// Meaning of each number (same in the widget and docs): unreviewed = flags nobody has judged,
/// confirmed = a person confirmed or corrected it, dismissed = a person rejected it.
public struct HelmetFlagSummary: Equatable, Codable, Sendable {
    public var unreviewed = 0
    public var confirmed = 0
    public var dismissed = 0
    public var flagsToday = 0
    public var mostAffectedAreaID: UUID?
}

public enum DashboardCalculator {
    public static func summary(
        projectID: UUID,
        issues: [Issue],
        tasks: [TaskItem],
        inspections: [Inspection],
        now: Date,
        calendar: Calendar = .current
    ) -> DashboardSummary {
        // Scoping happens here too, not only in the queries: a caller that passes
        // records from several projects still gets a single project's numbers.
        let issues = issues.filter { $0.projectID == projectID }
        let tasks = tasks.filter { $0.projectID == projectID }
        let inspections = inspections.filter { $0.projectID == projectID }

        let open = issues.filter { $0.status.isOpenWork && $0.review != .dismissed }
        var byPriority = Dictionary(uniqueKeysWithValues: Priority.allCases.map { ($0, 0) })
        for issue in open { byPriority[issue.priority, default: 0] += 1 }

        let counted = issues.filter { $0.review != .dismissed }
        let signedOff = counted.filter { $0.status == .verified || $0.status == .closed }.count

        var taskCounts = Dictionary(uniqueKeysWithValues: TaskBucket.allCases.map { ($0, 0) })
        for task in tasks { taskCounts[TaskScheduling.bucket(for: task, now: now, calendar: calendar), default: 0] += 1 }

        let due = inspections.filter { inspection in
            guard inspection.completedAt == nil else { return false }
            guard let dueDate = inspection.dueDate else { return true }   // started, unfinished
            return dueDate <= endOfDay(now, calendar)
        }.count

        let activityToday = issues.filter { calendar.isDate($0.createdAt, inSameDayAs: now) }.count
            + tasks.filter { calendar.isDate($0.createdAt, inSameDayAs: now) }.count
            + inspections.filter { calendar.isDate($0.startedAt, inSameDayAs: now) }.count

        return DashboardSummary(
            openIssuesByPriority: byPriority,
            openIssueTotal: open.count,
            issuesSignedOff: signedOff,
            issuesTotal: counted.count,
            inspectionsDue: due,
            taskCounts: taskCounts,
            activityToday: activityToday,
            helmet: helmetSummary(issues: issues, now: now, calendar: calendar),
            areasUnderStopWork: InspectionRules.areasUnderStopWork(inspections).count
        )
    }

    public static func helmetSummary(issues: [Issue], now: Date, calendar: Calendar = .current) -> HelmetFlagSummary {
        let flags = issues.filter(\.isMachineGenerated)
        var s = HelmetFlagSummary()
        for flag in flags {
            switch flag.review {
            case .awaitingReview: s.unreviewed += 1
            case .confirmed, .corrected: s.confirmed += 1
            case .dismissed: s.dismissed += 1
            case .notRequired: break
            }
            if calendar.isDate(flag.createdAt, inSameDayAs: now) { s.flagsToday += 1 }
        }
        // Most affected area among flags a person has not dismissed.
        let live = flags.filter { $0.review != .dismissed }
        s.mostAffectedAreaID = Dictionary(grouping: live, by: \.areaID)
            .max { $0.value.count < $1.value.count }?.key
        return s
    }

    private static func endOfDay(_ date: Date, _ calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) ?? date
    }
}

/// Compact snapshot shared with the widget through the App Group container.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var projectName: String
    public var generatedAt: Date
    public var unreviewedFlags: Int
    public var confirmedFindings: Int
    public var flagsToday: Int
    public var topAreaName: String?
    public var openCritical: Int

    public init(projectID: UUID, projectName: String, generatedAt: Date, unreviewedFlags: Int, confirmedFindings: Int, flagsToday: Int, topAreaName: String?, openCritical: Int) {
        self.projectID = projectID
        self.projectName = projectName
        self.generatedAt = generatedAt
        self.unreviewedFlags = unreviewedFlags
        self.confirmedFindings = confirmedFindings
        self.flagsToday = flagsToday
        self.topAreaName = topAreaName
        self.openCritical = openCritical
    }

    public static func make(project: Project, summary: DashboardSummary, areas: [SiteArea], now: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            projectID: project.id, projectName: project.name, generatedAt: now,
            unreviewedFlags: summary.helmet.unreviewed, confirmedFindings: summary.helmet.confirmed,
            flagsToday: summary.helmet.flagsToday,
            topAreaName: summary.helmet.mostAffectedAreaID.flatMap { id in areas.first { $0.id == id }?.name },
            openCritical: summary.openIssuesByPriority[.critical] ?? 0
        )
    }
}

/// Where the app writes the snapshot and the widget reads it. The App Group
/// suite is the only channel between the two processes.
public protocol WidgetSnapshotStore: Sendable {
    func save(_ snapshot: WidgetSnapshot) throws
    func load() -> WidgetSnapshot?
}

public final class UserDefaultsWidgetSnapshotStore: WidgetSnapshotStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "widget.snapshot.v1"

    public init(suiteName: String) {
        // A missing suite means the App Group entitlement is not configured;
        // fall back to standard so the app still runs, and the widget shows its
        // placeholder rather than crashing.
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    public func save(_ snapshot: WidgetSnapshot) throws {
        defaults.set(try RecordCodec.makeEncoder().encode(snapshot), forKey: key)
    }

    public func load() -> WidgetSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? RecordCodec.makeDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
