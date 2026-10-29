import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import BuildSightKit

struct FixedLocation: LocationProviding {
    var permission: LocationPermission = .whenInUse
    var fix: LocationFix
    func currentFix(timeout: TimeInterval) async -> LocationFix { fix }
}

final class RecordingSync: SyncTriggering, @unchecked Sendable {
    private(set) var requests = 0
    func requestSync() async { requests += 1 }
}

/// A real, tiny JPEG so the evidence store exercises ImageIO for real.
func makeJPEG(width: Int = 640, height: Int = 480) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

@MainActor
@Suite("Capture view model: the connected evidence workflow")
struct CaptureViewModelTests {
    let actor = ActingUser(userID: Fixture.worker, displayName: "Alex", role: .siteWorker, projectID: Fixture.projectA)
    let area = SiteArea(id: Fixture.areaA, projectID: Fixture.projectA, name: "North Wing", level: "L2")

    private func makeVM(analyzer: ScriptedAnalyzer?, location: LocationFix = Fixture.gps, store: CoreDataLocalStore, sync: RecordingSync = RecordingSync()) throws -> (CaptureViewModel, EvidenceFileStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("evidence-\(UUID().uuidString)")
        let files = try EvidenceFileStore(directory: dir)
        let workflow = HelmetWorkflow(analyzer: analyzer, store: store) { files.url(forFilename: $0.localFilename) }
        let vm = CaptureViewModel(actor: actor, areas: [area], store: store, files: files, location: FixedLocation(fix: location), workflow: workflow, sync: sync, clock: { Fixture.now })
        return (vm, files)
    }

    @Test("Capture → save locally → analyse → suspected-missing-helmet issue → review → record reopens from storage")
    func endToEnd() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let sync = RecordingSync()
        let (vm, files) = try makeVM(analyzer: .detecting([Fixture.obs(.noHelmet, 0.9)]), store: store, sync: sync)

        vm.photoCaptured(makeJPEG())
        #expect(vm.phase == .review && !vm.canSave)            // no area chosen yet
        vm.selectedAreaID = area.id
        vm.category = .safety
        vm.note = "Scaffold, level 2"
        #expect(vm.canSave)
        await vm.saveAndAnalyse()

        #expect(vm.phase == .finished)
        let outcome = try #require(vm.outcome)
        let photo = outcome.photo
        #expect(photo.projectID == Fixture.projectA && photo.areaID == area.id && photo.creatorID == actor.userID)
        #expect(photo.capturedAt == Fixture.now && photo.location == Fixture.gps)
        #expect(photo.pixelWidth == 640 && photo.pixelHeight == 480)
        #expect(FileManager.default.fileExists(atPath: files.url(forFilename: photo.localFilename).path))
        #expect(outcome.createdNewIssue)
        #expect(sync.requests >= 1)

        // "Reopen the saved record": everything is readable back from Core Data.
        let storedPhoto = try #require(try await store.record(EvidencePhoto.self, id: photo.id))
        #expect(storedPhoto.note == "Scaffold, level 2")
        let issue = try #require(outcome.issue)
        let workflow = HelmetWorkflow(analyzer: nil, store: store) { files.url(forFilename: $0.localFilename) }
        let reviewed = try await workflow.review(analysisID: outcome.analysis.id, decision: .confirm, reviewerID: Fixture.supervisor, role: .supervisor, now: Fixture.now).get()
        #expect(reviewed.issue.review == .confirmed)
        #expect(try await store.record(Issue.self, id: issue.id)?.review == .confirmed)
    }

    @Test("When analysis fails the photo is still saved and the result says so, without creating an issue")
    func analysisFailureKeepsPhoto() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let (vm, _) = try makeVM(analyzer: ScriptedAnalyzer(result: .failure(.inferenceFailed("no gpu"))), store: store)
        vm.photoCaptured(makeJPEG()); vm.selectedAreaID = area.id
        await vm.saveAndAnalyse()
        let outcome = try #require(vm.outcome)
        guard case .failed = outcome.analysis.state else { Testing.Issue.record("expected failed analysis"); return }
        #expect(outcome.issue == nil)
        #expect(try await store.record(EvidencePhoto.self, id: outcome.photo.id) != nil)
    }

    @Test("Denied location saves the photo with an explicit unavailable reason, never coordinates")
    func locationUnavailable() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let (vm, _) = try makeVM(analyzer: .detecting([]), location: .unavailable(.permissionDenied), store: store)
        vm.photoCaptured(makeJPEG()); vm.selectedAreaID = area.id
        await vm.saveAndAnalyse()
        #expect(vm.outcome?.photo.location == .unavailable(.permissionDenied))
        #expect(vm.outcome?.photo.location.point == nil)
    }

    @Test("Cancelling review discards the image and persists nothing")
    func cancel() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let (vm, _) = try makeVM(analyzer: .detecting([]), store: store)
        vm.photoCaptured(makeJPEG()); vm.selectedAreaID = area.id
        vm.cancel()
        #expect(vm.phase == .camera && vm.capturedJPEG == nil)
        #expect(try await store.records(EvidencePhoto.self, projectID: Fixture.projectA).isEmpty)
    }

    @Test("An unreadable image fails cleanly before anything is stored")
    func corruptImage() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let (vm, _) = try makeVM(analyzer: .detecting([]), store: store)
        vm.photoCaptured(Data([0, 1, 2, 3])); vm.selectedAreaID = area.id
        await vm.saveAndAnalyse()
        guard case .failed = vm.phase else { Testing.Issue.record("expected failure"); return }
        #expect(try await store.records(EvidencePhoto.self, projectID: Fixture.projectA).isEmpty)
    }

    @Test("Areas from another project are not offered")
    func areaScoping() throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("e-\(UUID().uuidString)")
        let files = try EvidenceFileStore(directory: dir)
        let other = SiteArea(id: Fixture.areaB, projectID: Fixture.projectB, name: "Elsewhere", level: "")
        let vm = CaptureViewModel(actor: actor, areas: [area, other], store: store, files: files, location: FixedLocation(fix: Fixture.gps), workflow: HelmetWorkflow(analyzer: nil, store: store) { _ in dir })
        #expect(vm.areas.map(\.id) == [area.id])
    }
}

@Suite("Evidence file store")
struct EvidenceFileStoreTests {
    @Test("Stores an upright JPEG under the photo id and reports its true size")
    func saves() throws {
        let files = try EvidenceFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID().uuidString)"))
        let id = UUID()
        let saved = try files.save(jpeg: makeJPEG(width: 800, height: 600), photoID: id)
        #expect(saved.filename == "\(id.uuidString).jpg" && saved.pixelWidth == 800 && saved.pixelHeight == 600)
        #expect(FileManager.default.fileExists(atPath: files.url(forFilename: saved.filename).path))
        files.delete(filename: saved.filename)
        #expect(!FileManager.default.fileExists(atPath: files.url(forFilename: saved.filename).path))
    }

    @Test("A hostile filename cannot escape the evidence folder")
    func pathTraversal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID().uuidString)")
        let files = try EvidenceFileStore(directory: dir)
        let url = files.url(forFilename: "../../etc/passwd")
        #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
    }

    @Test("Garbage input is rejected")
    func rejects() throws {
        let files = try EvidenceFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID().uuidString)"))
        #expect(throws: EvidenceFileError.unreadableImage) { try files.save(jpeg: Data([1, 2, 3]), photoID: UUID()) }
    }
}

@MainActor
@Suite("Issue, task and inspection view models")
struct WorkViewModelTests {
    let supervisor = ActingUser(userID: Fixture.supervisor, displayName: "Sam", role: .supervisor, projectID: Fixture.projectA)
    let worker = ActingUser(userID: Fixture.worker, displayName: "Alex", role: .siteWorker, projectID: Fixture.projectA)

    final class DenyGate: ReauthenticationGate, @unchecked Sendable {
        var allow = false
        func confirmSensitiveAction(reason: String) async -> Bool { allow }
    }

    private func detail(for issue: Issue, as actor: ActingUser, store: CoreDataLocalStore, gate: ReauthenticationGate = AlwaysAllowGate()) -> IssueDetailViewModel {
        IssueDetailViewModel(issueID: issue.id, actor: actor, issues: IssueRepository(store: store), workflow: HelmetWorkflow(analyzer: nil, store: store) { _ in URL(fileURLWithPath: "/") }, session: gate, clock: { Fixture.now })
    }

    @Test("Transitions persist, add audit events and are visible to the next read")
    func transitionPersists() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let issue = Fixture.issue(assignee: Fixture.worker)
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt)])
        let vm = detail(for: issue, as: worker, store: store)
        #expect(await vm.perform(.start))
        #expect(try await store.record(Issue.self, id: issue.id)?.status == .inProgress)
        #expect(vm.events.contains { $0.kind == .statusChanged(from: .open, to: .inProgress) })
    }

    @Test("A rejected transition surfaces a plain-language message and changes nothing")
    func rejectedTransition() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let issue = Fixture.issue(status: .verified)
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt)])
        let vm = detail(for: issue, as: worker, store: store)
        #expect(!(await vm.perform(.close)))
        #expect(vm.errorMessage == "Your role can't do that on this issue.")
        #expect(try await store.record(Issue.self, id: issue.id)?.status == .verified)
    }

    @Test("Closing needs the biometric re-check; declining it leaves the issue verified")
    func closeNeedsReauth() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let issue = Fixture.issue(status: .verified)
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt)])
        let gate = DenyGate()
        let vm = detail(for: issue, as: supervisor, store: store, gate: gate)
        #expect(!(await vm.perform(.close)))
        #expect(try await store.record(Issue.self, id: issue.id)?.status == .verified)
        gate.allow = true
        #expect(await vm.perform(.close))
        #expect(try await store.record(Issue.self, id: issue.id)?.status == .closed)
    }

    @Test("Comments are saved as audit events; blank comments are refused")
    func comments() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let issue = Fixture.issue()
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt)])
        let vm = detail(for: issue, as: worker, store: store)
        vm.comment = "   "; await vm.addComment()
        #expect(vm.errorMessage == "Write a comment first.")
        vm.comment = "Photo attached"; await vm.addComment()
        #expect(vm.events.map(\.note).contains("Photo attached"))
    }

    @Test("A draft saves and reloads without syncing, then submit creates a synced-pending issue and removes the draft")
    func draftThenSubmit() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let vm = ReportIssueViewModel(actor: worker, areaID: Fixture.areaA, issues: IssueRepository(store: store), store: store, location: FixedLocation(fix: Fixture.gps), clock: { Fixture.now })
        vm.draft.title = "Loose handrail"
        await vm.saveDraft()
        #expect(try await store.drafts(projectID: Fixture.projectA).count == 1)
        #expect(try await store.pendingOperations().isEmpty)

        vm.draft.priority = .critical
        #expect(await vm.submit())
        #expect(try await store.drafts(projectID: Fixture.projectA).isEmpty)
        let issues = try await store.records(Issue.self, projectID: Fixture.projectA)
        #expect(issues.count == 1 && issues[0].priority == .critical && issues[0].reporterID == Fixture.worker)
        #expect(try await store.pendingOperations().contains { $0.recordType == .issue })
    }

    @Test("Submitting without a title or area is blocked with guidance")
    func submitValidation() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let vm = ReportIssueViewModel(actor: worker, issues: IssueRepository(store: store), store: store, location: FixedLocation(fix: Fixture.gps), clock: { Fixture.now })
        #expect(!(await vm.submit()))
        #expect(vm.errorMessage != nil)
        #expect(try await store.records(Issue.self, projectID: Fixture.projectA).isEmpty)
    }

    @Test("Task actions update the same record the list reads, so detail and list cannot disagree")
    func taskConsistency() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let repo = TaskRepository(store: store)
        let vm = TaskListViewModel(actor: supervisor, tasks: repo, clock: { Fixture.now }, calendar: Fixture.calendar)
        #expect(await vm.create(title: "Fix barrier", details: "", areaID: Fixture.areaA, assigneeID: Fixture.worker, priority: .high, dueDate: Fixture.date(day: 25, hour: 17), relatedIssueID: nil))
        let task = try #require(try await store.records(TaskItem.self, projectID: Fixture.projectA).first)

        let repository = ProjectRepository(store: store)
        try await store.commit([try RecordWrite(Project(id: Fixture.projectA, name: "P", locationName: "", status: .active, startDate: Fixture.now, endDate: Fixture.now, managerName: "", centre: nil), sortDate: Fixture.now, enqueue: false)])
        var snap = try #require(try await repository.snapshot(projectID: Fixture.projectA))
        #expect(vm.grouped(snap)[.today]?.map(\.id) == [task.id])

        await vm.perform(.complete, on: task.id)
        snap = try #require(try await repository.snapshot(projectID: Fixture.projectA))
        #expect(vm.grouped(snap)[.done]?.map(\.id) == [task.id])
        #expect(vm.grouped(snap)[.today]?.isEmpty == true)
    }

    @Test("Site workers cannot create tasks")
    func workerCannotCreateTask() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let vm = TaskListViewModel(actor: worker, tasks: TaskRepository(store: store), clock: { Fixture.now })
        #expect(!vm.canCreate)
        #expect(!(await vm.create(title: "x", details: "", areaID: nil, assigneeID: Fixture.worker, priority: .low, dueDate: Fixture.now, relatedIssueID: nil)))
    }

    @Test("Inspection: progress saves, completion is blocked with a specific message, then succeeds")
    func inspectionFlow() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let repo = InspectionRepository(store: store)
        let inspector = ActingUser(userID: Fixture.supervisor, displayName: "Sam", role: .inspector, projectID: Fixture.projectA)
        let inspection = try await repo.start(template: InspectionRules.builtInTemplates[0], areaID: Fixture.areaA, actor: inspector, location: Fixture.gps, now: Fixture.now)
        let vm = InspectionRunViewModel(inspection: inspection, actor: inspector, repository: repo, clock: { Fixture.now })

        vm.set(.pass, for: vm.inspection.items[0].id)
        await vm.saveProgress()
        #expect(try await store.record(Inspection.self, id: inspection.id)?.answeredCount == 1)
        await vm.complete()
        #expect(vm.errorMessage == "5 items still need a result.")

        for item in vm.inspection.items { vm.set(.pass, for: item.id) }
        vm.set(.fail, for: vm.inspection.items[2].id)
        await vm.complete()
        #expect(vm.errorMessage?.contains("Panel labelling") == true)
        vm.setNote("Label missing", for: vm.inspection.items[2].id)
        await vm.complete()
        #expect(vm.completed && vm.isReadOnly)
        #expect(try await store.record(Inspection.self, id: inspection.id)?.outcome == .failed)
    }

    @Test("Emergency stop persists the stop, a Critical issue and a notification together")
    func emergencyStop() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let repo = InspectionRepository(store: store)
        let inspector = ActingUser(userID: Fixture.supervisor, displayName: "Sam", role: .inspector, projectID: Fixture.projectA)
        let inspection = try await repo.start(template: InspectionRules.builtInTemplates[1], areaID: Fixture.areaA, actor: inspector, location: Fixture.gps, now: Fixture.now)
        let vm = InspectionRunViewModel(inspection: inspection, actor: inspector, repository: repo, clock: { Fixture.now })
        #expect(await vm.raiseEmergencyStop(reason: "Unstable scaffold"))
        #expect(vm.inspection.emergencyStop?.isActive == true)
        let issues = try await store.records(Issue.self, projectID: Fixture.projectA)
        #expect(issues.count == 1 && issues[0].priority == .critical)
        #expect(try await store.records(AppNotification.self, projectID: Fixture.projectA).map(\.kind) == [.emergencyStop])
    }
}

@MainActor
@Suite("Dashboard, map and issue filters")
struct DashboardViewModelTests {
    private func snapshot(issues: [Issue]) -> ProjectSnapshot {
        let project = Project(id: Fixture.projectA, name: "P", locationName: "", status: .active, startDate: Fixture.now, endDate: Fixture.now, managerName: "", centre: nil)
        return ProjectSnapshot(project: project, areas: [], members: [], photos: [], issues: issues, inspections: [], tasks: [], analyses: [], notifications: [])
    }

    @Test("Tiles are derived from stored records and each links to a filter that reproduces its count")
    func tilesMatchFilters() {
        let flagged = Fixture.issue(review: .awaitingReview, origin: .helmetDetection(analysisID: UUID()), priority: .high)
        let issues = [Fixture.issue(priority: .critical), Fixture.issue(status: .resolved, priority: .low), Fixture.issue(status: .closed), flagged]
        let snap = snapshot(issues: issues)
        let vm = DashboardViewModel(clock: { Fixture.now }, calendar: Fixture.calendar)
        vm.update(from: snap)

        let open = vm.tiles.first { $0.id == "open" }!
        guard case .issues(let filter) = open.destination else { Testing.Issue.record("wrong destination"); return }
        #expect(open.value == issues.filter(filter.matches).count)
        #expect(open.value == 3)

        let flags = vm.tiles.first { $0.id == "flags" }!
        #expect(flags.value == 1)
        #expect(flags.destination == .helmetFlags(unreviewedOnly: true))
    }

    @Test("Issue filters combine and search narrows")
    func filters() {
        let a = Fixture.issue(priority: .critical)
        var b = Fixture.issue(priority: .low); b.title = "Water leak"
        let snap = snapshot(issues: [a, b])
        let vm = IssueListViewModel(filter: IssueFilter(priorities: [.critical]))
        #expect(vm.issues(in: snap).map(\.id) == [a.id])
        vm.filter = IssueFilter(); vm.search = "water"
        #expect(vm.issues(in: snap).map(\.id) == [b.id])
    }

    @Test("Map layers toggle and a denied permission explains itself")
    func mapFilters() {
        let issue = Fixture.issue(); let photo = Fixture.photo()
        var snap = snapshot(issues: [issue]); snap.photos = [photo]
        let vm = MapViewModel(locationPermission: .denied)
        #expect(vm.projection(for: snap).items.count == 2)
        vm.toggle(.photo)
        #expect(vm.projection(for: snap).items.map(\.ref.kind) == [.issue])
        #expect(vm.permissionNotice()?.contains("Location access is off") == true)
    }

    @Test("Reminders are planned only for the user's own future items and respect preferences and the cap")
    func reminders() {
        var prefs = NotificationPreferences()
        let mine = Fixture.task(due: Fixture.date(day: 26))
        var theirs = Fixture.task(due: Fixture.date(day: 26)); theirs.assigneeID = UUID()
        let overdue = Fixture.task(due: Fixture.date(day: 20))
        let done = Fixture.task(status: .completed, due: Fixture.date(day: 27))
        let plan = ReminderPlanner.plan(tasks: [mine, theirs, overdue, done], inspections: [], assignedTo: Fixture.worker, preferences: prefs, now: Fixture.now)
        #expect(plan.map(\.identifier) == ["task-\(mine.id.uuidString)"])
        #expect(plan[0].fireDate == mine.dueDate.addingTimeInterval(-30 * 60))
        prefs.taskReminders = false
        #expect(ReminderPlanner.plan(tasks: [mine], inspections: [], assignedTo: Fixture.worker, preferences: prefs, now: Fixture.now).isEmpty)

        let many = (0..<80).map { i in Fixture.task(due: Fixture.date(day: 26).addingTimeInterval(Double(i) * 60)) }
        #expect(ReminderPlanner.plan(tasks: many, inspections: [], assignedTo: Fixture.worker, preferences: NotificationPreferences(), now: Fixture.now).count == ReminderPlanner.maxPending)
    }
}
