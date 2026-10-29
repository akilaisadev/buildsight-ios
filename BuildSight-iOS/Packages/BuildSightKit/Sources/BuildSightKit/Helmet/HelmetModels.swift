import Foundation
import CoreGraphics
/// A rectangle in normalised image coordinates with the origin at the
/// TOP-left (UIKit/SwiftUI convention). Vision reports boxes from the
/// bottom-left; `CoreMLHelmetAnalyzer` flips them once at the boundary so
/// nothing downstream has to remember which convention applies.
public struct NormalizedRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Converts a Vision-style rect (origin bottom-left) to top-left origin.
    public init(visionRect x: Double, y: Double, width: Double, height: Double) {
        self.init(x: x, y: 1 - y - height, width: width, height: height)
    }

    public var area: Double { max(0, width) * max(0, height) }

    public func intersectionOverUnion(with other: NormalizedRect) -> Double {
        let ix = max(0, min(x + width, other.x + other.width) - max(x, other.x))
        let iy = max(0, min(y + height, other.y + other.height) - max(y, other.y))
        let inter = ix * iy
        let union = area + other.area - inter
        return union > 0 ? inter / union : 0
    }

    public func scaled(to size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }
}

/// What the bundled model's class names mean for BuildSight. The detector is
/// head-level: a "no helmet" box is a class the network was trained to
/// recognise, not merely the absence of a helmet box.
public enum HelmetLabel: String, Codable, Sendable {
    case helmet
    case noHelmet
    /// Equipment classes from the multi-class PPE model. These are reported as
    /// facts about the photo and never raise a safety issue on their own.
    case vest
    case gloves
    /// "Bare hands" class. Weak in testing (AP 0.09), so shown only as a hint.
    case noGloves

    /// Head classes drive the helmet outcome; the rest feed `EquipmentSummary`.
    public var isHead: Bool { self == .helmet || self == .noHelmet }
}

/// What the PPE model saw besides heads. Deliberately counts only what was
/// detected: the model has no "no vest" class, so a photo without a vest box
/// says nothing about whether a vest was worn.
public struct EquipmentSummary: Codable, Hashable, Sendable {
    public var vestsDetected: Int
    public var glovesDetected: Int
    /// "No gloves" boxes above the flag score. A hint for the reviewer, never a violation.
    public var possibleBareHands: Int

    public init(vestsDetected: Int = 0, glovesDetected: Int = 0, possibleBareHands: Int = 0) {
        self.vestsDetected = vestsDetected
        self.glovesDetected = glovesDetected
        self.possibleBareHands = possibleBareHands
    }

    public static let empty = EquipmentSummary()
    public var isEmpty: Bool { vestsDetected == 0 && glovesDetected == 0 && possibleBareHands == 0 }

    /// One line for the result screen. Never says "safe" or "compliant".
    public var summary: String {
        var parts: [String] = []
        if vestsDetected > 0 { parts.append(vestsDetected == 1 ? "1 vest detected" : "\(vestsDetected) vests detected") }
        if glovesDetected > 0 { parts.append(glovesDetected == 1 ? "1 glove detected" : "\(glovesDetected) gloves detected") }
        if possibleBareHands > 0 { parts.append(possibleBareHands == 1 ? "1 possible bare hand (unconfirmed)" : "\(possibleBareHands) possible bare hands (unconfirmed)") }
        return parts.isEmpty ? "No vests or gloves detected" : parts.joined(separator: " · ")
    }
}

/// Provenance and I/O contract of the bundled model. Everything the report and
/// README say about the model should be traceable to this value.
public struct HelmetModelDescriptor: Codable, Hashable, Sendable {
    public var identifier: String
    public var version: String
    /// Raw class name emitted by the model → BuildSight meaning.
    public var labelMap: [String: HelmetLabel]
    public var inputSide: Int
    public var sourceDescription: String
    public var licenceNote: String

    public init(identifier: String, version: String, labelMap: [String: HelmetLabel], inputSide: Int, sourceDescription: String, licenceNote: String) {
        self.identifier = identifier
        self.version = version
        self.labelMap = labelMap
        self.inputSide = inputSide
        self.sourceDescription = sourceDescription
        self.licenceNote = licenceNote
    }

    /// Candidate model identified during feasibility work. The licence is NOT
    /// yet resolved (see docs/HELMET_MODEL_FEASIBILITY.md), so this constant
    /// must not be presented as cleared for redistribution.
    public static let candidateKeremberkeYOLOv8n = HelmetModelDescriptor(
        identifier: "yolov8n-hard-hat-detection",
        version: "keremberke-2023-01",
        labelMap: ["Hardhat": .helmet, "NO-Hardhat": .noHelmet],
        inputSide: 640,
        sourceDescription: "huggingface.co/keremberke/yolov8n-hard-hat-detection, trained on the Roboflow hard-hat-detection dataset",
        licenceNote: "Repository declares no licence; YOLOv8 code is AGPL-3.0. Unresolved."
    )

    /// Multi-class PPE model trained in this project (ML/training/train_ppe_v2.py).
    /// Weights are not in the repository; see ML/README.md for provenance and the
    /// measured per-class test results.
    public static let ppeYOLOv8s = HelmetModelDescriptor(
        identifier: "yolov8s-ppe-5class",
        version: "buildsight-2026-10",
        labelMap: ["helmet": .helmet, "no-helmet": .noHelmet, "vest": .vest, "gloves": .gloves, "no-gloves": .noGloves],
        inputSide: 640,
        sourceDescription: "YOLOv8s fine-tuned on Ultralytics Construction-PPE (AGPL-3.0) and Roboflow ppe-detection_data-adcya v3 (CC BY 4.0)",
        licenceNote: "Training data includes an AGPL-3.0 dataset and Ultralytics YOLOv8 is AGPL-3.0. Redistribution terms unresolved."
    )
}

/// One box the model produced. `score` is the raw class confidence from the
/// network. It is a ranking signal, not a calibrated probability.
public struct HelmetObservation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var label: HelmetLabel
    public var score: Double
    public var box: NormalizedRect

    public init(id: UUID = UUID(), label: HelmetLabel, score: Double, box: NormalizedRect) {
        self.id = id
        self.label = label
        self.score = score
        self.box = box
    }
}

public enum UnableToAssessReason: String, Codable, Sendable {
    case imageTooSmall
    case imageTooBlurry
    case noHeadsDetected
    case onlyLowConfidenceDetections
}

public enum HelmetOutcome: Codable, Hashable, Sendable {
    /// At least one head was confidently classified as not wearing a helmet.
    case suspectedMissingHelmet(count: Int)
    /// Heads were found and none was flagged. This is deliberately not "safe":
    /// workers outside the frame or hidden from view are simply not assessed.
    case helmetsDetected(helmets: Int, uncertain: Int)
    case unableToAssess(UnableToAssessReason)
}

public enum HeadState: String, Codable, Sendable {
    case helmetWorn
    case suspectedMissingHelmet
    case uncertain
}

public struct HeadFinding: Codable, Hashable, Sendable {
    public var observationID: UUID
    public var state: HeadState
}

/// Persisted result for one photo. Re-analysing a photo replaces the same
/// record (same id), so history never contains two competing analyses.
public struct HelmetAnalysis: SyncableRecord {
    public static let recordType: RecordType = .helmetAnalysis

    public enum State: Codable, Hashable, Sendable {
        case pending
        case finished(HelmetOutcome)
        case failed(String)
    }

    public var id: UUID
    public var projectID: UUID
    public var photoID: UUID
    public var modelIdentifier: String
    public var modelVersion: String
    public var policyVersion: String
    public var analysedAt: Date
    public var inferenceMilliseconds: Double?
    public var state: State
    public var observations: [HelmetObservation]
    public var findings: [HeadFinding]
    /// Vests/gloves seen by a multi-class model. Optional so records saved
    /// by the helmet-only model still decode.
    public var equipment: EquipmentSummary?
    public var review: HumanReviewStatus
    public var linkedIssueID: UUID?
    public var updatedAt: Date
    public var serverVersion: Int

    public init(id: UUID = UUID(), projectID: UUID, photoID: UUID, modelIdentifier: String, modelVersion: String, policyVersion: String, analysedAt: Date, inferenceMilliseconds: Double? = nil, state: State, observations: [HelmetObservation] = [], findings: [HeadFinding] = [], equipment: EquipmentSummary? = nil, review: HumanReviewStatus = .notRequired, linkedIssueID: UUID? = nil, serverVersion: Int = 0) {
        self.equipment = equipment
        self.id = id
        self.projectID = projectID
        self.photoID = photoID
        self.modelIdentifier = modelIdentifier
        self.modelVersion = modelVersion
        self.policyVersion = policyVersion
        self.analysedAt = analysedAt
        self.inferenceMilliseconds = inferenceMilliseconds
        self.state = state
        self.observations = observations
        self.findings = findings
        self.review = review
        self.linkedIssueID = linkedIssueID
        self.updatedAt = analysedAt
        self.serverVersion = serverVersion
    }

    public var outcome: HelmetOutcome? {
        if case .finished(let o) = state { return o }
        return nil
    }

    public var suspectedMissingCount: Int {
        if case .suspectedMissingHelmet(let n)? = outcome { return n }
        return 0
    }
}
