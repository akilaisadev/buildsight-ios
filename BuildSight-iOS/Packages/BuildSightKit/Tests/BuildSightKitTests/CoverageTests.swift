import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import BuildSightKit

// MARK: - Roles

@Suite("Role permissions")
struct RolePermissionTests {
    @Test("Everyone can report an issue", arguments: Role.allCases)
    func reportIssue(_ r: Role) { #expect(r.can(.reportIssue)) }

    @Test("Everyone but an inspector can move an issue along", arguments: Role.allCases)
    func progressIssue(_ r: Role) { #expect(r.can(.progressIssue) == (r != .inspector)) }

    @Test("Verifying is for supervisors, inspectors and project managers", arguments: Role.allCases)
    func verifyIssue(_ r: Role) { #expect(r.can(.verifyIssue) == [.supervisor, .inspector, .projectManager].contains(r)) }

    @Test("Closing is for supervisors and project managers", arguments: Role.allCases)
    func closeIssue(_ r: Role) { #expect(r.can(.closeIssue) == [.supervisor, .projectManager].contains(r)) }

    @Test("Reopening matches closing", arguments: Role.allCases)
    func reopenIssue(_ r: Role) { #expect(r.can(.reopenIssue) == r.can(.closeIssue)) }

    @Test("Clearing an emergency stop matches closing", arguments: Role.allCases)
    func clearStop(_ r: Role) { #expect(r.can(.clearEmergencyStop) == r.can(.closeIssue)) }

    @Test("Reviewing helmet flags is for supervisors, inspectors and project managers", arguments: Role.allCases)
    func reviewFlag(_ r: Role) { #expect(r.can(.reviewHelmetFlag) == [.supervisor, .inspector, .projectManager].contains(r)) }

    @Test("Only a site worker cannot create tasks", arguments: Role.allCases)
    func createTask(_ r: Role) { #expect(r.can(.createTask) == (r != .siteWorker)) }

    @Test("Inspections are run by inspectors, supervisors and engineers", arguments: Role.allCases)
    func runInspection(_ r: Role) { #expect(r.can(.runInspection) == [.inspector, .supervisor, .engineer].contains(r)) }

    @Test("Anyone on site can raise an emergency stop", arguments: Role.allCases)
    func raiseStop(_ r: Role) { #expect(r.can(.raiseEmergencyStop)) }

    @Test("Every role has a distinct, readable name")
    func names() {
        let names = Role.allCases.map(\.displayName)
        #expect(Set(names).count == Role.allCases.count)
        #expect(names.allSatisfy { !$0.isEmpty })
    }

    @Test("A membership remembers its project and role")
    func membership() {
        let m = ProjectMembership(projectID: Fixture.projectA, role: .engineer)
        #expect(m.projectID == Fixture.projectA && m.role == .engineer)
    }

    @Test("A profile lists only the projects it belongs to")
    func profileProjects() {
        let profile = UserProfile(id: Fixture.worker, displayName: "Alex", email: "a@b.co", organisationName: "Org",
                                  memberships: [ProjectMembership(projectID: Fixture.projectA, role: .siteWorker)])
        #expect(profile.projectIDs == [Fixture.projectA])
        #expect(profile.role(in: Fixture.projectA) == .siteWorker)
        #expect(profile.role(in: Fixture.projectB) == nil)
    }
}

// MARK: - Auth models

@Suite("Auth models")
struct AuthModelTests {
    @Test("Every sign-in error has a plain message", arguments: [
        (AuthError.invalidCredentials, "Email or password is incorrect."),
        (.emailNotConfirmed, "Confirm your email address first, then sign in."),
        (.accountDisabled, "This account has been disabled. Contact your project administrator."),
        (.sessionExpired, "Your session has expired. Please sign in again."),
        (.network, "No connection. Check your network and try again."),
        (.other("Something specific"), "Something specific"),
    ])
    func messages(_ c: (error: AuthError, text: String)) { #expect(c.error.userMessage == c.text) }

    private func session(expiresIn seconds: TimeInterval) -> AuthSession {
        AuthSession(accessToken: "a", refreshToken: "r", expiresAt: Fixture.now.addingTimeInterval(seconds), userID: Fixture.worker)
    }

    @Test("A session is treated as expired 30 seconds early", arguments: [(-100.0, true), (0.0, true), (30.0, true), (31.0, false), (3600.0, false)])
    func expiry(_ c: (seconds: Double, expired: Bool)) {
        #expect(session(expiresIn: c.seconds).isExpired(at: Fixture.now) == c.expired)
    }

    @Test("The early-expiry margin can be changed")
    func customLeeway() {
        #expect(!session(expiresIn: 40).isExpired(at: Fixture.now, leeway: 10))
        #expect(session(expiresIn: 40).isExpired(at: Fixture.now, leeway: 60))
    }

    @Test("A session round-trips through JSON, as the keychain stores it")
    func codable() throws {
        let original = session(expiresIn: 600)
        let back = try JSONDecoder().decode(AuthSession.self, from: JSONEncoder().encode(original))
        #expect(back == original)
    }
}

// MARK: - Widget publisher

final class MemoryWidgetStore: WidgetSnapshotStore, @unchecked Sendable {
    var saved: WidgetSnapshot?
    var failSave = false
    func save(_ snapshot: WidgetSnapshot) throws {
        if failSave { throw CocoaError(.fileWriteUnknown) }
        saved = snapshot
    }
    func load() -> WidgetSnapshot? { saved }
}

final class Counter: @unchecked Sendable {
    private(set) var count = 0
    func bump() { count += 1 }
}

func makeProject(id: UUID = Fixture.projectA, name: String = "Tower A", centre: GeoPoint? = nil) -> Project {
    Project(id: id, name: name, locationName: "Colombo", status: .active, startDate: Fixture.now, endDate: Fixture.now.addingTimeInterval(86_400 * 30), managerName: "Alex", centre: centre)
}

@Suite("Widget publisher")
struct WidgetPublisherTests {
    private func seeded(issues: [Issue] = []) async throws -> (ProjectRepository, CoreDataLocalStore) {
        let store = try CoreDataLocalStore(storeURL: nil)
        var writes = [try RecordWrite(makeProject(), sortDate: Fixture.now)]
        for issue in issues { writes.append(try RecordWrite(issue, sortDate: Fixture.now)) }
        try await store.commit(writes)
        return (ProjectRepository(store: store), store)
    }

    @Test("Publishing writes a snapshot for the project and reloads the widget once")
    func publishes() async throws {
        let (repo, _) = try await seeded()
        let widget = MemoryWidgetStore(), reloads = Counter()
        let publisher = WidgetSnapshotPublisher(repository: repo, snapshots: widget, calendar: Fixture.calendar, clock: { Fixture.now }, reloadTimelines: { reloads.bump() })
        let snapshot = try #require(await publisher.publish(projectID: Fixture.projectA))
        #expect(snapshot.projectName == "Tower A")
        #expect(snapshot.projectID == Fixture.projectA)
        #expect(snapshot.generatedAt == Fixture.now)
        #expect(widget.saved == snapshot)
        #expect(reloads.count == 1)
    }

    @Test("A critical open issue shows in the snapshot")
    func countsCritical() async throws {
        let (repo, _) = try await seeded(issues: [Fixture.issue(priority: .critical), Fixture.issue(priority: .low)])
        let publisher = WidgetSnapshotPublisher(repository: repo, snapshots: MemoryWidgetStore(), calendar: Fixture.calendar, clock: { Fixture.now }, reloadTimelines: {})
        let snapshot = try #require(await publisher.publish(projectID: Fixture.projectA))
        #expect(snapshot.openCritical == 1)
        #expect(snapshot.status == .critical(1))
    }

    @Test("A project with nothing to review is all clear")
    func allClear() async throws {
        let (repo, _) = try await seeded()
        let publisher = WidgetSnapshotPublisher(repository: repo, snapshots: MemoryWidgetStore(), calendar: Fixture.calendar, clock: { Fixture.now }, reloadTimelines: {})
        #expect(try #require(await publisher.publish(projectID: Fixture.projectA)).status == .allClear)
    }

    @Test("An unknown project publishes nothing and does not reload")
    func unknownProject() async throws {
        let (repo, _) = try await seeded()
        let widget = MemoryWidgetStore(), reloads = Counter()
        let publisher = WidgetSnapshotPublisher(repository: repo, snapshots: widget, calendar: Fixture.calendar, clock: { Fixture.now }, reloadTimelines: { reloads.bump() })
        #expect(await publisher.publish(projectID: Fixture.projectB) == nil)
        #expect(widget.saved == nil && reloads.count == 0)
    }

    @Test("If the snapshot cannot be saved, nothing is reloaded")
    func saveFails() async throws {
        let (repo, _) = try await seeded()
        let widget = MemoryWidgetStore(); widget.failSave = true
        let reloads = Counter()
        let publisher = WidgetSnapshotPublisher(repository: repo, snapshots: widget, calendar: Fixture.calendar, clock: { Fixture.now }, reloadTimelines: { reloads.bump() })
        #expect(await publisher.publish(projectID: Fixture.projectA) == nil)
        #expect(reloads.count == 0)
    }

    @Test("Publishing twice reloads twice and keeps the latest snapshot")
    func twice() async throws {
        let (repo, _) = try await seeded()
        let widget = MemoryWidgetStore(), reloads = Counter()
        let publisher = WidgetSnapshotPublisher(repository: repo, snapshots: widget, calendar: Fixture.calendar, clock: { Fixture.now }, reloadTimelines: { reloads.bump() })
        _ = await publisher.publish(projectID: Fixture.projectA)
        _ = await publisher.publish(projectID: Fixture.projectA)
        #expect(reloads.count == 2 && widget.load() != nil)
    }
}

// MARK: - Timeline, map, notifications, sync centre

private func snapshot(photos: [EvidencePhoto] = [], issues: [Issue] = [], tasks: [TaskItem] = [], notifications: [AppNotification] = []) -> ProjectSnapshot {
    ProjectSnapshot(project: makeProject(), areas: [SiteArea(id: Fixture.areaA, projectID: Fixture.projectA, name: "North", level: "L1")], members: [],
                    photos: photos, issues: issues, inspections: [], tasks: tasks, analyses: [], notifications: notifications)
}

@MainActor
@Suite("Timeline view model")
struct TimelineViewModelTests {
    @Test("An empty project has no timeline sections")
    func empty() {
        #expect(TimelineViewModel(calendar: Fixture.calendar).sections(for: snapshot()).isEmpty)
    }

    @Test("Records appear as timeline sections")
    func hasSections() {
        let vm = TimelineViewModel(calendar: Fixture.calendar)
        #expect(!vm.sections(for: snapshot(photos: [Fixture.photo()], issues: [Fixture.issue()])).isEmpty)
    }

    @Test("Filtering to a kind with no records empties the timeline")
    func kindFilter() {
        let vm = TimelineViewModel(filter: TimelineFilter(kinds: [.task]), calendar: Fixture.calendar)
        #expect(vm.sections(for: snapshot(photos: [Fixture.photo()])).isEmpty)
    }

    @Test("Statuses offered for filtering are unique and sorted")
    func statuses() {
        let vm = TimelineViewModel(calendar: Fixture.calendar)
        let statuses = vm.availableStatuses(for: snapshot(issues: [Fixture.issue(), Fixture.issue(status: .resolved)]))
        #expect(statuses == statuses.sorted())
        #expect(Set(statuses).count == statuses.count)
        #expect(!statuses.isEmpty)
        #expect(vm.availableStatuses(for: snapshot()).isEmpty)
    }

    @Test("Today covers the whole day, to the last second")
    func today() throws {
        let vm = TimelineViewModel(calendar: Fixture.calendar)
        vm.setToday(now: Fixture.now)
        let range = try #require(vm.filter.dateRange)
        #expect(range.lowerBound == Fixture.calendar.startOfDay(for: Fixture.now))
        #expect(range.upperBound == Fixture.calendar.date(byAdding: .day, value: 1, to: range.lowerBound)!.addingTimeInterval(-1))
    }

    @Test("Clearing resets every filter")
    func clear() {
        let vm = TimelineViewModel(filter: TimelineFilter(areaIDs: [Fixture.areaA], kinds: [.issue], personID: Fixture.worker, statusLabel: "Open"), calendar: Fixture.calendar)
        vm.setToday(now: Fixture.now)
        vm.clear()
        #expect(vm.filter == TimelineFilter())
    }
}

@MainActor
@Suite("Map view model")
struct MapViewModelTests {
    @Test("Location problems come with an explanation", arguments: [LocationPermission.denied, .restricted, .approximateOnly])
    func explains(_ p: LocationPermission) {
        #expect(MapViewModel(locationPermission: p).permissionNotice() != nil)
    }

    @Test("Normal permission states need no explanation", arguments: [LocationPermission.notDetermined, .whenInUse, .always])
    func silent(_ p: LocationPermission) {
        #expect(MapViewModel(locationPermission: p).permissionNotice() == nil)
    }

    @Test("The permission can change while the screen is open")
    func updates() {
        let vm = MapViewModel()
        vm.updatePermission(.denied)
        #expect(vm.locationPermission == .denied && vm.permissionNotice() != nil)
    }

    @Test("Toggling a kind hides and shows its pins")
    func toggling() {
        let vm = MapViewModel()
        let snap = snapshot(photos: [Fixture.photo()])
        #expect(vm.projection(for: snap).items.count == 1)
        vm.toggle(.photo)
        #expect(vm.projection(for: snap).items.isEmpty)
        vm.toggle(.photo)
        #expect(vm.projection(for: snap).items.count == 1)
    }

    @Test("All kinds are visible to start with")
    func allVisible() { #expect(MapViewModel().visibleKinds == Set(TimelineKind.allCases)) }
}

@MainActor
@Suite("Notifications view model")
struct NotificationsViewModelTests {
    private func note(read: Bool) -> AppNotification {
        AppNotification(projectID: Fixture.projectA, kind: .taskOverdue, title: "Task overdue", body: "Fix it", createdAt: Fixture.now, readAt: read ? Fixture.now : nil)
    }

    private func make() throws -> (NotificationsViewModel, CoreDataLocalStore) {
        let store = try CoreDataLocalStore(storeURL: nil)
        return (NotificationsViewModel(repository: NotificationRepository(store: store), clock: { Fixture.now }), store)
    }

    @Test("Unread count ignores read notifications")
    func unread() throws {
        let (vm, _) = try make()
        #expect(vm.unreadCount(in: snapshot(notifications: [note(read: false), note(read: true), note(read: false)])) == 2)
    }

    @Test("The unread filter hides read notifications")
    func filter() throws {
        let (vm, _) = try make()
        let snap = snapshot(notifications: [note(read: false), note(read: true)])
        #expect(vm.items(in: snap).count == 2)
        vm.showUnreadOnly = true
        #expect(vm.items(in: snap).count == 1)
    }

    @Test("Opening a notification marks it read in the store")
    func open() async throws {
        let (vm, store) = try make()
        let n = note(read: false)
        try await store.commit([try RecordWrite(n, sortDate: n.createdAt)])
        await vm.open(n)
        #expect(try await store.record(AppNotification.self, id: n.id)?.readAt == Fixture.now)
    }

    @Test("Mark all read clears every unread notification")
    func markAll() async throws {
        let (vm, store) = try make()
        let items = [note(read: false), note(read: false)]
        try await store.commit(try items.map { try RecordWrite($0, sortDate: $0.createdAt) })
        await vm.markAllRead(projectID: Fixture.projectA)
        let stored = try await store.records(AppNotification.self, projectID: Fixture.projectA)
        #expect(stored.count == 2 && stored.allSatisfy(\.isRead))
    }
}

@MainActor
@Suite("Sync centre view model")
struct SyncCentreViewModelTests {
    private func make(_ script: [FakeBackend.Step] = [.ok(1)]) async throws -> (SyncCenterViewModel, CoreDataLocalStore, FakeBackend) {
        let store = try CoreDataLocalStore(storeURL: nil)
        let backend = FakeBackend(script)
        try await store.commit([try RecordWrite(Fixture.issue(), sortDate: Fixture.now)])
        return (SyncCenterViewModel(store: store, engine: SyncEngine(store: store, backend: backend, clock: { Fixture.now })), store, backend)
    }

    @Test("A queued change shows as waiting, titled from its content")
    func waiting() async throws {
        let (vm, _, _) = try await make()
        await vm.reload()
        #expect(vm.rows.count == 1)
        #expect(vm.rows[0].phase == .waiting)
        #expect(vm.rows[0].title == "Crack")
        #expect(vm.summary.pending == 1 && vm.summary.total == 1)
    }

    @Test("Syncing now sends it and empties the list")
    func syncs() async throws {
        let (vm, _, backend) = try await make()
        await vm.syncNow()
        #expect(vm.lastReport?.completed == 1)
        #expect(vm.rows.isEmpty && !vm.isSyncing)
        #expect(backend.upserts.count == 1)
    }

    @Test("A change the server rejects shows as failed with the reason")
    func rejected() async throws {
        let (vm, _, _) = try await make([.fail(.rejected("Your role isn't allowed."))])
        await vm.syncNow()
        #expect(vm.rows.count == 1)
        guard case .failed(let reason) = vm.rows[0].phase else { Testing.Issue.record("expected failed, got \(vm.rows[0].phase)"); return }
        #expect(reason.contains("role"))
        #expect(vm.summary.failed == 1)
    }

    @Test("A temporary error is shown as retrying later")
    func retrying() async throws {
        let (vm, _, _) = try await make([.fail(.transient("Server error 503"))])
        await vm.syncNow()
        #expect(vm.lastReport?.retryScheduled == 1)
        guard case .retrying = vm.rows.first?.phase else { Testing.Issue.record("expected retrying, got \(String(describing: vm.rows.first?.phase))"); return }
    }

    @Test("Discarding removes a queued change")
    func discards() async throws {
        let (vm, _, _) = try await make()
        await vm.reload()
        await vm.discard(vm.rows[0].id)
        #expect(vm.rows.isEmpty && vm.summary.total == 0)
    }

    @Test("Retrying a failed change sends it again")
    func retries() async throws {
        let (vm, _, backend) = try await make([.fail(.rejected("no")), .ok(2)])
        await vm.syncNow()
        await vm.retry(vm.rows[0].id)
        #expect(backend.upserts.count == 2 && vm.rows.isEmpty)
    }

    @Test("With nothing queued the list is empty")
    func nothing() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let vm = SyncCenterViewModel(store: store, engine: SyncEngine(store: store, backend: FakeBackend([])))
        await vm.reload()
        #expect(vm.rows.isEmpty && vm.summary.total == 0)
    }
}

// MARK: - Image sharpness and the Core ML analyzer

@Suite("Image sharpness maths")
struct SharpnessMathTests {
    @Test("A flat grey picture has no sharpness at all")
    func flat() {
        #expect(ImageSharpness.laplacianVariance(pixels: [UInt8](repeating: 128, count: 64), width: 8, height: 8) == 0)
    }

    @Test("A checkerboard is far sharper than a gentle gradient")
    func checkerboard() {
        let checker = (0..<64).map { UInt8((($0 / 8) + ($0 % 8)) % 2 == 0 ? 0 : 255) }
        let gradient = (0..<64).map { UInt8(($0 % 8) * 4) }
        #expect(ImageSharpness.laplacianVariance(pixels: checker, width: 8, height: 8) > ImageSharpness.laplacianVariance(pixels: gradient, width: 8, height: 8) * 100)
    }

    @Test("Too-small or short inputs give zero instead of crashing", arguments: [(2, 2, 4), (8, 8, 10), (0, 0, 0), (3, 2, 6)])
    func degenerate(_ c: (w: Int, h: Int, count: Int)) {
        #expect(ImageSharpness.laplacianVariance(pixels: [UInt8](repeating: 9, count: c.count), width: c.w, height: c.h) == 0)
    }

    @Test("A blurry picture scores lower than a noisy one")
    func measureImages() throws {
        func image(noisy: Bool) throws -> CGImage {
            let source = try #require(CGImageSourceCreateWithData(makeImageData(width: 256, height: 256, noisy: noisy) as CFData, nil))
            return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let blurry = try image(noisy: false), noisy = try image(noisy: true)
        #expect(ImageSharpness.measure(blurry) < ImageSharpness.measure(noisy))
    }

    @Test("Large pictures are measured on a small copy, so it stays fast")
    func largeImage() throws {
        let source = try #require(CGImageSourceCreateWithData(makeImageData(width: 2000, height: 1000, noisy: true) as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(ImageSharpness.measure(image) > 0)
    }
}

private let modelFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("ML/models")
private let helmetModel = modelFolder.appendingPathComponent("HelmetDetector.mlpackage")
private let modelsPresent = FileManager.default.fileExists(atPath: helmetModel.path)

@Suite("Core ML analyzer with the real model")
struct RealModelTests {
    private func photoFile(width: Int = 640, height: Int = 480) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString).jpg")
        try makeJPEG(width: width, height: height).write(to: url)
        return url
    }

    @Test("A missing model is reported, not crashed on")
    func missingModel() {
        #expect(throws: HelmetAnalyzerError.self) {
            _ = try CoreMLHelmetAnalyzer(modelURL: URL(fileURLWithPath: "/no/such/Model.mlpackage"), descriptor: .candidateKeremberkeYOLOv8n)
        }
    }

    @Test("The helmet model loads and analyses a photo", .enabled(if: modelsPresent))
    func analyses() async throws {
        let analyzer = try CoreMLHelmetAnalyzer(modelURL: helmetModel, descriptor: .candidateKeremberkeYOLOv8n)
        let result = try await analyzer.analyse(imageAt: try photoFile())
        #expect(result.inferenceMilliseconds > 0)
        #expect(result.quality.pixelWidth == 640 && result.quality.pixelHeight == 480)
        #expect(analyzer.descriptor.identifier == HelmetModelDescriptor.candidateKeremberkeYOLOv8n.identifier)
    }

    @Test("A file that is not an image is rejected", .enabled(if: modelsPresent))
    func unreadable() async throws {
        let analyzer = try CoreMLHelmetAnalyzer(modelURL: helmetModel, descriptor: .candidateKeremberkeYOLOv8n)
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).jpg")
        try Data("not an image".utf8).write(to: junk)
        await #expect(throws: HelmetAnalyzerError.self) { try await analyzer.analyse(imageAt: junk) }
    }

    @Test("A photo that does not exist is rejected", .enabled(if: modelsPresent))
    func missingPhoto() async throws {
        let analyzer = try CoreMLHelmetAnalyzer(modelURL: helmetModel, descriptor: .candidateKeremberkeYOLOv8n)
        await #expect(throws: HelmetAnalyzerError.self) { try await analyzer.analyse(imageAt: URL(fileURLWithPath: "/no/such/photo.jpg")) }
    }

    @Test("Photos of different shapes are all analysed", .enabled(if: modelsPresent), arguments: [(640, 640), (1280, 720), (720, 1280), (4000, 3000)])
    func shapes(_ size: (Int, Int)) async throws {
        let analyzer = try CoreMLHelmetAnalyzer(modelURL: helmetModel, descriptor: .candidateKeremberkeYOLOv8n)
        let result = try await analyzer.analyse(imageAt: try photoFile(width: size.0, height: size.1))
        #expect(result.quality.pixelWidth > 0 && result.inferenceMilliseconds > 0)
    }

    @Test("All boxes the model returns lie inside the picture", .enabled(if: modelsPresent))
    func boxesInside() async throws {
        let analyzer = try CoreMLHelmetAnalyzer(modelURL: helmetModel, descriptor: .candidateKeremberkeYOLOv8n)
        let result = try await analyzer.analyse(imageAt: try photoFile())
        for o in result.observations {
            #expect(o.box.x >= -0.01 && o.box.y >= -0.01 && o.box.x + o.box.width <= 1.01 && o.box.y + o.box.height <= 1.01)
        }
    }
}
