import Foundation

/// Recomputes the widget snapshot from stored records and writes it to the
/// shared container. WidgetKit decides when a widget actually refreshes; this
/// only guarantees the data it will read is current whenever the app changes
/// something. `reloadTimelines` is injected so the package stays free of WidgetKit.
public struct WidgetSnapshotPublisher: Sendable {
    private let repository: ProjectRepository
    private let snapshots: WidgetSnapshotStore
    private let reloadTimelines: @Sendable () -> Void
    private let clock: @Sendable () -> Date
    private let calendar: Calendar

    public init(repository: ProjectRepository, snapshots: WidgetSnapshotStore, calendar: Calendar = .current, clock: @escaping @Sendable () -> Date = { Date() }, reloadTimelines: @escaping @Sendable () -> Void) {
        self.repository = repository
        self.snapshots = snapshots
        self.calendar = calendar
        self.clock = clock
        self.reloadTimelines = reloadTimelines
    }

    @discardableResult
    public func publish(projectID: UUID) async -> WidgetSnapshot? {
        guard let data = try? await repository.snapshot(projectID: projectID) else { return nil }
        let now = clock()
        let summary = DashboardCalculator.summary(projectID: projectID, issues: data.issues, tasks: data.tasks, inspections: data.inspections, now: now, calendar: calendar)
        let snapshot = WidgetSnapshot.make(project: data.project, summary: summary, areas: data.areas, now: now)
        guard (try? snapshots.save(snapshot)) != nil else { return nil }
        reloadTimelines()
        return snapshot
    }
}
