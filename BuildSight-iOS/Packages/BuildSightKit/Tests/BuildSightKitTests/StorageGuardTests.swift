import Testing
import Foundation
@testable import BuildSightKit

private let mb: Int64 = 1024 * 1024

@Suite("Storage guard")
struct StorageGuardTests {
    @Test("Enough room is accepted", arguments: [50 * mb, 51 * mb, 500 * mb, 64 * 1024 * mb, Int64.max])
    func enough(_ free: Int64) { #expect(StorageGuard.hasRoom(available: free)) }

    @Test("Too little room is refused", arguments: [Int64(0), 1, 10 * mb, 49 * mb, 50 * mb - 1, -5])
    func tooLittle(_ free: Int64) { #expect(!StorageGuard.hasRoom(available: free)) }

    @Test("An unreadable amount never blocks saving")
    func unknown() { #expect(StorageGuard.hasRoom(available: nil)) }

    @Test("The limit can be raised for bigger jobs")
    func customNeed() {
        #expect(!StorageGuard.hasRoom(available: 100 * mb, needed: 200 * mb))
        #expect(StorageGuard.hasRoom(available: 300 * mb, needed: 200 * mb))
    }

    @Test("The default limit is 50 MB")
    func limit() { #expect(StorageGuard.minimumFreeBytes == 50 * mb) }

    @Test("The message says how much is free and what to do")
    func message() {
        let text = StorageGuard.message(available: 12 * mb)
        #expect(text.contains("12"))
        #expect(text.localizedCaseInsensitiveContains("free up"))
    }

    @Test("A negative amount is shown as zero, not as a negative size")
    func negativeMessage() { #expect(!StorageGuard.message(available: -100).contains("-")) }

    @Test("The real device reading is a positive number or nil")
    func realReading() {
        if let bytes = StorageGuard.deviceAvailableBytes() { #expect(bytes > 0) }
    }
}

@MainActor
@Suite("Capture with low storage")
struct CaptureStorageTests {
    let actor = ActingUser(userID: Fixture.worker, displayName: "Alex", role: .siteWorker, projectID: Fixture.projectA)
    let area = SiteArea(id: Fixture.areaA, projectID: Fixture.projectA, name: "North Wing", level: "L2")

    private func make(free: Int64?) throws -> (CaptureViewModel, CoreDataLocalStore) {
        let store = try CoreDataLocalStore(storeURL: nil)
        let files = try EvidenceFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString)"))
        let workflow = HelmetWorkflow(analyzer: ScriptedAnalyzer.detecting([]), store: store) { files.url(forFilename: $0.localFilename) }
        let vm = CaptureViewModel(actor: actor, areas: [area], store: store, files: files, location: FixedLocation(fix: Fixture.gps), workflow: workflow, sync: RecordingSync(), clock: { Fixture.now }, availableStorage: { free })
        vm.photoCaptured(makeJPEG())
        vm.selectedAreaID = area.id
        return (vm, store)
    }

    @Test("Nearly full: saving stops with a clear message and saves nothing")
    func blocksSave() async throws {
        let (vm, store) = try make(free: 10 * mb)
        await vm.saveAndAnalyse()
        guard case .failed(let message) = vm.phase else { Testing.Issue.record("expected a failed phase, got \(vm.phase)"); return }
        #expect(message.localizedCaseInsensitiveContains("free"))
        #expect(try await store.records(EvidencePhoto.self, projectID: Fixture.projectA).isEmpty)
        #expect(vm.outcome == nil)
    }

    @Test("Plenty of room: the photo is saved and analysed as usual")
    func allowsSave() async throws {
        let (vm, store) = try make(free: 5_000 * mb)
        await vm.saveAndAnalyse()
        #expect(vm.phase == .finished)
        #expect(try await store.records(EvidencePhoto.self, projectID: Fixture.projectA).count == 1)
    }

    @Test("Unknown free space does not block saving")
    func unknownAllows() async throws {
        let (vm, _) = try make(free: nil)
        await vm.saveAndAnalyse()
        #expect(vm.phase == .finished)
    }

    @Test("Exactly the minimum is allowed")
    func boundary() async throws {
        let (vm, _) = try make(free: 50 * mb)
        await vm.saveAndAnalyse()
        #expect(vm.phase == .finished)
    }
}
