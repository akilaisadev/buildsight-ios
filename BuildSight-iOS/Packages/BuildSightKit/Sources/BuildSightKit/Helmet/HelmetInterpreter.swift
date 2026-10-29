import Foundation

/// Image-level facts gathered before inference. A struct rather than a CGImage
/// so the interpreter stays pure and testable.
public struct ImageQuality: Codable, Hashable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Variance of the Laplacian on a downscaled greyscale copy; higher is sharper.
    public var sharpness: Double

    public init(pixelWidth: Int, pixelHeight: Int, sharpness: Double) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sharpness = sharpness
    }
}

/// How raw model boxes become BuildSight conclusions. Every number here is a
/// policy choice, not a measured probability; they are meant to be tuned
/// against the evaluation set and the version string is stored on each result.
public struct HelmetThresholdPolicy: Sendable {
    public var version: String
    /// Boxes below this are treated as noise and discarded.
    public var minimumScore: Double
    /// A "no helmet" box must reach this to count as a suspected violation.
    /// Set above `minimumScore` because a false flag costs a supervisor's time.
    public var flagScore: Double
    /// Overlap at which a helmet box and a no-helmet box are the same head.
    public var conflictIoU: Double
    /// If conflicting boxes are closer in score than this, the head is uncertain.
    public var conflictMargin: Double
    public var minimumImageSide: Int
    /// Below this the image is considered too blurry to trust. Provisional:
    /// calibrated on the evaluation images, not on theory.
    public var minimumSharpness: Double

    public init(version: String = "policy-1", minimumScore: Double = 0.30, flagScore: Double = 0.50, conflictIoU: Double = 0.50, conflictMargin: Double = 0.15, minimumImageSide: Int = 320, minimumSharpness: Double = 20) {
        self.version = version
        self.minimumScore = minimumScore
        self.flagScore = flagScore
        self.conflictIoU = conflictIoU
        self.conflictMargin = conflictMargin
        self.minimumImageSide = minimumImageSide
        self.minimumSharpness = minimumSharpness
    }

    public static let standard = HelmetThresholdPolicy()
}

public struct HelmetInterpretation: Equatable, Sendable {
    public var findings: [HeadFinding]
    public var outcome: HelmetOutcome
    public var equipment: EquipmentSummary = .empty
}

public enum HelmetInterpreter {
    /// Pure function: observations + image facts → findings and one outcome.
    /// Missing-helmet conclusions only ever come from a "no helmet" detection;
    /// an empty or helmet-free result is never turned into a violation.
    public static func interpret(
        observations: [HelmetObservation],
        quality: ImageQuality,
        policy: HelmetThresholdPolicy = .standard
    ) -> HelmetInterpretation {
        if min(quality.pixelWidth, quality.pixelHeight) < policy.minimumImageSide {
            return HelmetInterpretation(findings: [], outcome: .unableToAssess(.imageTooSmall))
        }
        if quality.sharpness < policy.minimumSharpness {
            return HelmetInterpretation(findings: [], outcome: .unableToAssess(.imageTooBlurry))
        }

        let candidates = observations
            .filter { $0.label.isHead && $0.score >= policy.minimumScore }
            .sorted { $0.score > $1.score }

        // Walk from most to least confident. A box is dropped if a more
        // confident box of the other class already covers the same head.
        var kept: [HelmetObservation] = []
        var conflicted: [UUID] = []
        for obs in candidates {
            if let rival = kept.first(where: { $0.label != obs.label && $0.box.intersectionOverUnion(with: obs.box) >= policy.conflictIoU }) {
                if rival.score - obs.score < policy.conflictMargin {
                    conflicted.append(rival.id)   // too close to call: head is uncertain
                }
                continue
            }
            kept.append(obs)
        }

        let findings: [HeadFinding] = kept.map { obs in
            if conflicted.contains(obs.id) { return HeadFinding(observationID: obs.id, state: .uncertain) }
            switch obs.label {
            case .helmet:
                return HeadFinding(observationID: obs.id, state: .helmetWorn)
            case .noHelmet:
                return HeadFinding(observationID: obs.id, state: obs.score >= policy.flagScore ? .suspectedMissingHelmet : .uncertain)
            case .vest, .gloves, .noGloves:
                return HeadFinding(observationID: obs.id, state: .uncertain)   // unreachable: filtered to heads above
            }
        }

        let missing = findings.filter { $0.state == .suspectedMissingHelmet }.count
        let worn = findings.filter { $0.state == .helmetWorn }.count
        let uncertain = findings.filter { $0.state == .uncertain }.count

        let outcome: HelmetOutcome
        if missing > 0 {
            outcome = .suspectedMissingHelmet(count: missing)
        } else if worn > 0 {
            outcome = .helmetsDetected(helmets: worn, uncertain: uncertain)
        } else if uncertain > 0 {
            outcome = .unableToAssess(.onlyLowConfidenceDetections)
        } else {
            outcome = .unableToAssess(.noHeadsDetected)
        }
        return HelmetInterpretation(findings: findings, outcome: outcome, equipment: equipment(from: observations, policy: policy))
    }

    /// Counts what the model saw besides heads. Boxes below the noise floor are
    /// ignored; "no gloves" must also clear the flag score because that class
    /// was the weakest in testing, and it is only ever a reviewer hint.
    public static func equipment(from observations: [HelmetObservation], policy: HelmetThresholdPolicy = .standard) -> EquipmentSummary {
        var summary = EquipmentSummary()
        for obs in observations where obs.score >= policy.minimumScore {
            switch obs.label {
            case .vest: summary.vestsDetected += 1
            case .gloves: summary.glovesDetected += 1
            case .noGloves where obs.score >= policy.flagScore: summary.possibleBareHands += 1
            case .noGloves, .helmet, .noHelmet: break
            }
        }
        return summary
    }
}

public extension HelmetOutcome {
    /// Wording shown to users. Intentionally never says "safe" or "compliant".
    var summary: String {
        switch self {
        case .suspectedMissingHelmet(let n):
            return n == 1 ? "Possible missing helmet on 1 worker" : "Possible missing helmets on \(n) workers"
        case .helmetsDetected(let h, let u):
            let base = h == 1 ? "Helmet detected on 1 worker" : "Helmets detected on \(h) workers"
            return u > 0 ? "\(base); \(u) unclear" : base
        case .unableToAssess(let reason):
            switch reason {
            case .imageTooSmall: return "Unable to assess: image too small"
            case .imageTooBlurry: return "Unable to assess: image too blurry"
            case .noHeadsDetected: return "Unable to assess: no workers detected"
            case .onlyLowConfidenceDetections: return "Unable to assess: detections too uncertain"
            }
        }
    }
}
