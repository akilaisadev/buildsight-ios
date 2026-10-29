import Testing
import Foundation
@testable import BuildSightKit

@Suite("Inspections")
struct InspectionTests {
    private func started() throws -> Inspection {
        try InspectionRules.start(template: InspectionRules.builtInTemplates[0], projectID: Fixture.projectA, areaID: Fixture.areaA, inspectorID: Fixture.supervisor, role: .inspector, location: Fixture.gps, now: Fixture.now).get()
    }

    @Test("Cannot complete while items are unanswered, but progress can be saved")
    func unansweredBlocksCompletion() throws {
        var i = try started()
        i.items[0].result = .pass
        #expect(i.status == .inProgress)
        #expect(InspectionRules.validateCompletion(i) == .unansweredItems(count: 5))
    }

    @Test("A Fail needs a note or a photo")
    func failNeedsEvidence() throws {
        var i = try started()
        for k in i.items.indices { i.items[k].result = .pass }
        i.items[2].result = .fail
        #expect(InspectionRules.validateCompletion(i) == .failedItemNeedsNote(itemID: i.items[2].id))
        i.items[2].note = "Label missing on panel"
        #expect(InspectionRules.validateCompletion(i) == nil)
    }

    @Test("Completion stamps the time and derives the outcome from the answers")
    func outcome() throws {
        var i = try started()
        for k in i.items.indices { i.items[k].result = .pass }
        i.items[1].result = .notApplicable
        let passed = try InspectionRules.complete(i, now: Fixture.now).get()
        #expect(passed.outcome == .passed && passed.completedAt == Fixture.now)

        i.items[0].result = .fail; i.items[0].note = "Frayed"
        let failed = try InspectionRules.complete(i, now: Fixture.now).get()
        #expect(failed.outcome == .failed)
        #expect(InspectionRules.complete(failed, now: Fixture.now) == .failure(.alreadyCompleted))
    }

    @Test("Site workers cannot run inspections")
    func startPermission() {
        let r = InspectionRules.start(template: InspectionRules.builtInTemplates[0], projectID: Fixture.projectA, areaID: Fixture.areaA, inspectorID: Fixture.worker, role: .siteWorker, location: Fixture.gps, now: Fixture.now)
        #expect(r == .failure(.notPermitted))
    }

    @Test("Emergency stop creates a Critical Safety issue and marks the area; only a supervisor clears it")
    func emergencyStop() throws {
        let i = try started()
        let (stopped, issue) = try InspectionRules.raiseEmergencyStop(on: i, reason: "Live cable exposed", actorID: Fixture.supervisor, role: .inspector, now: Fixture.now).get()
        #expect(issue.priority == .critical && issue.category == .safety)
        #expect(stopped.emergencyStop?.raisedIssueID == issue.id)
        #expect(InspectionRules.areasUnderStopWork([stopped]) == [Fixture.areaA])

        #expect(InspectionRules.clearEmergencyStop(on: stopped, actorID: Fixture.worker, role: .inspector, now: Fixture.now) == .failure(.notPermitted))
        let cleared = try InspectionRules.clearEmergencyStop(on: stopped, actorID: Fixture.supervisor, role: .supervisor, now: Fixture.now).get()
        #expect(InspectionRules.areasUnderStopWork([cleared]).isEmpty)
    }

    @Test("Emergency stop needs a reason")
    func stopNeedsReason() throws {
        let r = InspectionRules.raiseEmergencyStop(on: try started(), reason: "  ", actorID: Fixture.supervisor, role: .inspector, now: Fixture.now)
        #expect(r.isFailureWith(.emergencyStopNeedsReason))
    }
}

private extension Result where Failure == InspectionError {
    func isFailureWith(_ error: InspectionError) -> Bool {
        if case .failure(let e) = self { return e == error }
        return false
    }
}

@Suite("Task date grouping")
struct TaskSchedulingTests {
    private let cal = Fixture.calendar

    @Test("Buckets are derived from the due date and status, relative to now")
    func buckets() {
        // now = 25 Sep 12:00
        #expect(TaskScheduling.bucket(for: Fixture.task(due: Fixture.date(day: 25, hour: 16)), now: Fixture.now, calendar: cal) == .today)
        #expect(TaskScheduling.bucket(for: Fixture.task(due: Fixture.date(day: 25, hour: 9)), now: Fixture.now, calendar: cal) == .overdue)
        #expect(TaskScheduling.bucket(for: Fixture.task(due: Fixture.date(day: 24)), now: Fixture.now, calendar: cal) == .overdue)
        #expect(TaskScheduling.bucket(for: Fixture.task(due: Fixture.date(day: 26)), now: Fixture.now, calendar: cal) == .upcoming)
        #expect(TaskScheduling.bucket(for: Fixture.task(status: .completed, due: Fixture.date(day: 1)), now: Fixture.now, calendar: cal) == .done)
    }

    @Test("A task due just before midnight is Today; just after is Upcoming (calendar day, not 24h)")
    func midnightBoundary() {
        let late = cal.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 23, minute: 59))!
        let next = cal.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 0, minute: 1))!
        #expect(TaskScheduling.bucket(for: Fixture.task(due: late), now: Fixture.now, calendar: cal) == .today)
        #expect(TaskScheduling.bucket(for: Fixture.task(due: next), now: Fixture.now, calendar: cal) == .upcoming)
    }

    @Test("Completing moves a task to Done and reopening takes it back out")
    func completeAndReopen() throws {
        let task = Fixture.task(due: Fixture.date(day: 26))
        let started = try TaskScheduling.start(task, now: Fixture.now).get()
        let done = try TaskScheduling.complete(started, now: Fixture.now).get()
        #expect(TaskScheduling.bucket(for: done, now: Fixture.now, calendar: cal) == .done)
        #expect(done.completedAt == Fixture.now)
        let reopened = try TaskScheduling.reopen(done, now: Fixture.now).get()
        #expect(reopened.completedAt == nil && reopened.status == .inProgress)
        #expect(TaskScheduling.bucket(for: reopened, now: Fixture.now, calendar: cal) == .upcoming)
    }

    @Test("Invalid transitions are rejected")
    func invalid() {
        let done = Fixture.task(status: .completed, due: Fixture.date(day: 26))
        #expect(TaskScheduling.complete(done, now: Fixture.now).isFailure)
        #expect(TaskScheduling.start(done, now: Fixture.now).isFailure)
        #expect(TaskScheduling.reopen(Fixture.task(due: Fixture.date(day: 26)), now: Fixture.now).isFailure)
    }

    @Test("Grouping keeps overdue tasks oldest-first and every task in exactly one bucket")
    func grouping() {
        let tasks = [Fixture.task(due: Fixture.date(day: 23)), Fixture.task(due: Fixture.date(day: 21)), Fixture.task(due: Fixture.date(day: 25, hour: 17)), Fixture.task(status: .completed, due: Fixture.date(day: 20))]
        let g = TaskScheduling.grouped(tasks, now: Fixture.now, calendar: cal)
        #expect(g.values.map(\.count).reduce(0, +) == tasks.count)
        #expect(g[.overdue]?.map(\.dueDate) == [Fixture.date(day: 21), Fixture.date(day: 23)])
    }
}

private extension Result {
    var isFailure: Bool { if case .failure = self { return true } else { return false } }
}

@Suite("Deep links and QR payloads")
struct LinkTests {
    @Test("Every deep link round-trips through its URL")
    func roundTrip() {
        let links: [DeepLink] = [
            .issue(projectID: Fixture.projectA, issueID: UUID()),
            .helmetFlags(projectID: Fixture.projectA, unreviewedOnly: true),
            .helmetFlags(projectID: Fixture.projectA, unreviewedOnly: false),
            .map(projectID: Fixture.projectA),
            .task(projectID: Fixture.projectA, taskID: UUID()),
            .inspection(projectID: Fixture.projectA, inspectionID: UUID()),
        ]
        for link in links { #expect(DeepLink(url: link.url) == link) }
    }

    @Test("Malformed or foreign URLs are rejected")
    func rejects() {
        #expect(DeepLink(url: URL(string: "https://example.com/issue/1")!) == nil)
        #expect(DeepLink(url: URL(string: "buildsight://issue/not-a-uuid/also-bad")!) == nil)
        #expect(DeepLink(url: URL(string: "buildsight://unknown/\(Fixture.projectA)")!) == nil)
    }

    @Test("QR codes must belong to the active project and a known area")
    func qrValidation() {
        let areas = [SiteArea(id: Fixture.areaA, projectID: Fixture.projectA, name: "North Wing", level: "L2")]
        let good = AreaQRPayload.makeString(projectID: Fixture.projectA, areaID: Fixture.areaA)
        #expect(AreaQRPayload.resolve(good, activeProject: Fixture.projectA, areas: areas) == .success(areas[0]))

        let other = AreaQRPayload.makeString(projectID: Fixture.projectB, areaID: Fixture.areaB)
        #expect(AreaQRPayload.resolve(other, activeProject: Fixture.projectA, areas: areas) == .failure(.wrongProject))

        let unknown = AreaQRPayload.makeString(projectID: Fixture.projectA, areaID: UUID())
        #expect(AreaQRPayload.resolve(unknown, activeProject: Fixture.projectA, areas: areas) == .failure(.unknownArea))
        #expect(AreaQRPayload.resolve("https://wifi.example/join", activeProject: Fixture.projectA, areas: areas) == .failure(.notABuildSightCode))
    }
}

@Suite("Location fixes")
struct LocationTests {
    @Test("Invalid or placeholder coordinates are never treated as a position")
    func unusable() {
        #expect(LocationFix.gps(GeoPoint(latitude: 0, longitude: 0, horizontalAccuracy: 5)).point == nil)
        #expect(LocationFix.gps(GeoPoint(latitude: 6.9, longitude: 79.8, horizontalAccuracy: -1)).point == nil)
        #expect(LocationFix.unavailable(.permissionDenied).point == nil)
        #expect(Fixture.gps.point != nil)
    }

    @Test("Coarse fixes are flagged approximate")
    func approximate() {
        #expect(!Fixture.gps.isApproximate)
        #expect(LocationFix.gps(GeoPoint(latitude: 6.9, longitude: 79.8, horizontalAccuracy: 120)).isApproximate)
    }
}
