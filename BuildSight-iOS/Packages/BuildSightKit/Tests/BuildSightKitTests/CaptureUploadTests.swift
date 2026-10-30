import Testing
import Foundation
@testable import BuildSightKit

/// Counts how often the live location is asked for.
final class CountingLocation: LocationProviding, @unchecked Sendable {
    var permission: LocationPermission = .whenInUse
    private(set) var asked = 0
    func currentFix(timeout: TimeInterval) async -> LocationFix { asked += 1; return Fixture.gps }
}

@MainActor
@Suite("Capture: uploading a photo from the library")
struct CaptureUploadTests {
    let actor = ActingUser(userID: Fixture.worker, displayName: "Alex", role: .siteWorker, projectID: Fixture.projectA)
    let area = SiteArea(id: Fixture.areaA, projectID: Fixture.projectA, name: "North Wing", level: "L2")
    let pictureDate = Fixture.date(day: 1, hour: 9, month: 8)

    private func make(analyzer: ScriptedAnalyzer? = nil, location: CountingLocation = CountingLocation(), sync: RecordingSync = RecordingSync(), store: CoreDataLocalStore? = nil) throws -> (CaptureViewModel, CoreDataLocalStore, EvidenceFileStore, CountingLocation) {
        let store = try store ?? CoreDataLocalStore(storeURL: nil)
        let files = try EvidenceFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)"))
        let workflow = HelmetWorkflow(analyzer: analyzer, store: store) { files.url(forFilename: $0.localFilename) }
        let vm = CaptureViewModel(actor: actor, areas: [area], store: store, files: files, location: location, workflow: workflow, sync: sync, clock: { Fixture.now })
        return (vm, store, files, location)
    }

    private func picture(width: Int = 640, height: Int = 480, takenAt: Date? = nil) throws -> ImportedPhoto {
        ImportedPhoto(jpeg: makeJPEG(width: width, height: height), pixelWidth: width, pixelHeight: height, takenAt: takenAt)
    }

    @Test("Uploading moves to the review step and marks the photo as an upload")
    func entersReview() throws {
        let (vm, _, _, _) = try make()
        vm.photoUploaded(try picture())
        #expect(vm.phase == .review)
        #expect(vm.isUpload)
        #expect(vm.capturedJPEG != nil)
    }

    @Test("A camera photo is not marked as an upload")
    func cameraIsNotUpload() throws {
        let (vm, _, _, _) = try make()
        vm.photoCaptured(makeJPEG())
        #expect(!vm.isUpload)
    }

    @Test("The picture's own date is used when it has one")
    func usesPictureDate() throws {
        let (vm, _, _, _) = try make()
        vm.photoUploaded(try picture(takenAt: pictureDate))
        #expect(vm.capturedAt == pictureDate)
    }

    @Test("Without a date the upload time is used")
    func fallsBackToNow() throws {
        let (vm, _, _, _) = try make()
        vm.photoUploaded(try picture(takenAt: nil))
        #expect(vm.capturedAt == Fixture.now)
    }

    @Test("The location preview says the photo was uploaded, straight away")
    func previewIsImported() throws {
        let (vm, _, _, _) = try make()
        vm.photoUploaded(try picture())
        #expect(vm.locationPreview == .unavailable(.imported))
    }

    @Test("The phone's current position is never asked for or stored on an upload")
    func neverAsksForGPS() async throws {
        let (vm, store, _, location) = try make(analyzer: .detecting([]))
        vm.photoUploaded(try picture())
        vm.selectedAreaID = area.id
        await vm.saveAndAnalyse()
        let saved = try #require(vm.outcome?.photo)
        #expect(location.asked == 0)
        #expect(saved.location == .unavailable(.imported))
        #expect(saved.location.point == nil)
        let stored = try #require(try await store.record(EvidencePhoto.self, id: saved.id))
        #expect(stored.location == .unavailable(.imported))
    }

    @Test("A camera photo does ask for the position")
    func cameraAsksForGPS() async throws {
        let (vm, _, _, location) = try make(analyzer: .detecting([]))
        vm.photoCaptured(makeJPEG())
        vm.selectedAreaID = area.id
        await vm.saveAndAnalyse()
        #expect(location.asked >= 1)
        #expect(vm.outcome?.photo.location == Fixture.gps)
    }

    @Test("Saving needs an area, the same as for a camera photo")
    func needsArea() throws {
        let (vm, _, _, _) = try make()
        vm.photoUploaded(try picture())
        #expect(!vm.canSave)
        vm.selectedAreaID = area.id
        #expect(vm.canSave)
    }

    @Test("The saved record uses the picture's date")
    func savedDate() async throws {
        let (vm, _, _, _) = try make(analyzer: .detecting([]))
        vm.photoUploaded(try picture(takenAt: pictureDate))
        vm.selectedAreaID = area.id
        await vm.saveAndAnalyse()
        #expect(vm.outcome?.photo.capturedAt == pictureDate)
    }

    @Test("An uploaded photo with no helmet is analysed and raises a safety issue")
    func analysedLikeACameraPhoto() async throws {
        let (vm, _, _, _) = try make(analyzer: .detecting([Fixture.obs(.noHelmet, 0.9)]))
        vm.photoUploaded(try picture())
        vm.selectedAreaID = area.id
        await vm.saveAndAnalyse()
        #expect(vm.phase == .finished)
        let outcome = try #require(vm.outcome)
        #expect(outcome.createdNewIssue)
        #expect(outcome.issue?.isMachineGenerated == true)
        #expect(outcome.issue?.review == .awaitingReview)
    }

    @Test("An uploaded photo with all helmets on raises no issue")
    func cleanUploadRaisesNothing() async throws {
        let (vm, _, _, _) = try make(analyzer: .detecting([Fixture.obs(.helmet, 0.95)]))
        vm.photoUploaded(try picture())
        vm.selectedAreaID = area.id
        await vm.saveAndAnalyse()
        #expect(vm.outcome?.issue == nil)
    }

    @Test("The evidence file on disk has the uploaded picture's size", arguments: [(640, 480), (480, 640), (1024, 1024)])
    func fileSize(_ size: (Int, Int)) async throws {
        let (vm, _, files, _) = try make(analyzer: .detecting([]))
        vm.photoUploaded(try picture(width: size.0, height: size.1))
        vm.selectedAreaID = area.id
        await vm.saveAndAnalyse()
        let photo = try #require(vm.outcome?.photo)
        #expect(photo.pixelWidth == size.0 && photo.pixelHeight == size.1)
        #expect(FileManager.default.fileExists(atPath: files.url(forFilename: photo.localFilename).path))
    }

    @Test("Choosing another photo clears the upload flag")
    func retakeClears() throws {
        let (vm, _, _, _) = try make()
        vm.photoUploaded(try picture())
        vm.retake()
        #expect(!vm.isUpload && vm.phase == .camera && vm.capturedJPEG == nil)
    }

    @Test("Taking a camera photo after an upload clears the flag")
    func cameraAfterUpload() throws {
        let (vm, _, _, _) = try make()
        vm.photoUploaded(try picture())
        vm.photoCaptured(makeJPEG())
        #expect(!vm.isUpload)
        #expect(vm.locationPreview != .unavailable(.imported))
    }

    @Test("Uploading a second photo replaces the first")
    func secondUploadReplaces() throws {
        let (vm, _, _, _) = try make()
        vm.photoUploaded(try picture(takenAt: pictureDate))
        vm.photoUploaded(try picture(takenAt: nil))
        #expect(vm.capturedAt == Fixture.now)
    }

    @Test("Saving asks for a sync, as for every other record")
    func requestsSync() async throws {
        let sync = RecordingSync()
        let (vm, _, _, _) = try make(analyzer: .detecting([]), sync: sync)
        vm.photoUploaded(try picture())
        vm.selectedAreaID = area.id
        await vm.saveAndAnalyse()
        #expect(sync.requests >= 1)
    }
}

@Suite("Location reasons")
struct LocationReasonTests {
    @Test("An uploaded photo has no usable point and is not approximate")
    func importedHasNoPoint() {
        let fix = LocationFix.unavailable(.imported)
        #expect(fix.point == nil)
        #expect(!fix.isApproximate)
    }

    @Test("Every reason survives a JSON round trip", arguments: [LocationUnavailableReason.permissionDenied, .permissionRestricted, .servicesDisabled, .noFixYet, .timedOut, .imported])
    func codable(_ reason: LocationUnavailableReason) throws {
        let fix = LocationFix.unavailable(reason)
        let back = try JSONDecoder().decode(LocationFix.self, from: JSONEncoder().encode(fix))
        #expect(back == fix)
    }

    @Test("The stored name for an upload is stable")
    func rawValue() {
        #expect(LocationUnavailableReason.imported.rawValue == "imported")
    }

    @Test("A missing-reason value from an old build is rejected, not guessed")
    func unknownReason() {
        #expect(LocationUnavailableReason(rawValue: "somethingNew") == nil)
    }
}
