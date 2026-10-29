import Testing
import Foundation
@testable import BuildSightKit

@Suite("Helmet result interpretation")
struct HelmetInterpreterTests {
    private func interpret(_ obs: [HelmetObservation], quality: ImageQuality = Fixture.sharpImage) -> HelmetOutcome {
        HelmetInterpreter.interpret(observations: obs, quality: quality).outcome
    }

    @Test("A confident no-helmet detection is a suspected violation")
    func confidentNoHelmet() {
        #expect(interpret([Fixture.obs(.noHelmet, 0.82)]) == .suspectedMissingHelmet(count: 1))
    }

    @Test("Missing-helmet count follows the number of separate heads, not boxes of one head")
    func countsDistinctHeads() {
        let obs = [
            Fixture.obs(.noHelmet, 0.9, x: 0.1),
            Fixture.obs(.noHelmet, 0.7, x: 0.5),
            Fixture.obs(.helmet, 0.8, x: 0.8),
        ]
        #expect(interpret(obs) == .suspectedMissingHelmet(count: 2))
    }

    @Test("A no-helmet box below the flag threshold is uncertain, never a violation")
    func lowConfidenceNotFlagged() {
        let outcome = interpret([Fixture.obs(.noHelmet, 0.40)])
        #expect(outcome == .unableToAssess(.onlyLowConfidenceDetections))
    }

    @Test("Detections under the noise floor are ignored entirely")
    func noiseFloor() {
        #expect(interpret([Fixture.obs(.noHelmet, 0.10)]) == .unableToAssess(.noHeadsDetected))
    }

    @Test("An empty scene is unable-to-assess, not safe and not a violation")
    func emptyScene() {
        #expect(interpret([]) == .unableToAssess(.noHeadsDetected))
    }

    @Test("Only helmets detected reports helmets, with no safety clearance wording")
    func helmetsOnly() {
        let outcome = interpret([Fixture.obs(.helmet, 0.9)])
        #expect(outcome == .helmetsDetected(helmets: 1, uncertain: 0))
        let text = outcome.summary.lowercased()
        #expect(!text.contains("safe") && !text.contains("compliant"))
    }

    @Test("Helmet and no-helmet boxes on the same head: the clearly stronger one wins")
    func conflictResolvedByMargin() {
        let box = (x: 0.3, y: 0.3, w: 0.2, h: 0.2)
        let obs = [Fixture.obs(.noHelmet, 0.90, x: box.x, y: box.y, w: box.w, h: box.h),
                   Fixture.obs(.helmet, 0.35, x: box.x, y: box.y, w: box.w, h: box.h)]
        #expect(interpret(obs) == .suspectedMissingHelmet(count: 1))
    }

    @Test("Nearly tied conflicting boxes make the head uncertain instead of flagging")
    func conflictTooCloseToCall() {
        let obs = [Fixture.obs(.noHelmet, 0.60, x: 0.3, y: 0.3), Fixture.obs(.helmet, 0.55, x: 0.3, y: 0.3)]
        #expect(interpret(obs) == .unableToAssess(.onlyLowConfidenceDetections))
    }

    @Test("Tiny images are rejected before any detection is trusted")
    func tooSmall() {
        let q = ImageQuality(pixelWidth: 200, pixelHeight: 200, sharpness: 200)
        #expect(interpret([Fixture.obs(.noHelmet, 0.95)], quality: q) == .unableToAssess(.imageTooSmall))
    }

    @Test("Blurry images are rejected even when the model is confident")
    func tooBlurry() {
        let q = ImageQuality(pixelWidth: 1600, pixelHeight: 1200, sharpness: 3)
        #expect(interpret([Fixture.obs(.noHelmet, 0.95)], quality: q) == .unableToAssess(.imageTooBlurry))
    }

    @Test("Vision bottom-left boxes are flipped to top-left exactly once")
    func visionCoordinateFlip() {
        // A box hugging the BOTTOM of the image in Vision space sits at y=0.
        let r = NormalizedRect(visionRect: 0.2, y: 0.0, width: 0.3, height: 0.25)
        #expect(abs(r.y - 0.75) < 1e-9)
        let top = NormalizedRect(visionRect: 0.2, y: 0.75, width: 0.3, height: 0.25)
        #expect(abs(top.y) < 1e-9)
    }

    @Test("IoU is 1 for identical boxes, 0 for disjoint boxes")
    func iou() {
        let a = NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)
        #expect(abs(a.intersectionOverUnion(with: a) - 1) < 1e-9)
        #expect(a.intersectionOverUnion(with: NormalizedRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2)) == 0)
    }
}

@Suite("Safety issue creation and human review")
struct SafetyIssueTests {
    private func analysis(for photo: EvidencePhoto, count: Int = 1) -> HelmetAnalysis {
        HelmetAnalysis(projectID: photo.projectID, photoID: photo.id, modelIdentifier: "m", modelVersion: "1", policyVersion: "p", analysedAt: Fixture.now, state: .finished(.suspectedMissingHelmet(count: count)))
    }

    @Test("A suspected missing helmet creates a High Safety issue labelled machine-generated and awaiting review")
    func createsIssue() throws {
        let photo = Fixture.photo()
        let issue = try #require(SafetyIssueFactory.makeIssue(for: analysis(for: photo), photo: photo, existingIssue: nil, now: Fixture.now))
        #expect(issue.priority == .high)
        #expect(issue.category == .safety)
        #expect(issue.isMachineGenerated)
        #expect(issue.review == .awaitingReview)
        #expect(issue.evidencePhotoIDs == [photo.id])
        #expect(issue.projectID == photo.projectID && issue.areaID == photo.areaID)
        #expect(issue.location == photo.location)
        #expect(issue.details.contains("Awaiting human review"))
    }

    @Test("Analysing the same photo again cannot create a second issue")
    func noDuplicate() throws {
        let photo = Fixture.photo()
        let a = analysis(for: photo)
        let first = try #require(SafetyIssueFactory.makeIssue(for: a, photo: photo, existingIssue: nil, now: Fixture.now))
        #expect(SafetyIssueFactory.makeIssue(for: a, photo: photo, existingIssue: first, now: Fixture.now) == nil)
        // The id is a pure function of the photo, so two devices agree on it.
        #expect(first.id == SafetyIssueFactory.issueID(forPhoto: photo.id))
    }

    @Test("Results that are not suspected violations never create issues")
    func nonViolationsCreateNothing() {
        let photo = Fixture.photo()
        for outcome: HelmetOutcome in [.helmetsDetected(helmets: 2, uncertain: 0), .unableToAssess(.noHeadsDetected), .unableToAssess(.imageTooBlurry)] {
            var a = analysis(for: photo); a.state = .finished(outcome)
            #expect(SafetyIssueFactory.makeIssue(for: a, photo: photo, existingIssue: nil, now: Fixture.now) == nil)
        }
        var failed = analysis(for: photo); failed.state = .failed("model missing")
        #expect(SafetyIssueFactory.makeIssue(for: failed, photo: photo, existingIssue: nil, now: Fixture.now) == nil)
    }

    private func flagged() throws -> (Issue, HelmetAnalysis) {
        let photo = Fixture.photo()
        let a = analysis(for: photo)
        let issue = try #require(SafetyIssueFactory.makeIssue(for: a, photo: photo, existingIssue: nil, now: Fixture.now))
        return (issue, a)
    }

    @Test("A supervisor can confirm; both records update and an audit event is produced")
    func confirm() throws {
        let (issue, a) = try flagged()
        let r = try SafetyIssueFactory.review(decision: .confirm, issue: issue, analysis: a, reviewerID: Fixture.supervisor, role: .supervisor, now: Fixture.now).get()
        #expect(r.issue.review == .confirmed && r.analysis.review == .confirmed)
        #expect(r.issue.status == .open)
        #expect(r.event.kind == .machineReview(.confirmed))
    }

    @Test("Dismissal needs a reason and closes the issue")
    func dismiss() throws {
        let (issue, a) = try flagged()
        let none = SafetyIssueFactory.review(decision: .dismiss(reason: " "), issue: issue, analysis: a, reviewerID: Fixture.supervisor, role: .supervisor, now: Fixture.now)
        #expect(throws: HelmetReviewError.reasonRequired) { try none.get() }
        let r = try SafetyIssueFactory.review(decision: .dismiss(reason: "Hat is on, glare on photo"), issue: issue, analysis: a, reviewerID: Fixture.supervisor, role: .supervisor, now: Fixture.now).get()
        #expect(r.issue.status == .closed && r.issue.review == .dismissed)
        #expect(r.event.note == "Hat is on, glare on photo")
    }

    @Test("Correcting the count to zero behaves as a dismissal")
    func correctToZero() throws {
        let (issue, a) = try flagged()
        let r = try SafetyIssueFactory.review(decision: .correct(confirmedCount: 0, note: "False alarm"), issue: issue, analysis: a, reviewerID: Fixture.supervisor, role: .supervisor, now: Fixture.now).get()
        #expect(r.issue.review == .dismissed)
    }

    @Test("A site worker cannot review a flag, and a flag can only be reviewed once")
    func reviewPermissionsAndOnce() throws {
        let (issue, a) = try flagged()
        let denied = SafetyIssueFactory.review(decision: .confirm, issue: issue, analysis: a, reviewerID: Fixture.worker, role: .siteWorker, now: Fixture.now)
        #expect(throws: HelmetReviewError.notPermitted) { try denied.get() }

        let done = try SafetyIssueFactory.review(decision: .confirm, issue: issue, analysis: a, reviewerID: Fixture.supervisor, role: .supervisor, now: Fixture.now).get()
        let again = SafetyIssueFactory.review(decision: .confirm, issue: done.issue, analysis: done.analysis, reviewerID: Fixture.supervisor, role: .supervisor, now: Fixture.now)
        #expect(throws: HelmetReviewError.alreadyReviewed) { try again.get() }
    }
}

@Suite("Vest and glove detections")
struct EquipmentInterpretationTests {
    private func run(_ obs: [HelmetObservation], quality: ImageQuality = Fixture.sharpImage) -> HelmetInterpretation {
        HelmetInterpreter.interpret(observations: obs, quality: quality)
    }

    @Test("Vests and gloves above the noise floor are counted")
    func countsEquipment() {
        let result = run([Fixture.obs(.vest, 0.8, x: 0.1), Fixture.obs(.vest, 0.6, x: 0.5), Fixture.obs(.gloves, 0.7, x: 0.8)])
        #expect(result.equipment == EquipmentSummary(vestsDetected: 2, glovesDetected: 1, possibleBareHands: 0))
    }

    @Test("Equipment boxes under the noise floor are ignored")
    func equipmentNoiseFloor() {
        #expect(run([Fixture.obs(.vest, 0.1), Fixture.obs(.gloves, 0.2)]).equipment.isEmpty)
    }

    @Test("A no-gloves box is only a hint and needs the flag score")
    func bareHandsHintNeedsFlagScore() {
        #expect(run([Fixture.obs(.noGloves, 0.40)]).equipment.possibleBareHands == 0)
        #expect(run([Fixture.obs(.noGloves, 0.60)]).equipment.possibleBareHands == 1)
    }

    @Test("Equipment boxes never change the helmet outcome")
    func equipmentDoesNotAffectHeads() {
        let heads = [Fixture.obs(.helmet, 0.9, x: 0.1)]
        let withEquipment = heads + [Fixture.obs(.vest, 0.9, x: 0.5), Fixture.obs(.noGloves, 0.9, x: 0.7)]
        #expect(run(withEquipment).outcome == run(heads).outcome)
        #expect(run(withEquipment).findings.count == run(heads).findings.count)
    }

    @Test("A vest overlapping a head box cannot make the head uncertain")
    func vestOverlapIsNotAHeadConflict() {
        let result = run([Fixture.obs(.noHelmet, 0.9, x: 0.1, y: 0.1, w: 0.2, h: 0.2), Fixture.obs(.vest, 0.85, x: 0.1, y: 0.1, w: 0.2, h: 0.2)])
        #expect(result.outcome == .suspectedMissingHelmet(count: 1))
    }

    @Test("Vests and gloves alone are not a head assessment and raise nothing")
    func equipmentOnlyPhoto() {
        let result = run([Fixture.obs(.vest, 0.9), Fixture.obs(.gloves, 0.9, x: 0.6)])
        #expect(result.outcome == .unableToAssess(.noHeadsDetected))
        #expect(result.equipment.vestsDetected == 1)
    }

    @Test("Blurry or tiny images report no equipment either")
    func qualityGateAppliesToEquipment() {
        let blurry = ImageQuality(pixelWidth: 1600, pixelHeight: 1200, sharpness: 1)
        #expect(run([Fixture.obs(.vest, 0.9)], quality: blurry).equipment.isEmpty)
    }

    @Test("Summary wording never claims compliance")
    func summaryWording() {
        #expect(EquipmentSummary(vestsDetected: 1, glovesDetected: 2).summary == "1 vest detected · 2 gloves detected")
        #expect(EquipmentSummary().summary == "No vests or gloves detected")
        let text = EquipmentSummary(vestsDetected: 3, glovesDetected: 1, possibleBareHands: 2).summary.lowercased()
        #expect(!text.contains("safe") && !text.contains("compliant"))
    }

    @Test("PPE model labels map to the right meanings")
    func descriptorLabelMap() {
        let map = HelmetModelDescriptor.ppeYOLOv8s.labelMap
        #expect(map["no-gloves"] == .noGloves && map["no-helmet"] == .noHelmet && map["vest"] == .vest)
        #expect(map.count == 5)
    }

    @Test("Analyses saved before the equipment field existed still decode")
    func oldAnalysisDecodes() throws {
        let analysis = HelmetAnalysis(projectID: Fixture.projectA, photoID: UUID(), modelIdentifier: "m", modelVersion: "1", policyVersion: "p", analysedAt: Fixture.date(day: 1), state: .finished(.unableToAssess(.noHeadsDetected)))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(analysis)) as? [String: Any])
        json.removeValue(forKey: "equipment")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HelmetAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.equipment == nil)
    }
}
