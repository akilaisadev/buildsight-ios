import Testing
import Foundation
@testable import BuildSightKit

@Suite("Dashboard, timeline, map and widget summaries")
struct SummaryTests {
    private let cal = Fixture.calendar

    private func flag(review: HumanReviewStatus, project: UUID = Fixture.projectA, createdDay: Int = 25) -> Issue {
        var i = Fixture.issue(status: .open, review: review, origin: .helmetDetection(analysisID: UUID()), project: project, priority: .high)
        i.createdAt = Fixture.date(day: createdDay)
        return i
    }

    @Test("Open issues are counted by priority and exclude verified, closed and dismissed")
    func openByPriority() {
        let issues = [
            Fixture.issue(status: .open, priority: .critical),
            Fixture.issue(status: .inProgress, priority: .critical),
            Fixture.issue(status: .resolved, priority: .low),
            Fixture.issue(status: .verified, priority: .high),
            Fixture.issue(status: .closed, priority: .high),
            flag(review: .dismissed),
        ]
        let s = DashboardCalculator.summary(projectID: Fixture.projectA, issues: issues, tasks: [], inspections: [], now: Fixture.now, calendar: cal)
        #expect(s.openIssuesByPriority[.critical] == 2)
        #expect(s.openIssuesByPriority[.low] == 1)
        #expect(s.openIssuesByPriority[.high] == 0)
        #expect(s.openIssueTotal == 3)
        #expect(s.issuesSignedOff == 2 && s.issuesTotal == 5)   // dismissed flag excluded from the denominator
    }

    @Test("Another project's records never leak into this project's numbers")
    func projectIsolation() {
        let issues = [Fixture.issue(status: .open, project: Fixture.projectA), Fixture.issue(status: .open, project: Fixture.projectB), flag(review: .awaitingReview, project: Fixture.projectB)]
        let tasks = [Fixture.task(due: Fixture.date(day: 26), project: Fixture.projectB)]
        let s = DashboardCalculator.summary(projectID: Fixture.projectA, issues: issues, tasks: tasks, inspections: [], now: Fixture.now, calendar: cal)
        #expect(s.openIssueTotal == 1)
        #expect(s.helmet.unreviewed == 0)
        #expect(s.taskCounts.values.reduce(0, +) == 0)
    }

    @Test("Helmet flag summary separates unreviewed, confirmed and dismissed and never merges them")
    func helmetSummary() {
        let issues = [flag(review: .awaitingReview), flag(review: .awaitingReview, createdDay: 20), flag(review: .confirmed), flag(review: .corrected), flag(review: .dismissed)]
        let h = DashboardCalculator.helmetSummary(issues: issues, now: Fixture.now, calendar: cal)
        #expect(h.unreviewed == 2)
        #expect(h.confirmed == 2)
        #expect(h.dismissed == 1)
        #expect(h.flagsToday == 4)
    }

    @Test("Inspections due counts unfinished inspections due by end of today, not completed ones or future ones")
    func inspectionsDue() throws {
        var dueToday = try InspectionRules.start(template: InspectionRules.builtInTemplates[0], projectID: Fixture.projectA, areaID: Fixture.areaA, inspectorID: Fixture.supervisor, role: .inspector, location: Fixture.gps, now: Fixture.now, dueDate: Fixture.date(day: 25, hour: 17)).get()
        let future = try InspectionRules.start(template: InspectionRules.builtInTemplates[1], projectID: Fixture.projectA, areaID: Fixture.areaA, inspectorID: Fixture.supervisor, role: .inspector, location: Fixture.gps, now: Fixture.now, dueDate: Fixture.date(day: 28)).get()
        var done = dueToday; done.completedAt = Fixture.now
        let s1 = DashboardCalculator.summary(projectID: Fixture.projectA, issues: [], tasks: [], inspections: [dueToday, future], now: Fixture.now, calendar: cal)
        #expect(s1.inspectionsDue == 1)
        dueToday = done
        let s2 = DashboardCalculator.summary(projectID: Fixture.projectA, issues: [], tasks: [], inspections: [dueToday, future], now: Fixture.now, calendar: cal)
        #expect(s2.inspectionsDue == 0)
    }

    @Test("Helmet flags appear on the timeline once, typed as flags, and filters narrow them")
    func timelineFlagsAndFilters() {
        let photo = Fixture.photo()
        let manual = Fixture.issue(status: .open)
        let machine = flag(review: .awaitingReview)
        let events = TimelineBuilder.events(projectID: Fixture.projectA, photos: [photo], issues: [manual, machine], inspections: [], tasks: [])
        #expect(events.count == 3)
        #expect(events.filter { $0.ref.kind == .helmetFlag }.count == 1)
        #expect(events.filter { $0.ref.kind == .issue }.count == 1)

        let flagsOnly = TimelineBuilder.sections(events, filter: TimelineFilter(kinds: [.helmetFlag]), calendar: cal)
        #expect(flagsOnly.flatMap(\.events).map(\.ref.id) == [machine.id])
        let awaiting = TimelineBuilder.sections(events, filter: TimelineFilter(statusLabel: "Awaiting review"), calendar: cal)
        #expect(awaiting.flatMap(\.events).count == 1)
        let otherArea = TimelineBuilder.sections(events, filter: TimelineFilter(areaIDs: [UUID()]), calendar: cal)
        #expect(otherArea.isEmpty)
        let person = TimelineBuilder.sections(events, filter: TimelineFilter(personID: Fixture.supervisor), calendar: cal)
        #expect(person.isEmpty)
    }

    @Test("Timeline groups by day newest first and respects the date range")
    func timelineGrouping() {
        var old = Fixture.issue(); old.createdAt = Fixture.date(day: 20)
        var recent = Fixture.issue(); recent.createdAt = Fixture.date(day: 25)
        let events = TimelineBuilder.events(projectID: Fixture.projectA, photos: [], issues: [old, recent], inspections: [], tasks: [])
        let all = TimelineBuilder.sections(events, filter: TimelineFilter(), calendar: cal)
        #expect(all.count == 2 && all[0].day > all[1].day)
        let ranged = TimelineBuilder.sections(events, filter: TimelineFilter(dateRange: Fixture.date(day: 24)...Fixture.date(day: 26)), calendar: cal)
        #expect(ranged.flatMap(\.events).count == 1)
    }

    @Test("The map pins only real GPS fixes and lists the rest separately")
    func mapNoInventedCoordinates() {
        var noGPS = Fixture.issue(); noGPS.location = .unavailable(.permissionDenied)
        let withGPS = Fixture.issue()
        let projection = MapProjector.project(projectID: Fixture.projectA, photos: [], issues: [noGPS, withGPS], inspections: [])
        #expect(projection.items.map(\.ref.id) == [withGPS.id])
        #expect(projection.withoutLocation.map(\.id) == [noGPS.id])
    }

    @Test("A task is pinned only through a related issue that has a real fix")
    func mapTasks() {
        let issue = Fixture.issue()
        var linked = Fixture.task(due: Fixture.date(day: 26)); linked.relatedIssueID = issue.id
        let loose = Fixture.task(due: Fixture.date(day: 26))
        let p = MapProjector.project(projectID: Fixture.projectA, photos: [], issues: [issue], inspections: [], tasks: [linked, loose])
        #expect(p.items.contains { $0.ref.id == linked.id })
        #expect(p.withoutLocation.map(\.id) == [loose.id])
    }

    @Test("Widget snapshot carries the same definitions as the dashboard and round-trips through storage")
    func widgetSnapshot() throws {
        let project = Project(id: Fixture.projectA, name: "Central Tower", locationName: "Colombo", status: .active, startDate: Fixture.now, endDate: Fixture.now, managerName: "M", centre: nil)
        let area = SiteArea(id: Fixture.areaA, projectID: Fixture.projectA, name: "North Wing", level: "L2")
        let issues = [flag(review: .awaitingReview), flag(review: .confirmed), Fixture.issue(status: .open, priority: .critical)]
        let summary = DashboardCalculator.summary(projectID: Fixture.projectA, issues: issues, tasks: [], inspections: [], now: Fixture.now, calendar: cal)
        let snap = WidgetSnapshot.make(project: project, summary: summary, areas: [area], now: Fixture.now)
        #expect(snap.unreviewedFlags == 1 && snap.confirmedFindings == 1 && snap.openCritical == 1)
        #expect(snap.topAreaName == "North Wing")

        let store = UserDefaultsWidgetSnapshotStore(suiteName: "bs.test.\(UUID().uuidString)")
        try store.save(snap)
        #expect(store.load() == snap)
    }
}
