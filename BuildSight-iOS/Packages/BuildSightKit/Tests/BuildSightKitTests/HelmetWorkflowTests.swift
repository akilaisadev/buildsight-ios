import Testing
import Foundation
@testable import BuildSightKit

struct ScriptedAnalyzer: HelmetAnalyzing {
    var descriptor = HelmetModelDescriptor.candidateKeremberkeYOLOv8n
    var result: Result<HelmetRawResult, HelmetAnalyzerError>
    func analyse(imageAt url: URL) async throws -> HelmetRawResult { try result.get() }

    static func detecting(_ observations: [HelmetObservation], quality: ImageQuality = Fixture.sharpImage) -> ScriptedAnalyzer {
        ScriptedAnalyzer(result: .success(HelmetRawResult(observations: observations, quality: quality, inferenceMilliseconds: 42)))
    }
}

@Suite("Capture → analyse → issue → review, end to end on a real store")
struct HelmetWorkflowTests {
    private func workflow(_ analyzer: ScriptedAnalyzer?, store: LocalStore) -> HelmetWorkflow {
        HelmetWorkflow(analyzer: analyzer, store: store) { URL(fileURLWithPath: "/dev/null/\($0.localFilename)") }
    }

    @Test("A suspected missing helmet is saved with its analysis, a linked High Safety issue, an audit event and an in-app notification")
    func fullFlow() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let photo = Fixture.photo()
        try await store.commit([try RecordWrite(photo, sortDate: photo.capturedAt)])

        let result = try await workflow(.detecting([Fixture.obs(.noHelmet, 0.88)]), store: store).analyse(photo: photo, now: Fixture.now)

        #expect(result.createdNewIssue)
        let issue = try #require(result.issue)
        #expect(issue.priority == .high && issue.review == .awaitingReview && issue.isMachineGenerated)
        #expect(result.analysis.linkedIssueID == issue.id && result.analysis.review == .awaitingReview)
        #expect(result.analysis.modelIdentifier == "yolov8n-hard-hat-detection")
        #expect(result.analysis.inferenceMilliseconds == 42)
        #expect(result.analysis.observations.count == 1)

        // Everything is persisted and relatable: reopen from the store.
        let storedIssue = try #require(try await store.record(Issue.self, id: issue.id))
        #expect(storedIssue == issue)
        let events = try await store.records(IssueEvent.self, projectID: Fixture.projectA, parentID: issue.id)
        #expect(events.count == 1)
        #expect(try await store.records(AppNotification.self, projectID: Fixture.projectA).count == 1)
        let analyses = try await store.records(HelmetAnalysis.self, projectID: Fixture.projectA, parentID: photo.id)
        #expect(analyses.count == 1)
    }

    @Test("Analysing the same photo twice leaves exactly one analysis and one issue")
    func idempotent() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let photo = Fixture.photo()
        let wf = workflow(.detecting([Fixture.obs(.noHelmet, 0.9)]), store: store)
        let first = try await wf.analyse(photo: photo, now: Fixture.now)
        let second = try await wf.analyse(photo: photo, now: Fixture.now.addingTimeInterval(60))

        #expect(first.createdNewIssue && !second.createdNewIssue)
        #expect(first.issue?.id == second.issue?.id)
        #expect(try await store.records(Issue.self, projectID: Fixture.projectA).count == 1)
        #expect(try await store.records(HelmetAnalysis.self, projectID: Fixture.projectA).count == 1)
        let events = try await store.records(IssueEvent.self, projectID: Fixture.projectA, parentID: first.issue?.id)
        #expect(events.contains { $0.kind == .reanalysed })
    }

    @Test("Re-analysis does not erase a human review decision")
    func reviewSurvivesReanalysis() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let photo = Fixture.photo()
        let wf = workflow(.detecting([Fixture.obs(.noHelmet, 0.9)]), store: store)
        let first = try await wf.analyse(photo: photo, now: Fixture.now)
        _ = try await wf.review(analysisID: first.analysis.id, decision: .confirm, reviewerID: Fixture.supervisor, role: .supervisor, now: Fixture.now).get()
        let again = try await wf.analyse(photo: photo, now: Fixture.now.addingTimeInterval(60))
        #expect(again.analysis.review == .confirmed)
        #expect(try await store.record(Issue.self, id: first.issue!.id)?.review == .confirmed)
    }

    @Test("Review persists the decision across issue, analysis and history, and refuses unauthorised roles")
    func reviewPersists() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let photo = Fixture.photo()
        let wf = workflow(.detecting([Fixture.obs(.noHelmet, 0.9)]), store: store)
        let r = try await wf.analyse(photo: photo, now: Fixture.now)

        let denied = try await wf.review(analysisID: r.analysis.id, decision: .confirm, reviewerID: Fixture.worker, role: .siteWorker, now: Fixture.now)
        #expect(denied.isFailure)
        #expect(try await store.record(Issue.self, id: r.issue!.id)?.review == .awaitingReview)

        _ = try await wf.review(analysisID: r.analysis.id, decision: .dismiss(reason: "Cap, not a worker"), reviewerID: Fixture.supervisor, role: .supervisor, now: Fixture.now).get()
        let issue = try #require(try await store.record(Issue.self, id: r.issue!.id))
        #expect(issue.review == .dismissed && issue.status == .closed)
        #expect(try await store.record(HelmetAnalysis.self, id: r.analysis.id)?.review == .dismissed)
        let history = try await store.records(IssueEvent.self, projectID: Fixture.projectA, parentID: issue.id)
        #expect(history.contains { $0.kind == .machineReview(.dismissed) && $0.note == "Cap, not a worker" })
    }

    @Test("No model installed: evidence is kept, the analysis is recorded as failed, and no issue is invented")
    func noModel() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let photo = Fixture.photo()
        try await store.commit([try RecordWrite(photo, sortDate: photo.capturedAt)])
        let r = try await workflow(nil, store: store).analyse(photo: photo, now: Fixture.now)
        guard case .failed = r.analysis.state else { Testing.Issue.record("expected a failed analysis"); return }
        #expect(r.issue == nil)
        #expect(try await store.record(EvidencePhoto.self, id: photo.id) != nil)
    }

    @Test("Analyser errors become a retryable failed analysis rather than a thrown error")
    func analyzerFailure() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        let r = try await workflow(ScriptedAnalyzer(result: .failure(.inferenceFailed("boom"))), store: store).analyse(photo: Fixture.photo(), now: Fixture.now)
        #expect(r.analysis.state == .failed("Analysis failed: boom"))
        #expect(r.issue == nil)
    }

    @Test("Scenes with no workers, only helmets, or a blurry image never create an issue")
    func noIssueScenarios() async throws {
        let scenarios: [ScriptedAnalyzer] = [
            .detecting([]),
            .detecting([Fixture.obs(.helmet, 0.9), Fixture.obs(.helmet, 0.8, x: 0.5)]),
            .detecting([Fixture.obs(.noHelmet, 0.95)], quality: ImageQuality(pixelWidth: 1600, pixelHeight: 1200, sharpness: 2)),
        ]
        for analyzer in scenarios {
            let store = try CoreDataLocalStore(storeURL: nil)
            let r = try await workflow(analyzer, store: store).analyse(photo: Fixture.photo(), now: Fixture.now)
            #expect(r.issue == nil)
            #expect(try await store.records(Issue.self, projectID: Fixture.projectA).isEmpty)
        }
    }

    @Test("The queue holds the issue, event, notification and analysis for syncing")
    func syncQueueContents() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        _ = try await workflow(.detecting([Fixture.obs(.noHelmet, 0.9)]), store: store).analyse(photo: Fixture.photo(), now: Fixture.now)
        let types = Set(try await store.pendingOperations().map(\.recordType))
        #expect(types == [.issue, .issueEvent, .notification, .helmetAnalysis])
    }
}

private extension Result {
    var isFailure: Bool { if case .failure = self { return true } else { return false } }
}

@Suite("Image sharpness heuristic")
struct SharpnessTests {
    @Test("A checkerboard scores far higher than a flat or smoothly graded image")
    func ordering() {
        let w = 64, h = 64
        let sharp = (0..<w * h).map { UInt8((($0 % w) / 2 + ($0 / w) / 2) % 2 == 0 ? 0 : 255) }
        let flat = [UInt8](repeating: 128, count: w * h)
        let gradient = (0..<w * h).map { UInt8(($0 % w) * 255 / (w - 1)) }
        let s = ImageSharpness.laplacianVariance(pixels: sharp, width: w, height: h)
        let f = ImageSharpness.laplacianVariance(pixels: flat, width: w, height: h)
        let g = ImageSharpness.laplacianVariance(pixels: gradient, width: w, height: h)
        #expect(s > 1000)
        #expect(f == 0)
        #expect(g < 1)
    }

    @Test("Degenerate input is safe")
    func degenerate() {
        #expect(ImageSharpness.laplacianVariance(pixels: [], width: 0, height: 0) == 0)
        #expect(ImageSharpness.laplacianVariance(pixels: [1, 2], width: 2, height: 1) == 0)
    }
}
