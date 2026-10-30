import Foundation
import Observation

public struct CaptureOutcome: Sendable {
    public var photo: EvidencePhoto
    public var analysis: HelmetAnalysis
    public var issue: Issue?
    public var createdNewIssue: Bool
}

/// Capture flow: camera → review → save → analyse → result. The photo is saved before
/// inference starts, so a model failure or crash never loses it.
@MainActor
@Observable
public final class CaptureViewModel {
    public enum Phase: Equatable {
        case camera
        case review
        case saving
        case analysing(photoID: UUID)
        case finished
        case failed(String)
    }

    public private(set) var phase: Phase = .camera
    public private(set) var capturedJPEG: Data?
    public private(set) var outcome: CaptureOutcome?
    public private(set) var locationPreview: LocationFix?
    public var selectedAreaID: UUID?
    public var category: PhotoCategory = .progress
    public var note = ""
    public let areas: [SiteArea]

    private let actor: ActingUser
    private let store: LocalStore
    private let files: EvidenceFileStoring
    private let location: LocationProviding
    private let workflow: HelmetWorkflow
    private let sync: SyncTriggering
    private let clock: @Sendable () -> Date
    private var capturedAt: Date?
    private var locationTask: Task<LocationFix, Never>?

    public init(actor: ActingUser, areas: [SiteArea], defaultAreaID: UUID? = nil, store: LocalStore, files: EvidenceFileStoring, location: LocationProviding, workflow: HelmetWorkflow, sync: SyncTriggering = NoopSyncTrigger(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.actor = actor
        self.areas = areas.filter { $0.projectID == actor.projectID }
        self.selectedAreaID = defaultAreaID
        self.store = store
        self.files = files
        self.location = location
        self.workflow = workflow
        self.sync = sync
        self.clock = clock
    }

    public var canSave: Bool { selectedAreaID != nil && phase == .review }

    /// Called with the camera's JPEG. Timestamp and location are taken NOW, at
    /// capture, not when the user finally presses Save.
    public func photoCaptured(_ jpeg: Data) {
        capturedJPEG = jpeg
        capturedAt = clock()
        locationPreview = nil
        let provider = location
        locationTask = Task { await provider.currentFix(timeout: 5) }
        phase = .review
        Task { [weak self] in
            guard let fix = await self?.locationTask?.value else { return }
            self?.locationPreview = fix
        }
    }

    public func retake() {
        locationTask?.cancel()
        capturedJPEG = nil
        locationPreview = nil
        phase = .camera
    }

    /// Cancelling review discards the unsaved image; nothing has been persisted yet.
    public func cancel() { retake(); note = "" }

    public func apply(scannedArea: SiteArea) { selectedAreaID = scannedArea.id }

    public func saveAndAnalyse() async {
        guard phase == .review, let jpeg = capturedJPEG, let areaID = selectedAreaID, let capturedAt else { return }
        phase = .saving
        let fix = await locationTask?.value ?? .unavailable(.noFixYet)

        let photoID = UUID()
        let photo: EvidencePhoto
        do {
            let saved = try files.save(jpeg: jpeg, photoID: photoID)
            photo = EvidencePhoto(id: photoID, projectID: actor.projectID, areaID: areaID, creatorID: actor.userID, capturedAt: capturedAt, location: fix, category: category, note: note.trimmingCharacters(in: .whitespacesAndNewlines), localFilename: saved.filename, pixelWidth: saved.pixelWidth, pixelHeight: saved.pixelHeight)
            try await store.commit([try RecordWrite(photo, sortDate: capturedAt, localFilename: saved.filename)])
        } catch {
            phase = .failed("The photo could not be saved: \(error.localizedDescription)")
            return
        }
        await sync.requestSync()

        phase = .analysing(photoID: photo.id)
        do {
            let result = try await workflow.analyse(photo: photo, now: clock())
            outcome = CaptureOutcome(photo: photo, analysis: result.analysis, issue: result.issue, createdNewIssue: result.createdNewIssue)
            await sync.requestSync()
        } catch {
            // The photo is already safe. Report the analysis problem without
            // implying the capture failed.
            let failed = HelmetAnalysis(projectID: photo.projectID, photoID: photo.id, modelIdentifier: "none", modelVersion: "none", policyVersion: "none", analysedAt: clock(), state: .failed(error.localizedDescription))
            outcome = CaptureOutcome(photo: photo, analysis: failed, issue: nil, createdNewIssue: false)
        }
        capturedJPEG = nil
        phase = .finished
    }

    public func reset() {
        outcome = nil
        capturedJPEG = nil
        note = ""
        phase = .camera
    }
}
