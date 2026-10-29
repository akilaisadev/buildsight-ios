import Foundation

public struct HelmetWorkflowResult: Sendable {
    public var analysis: HelmetAnalysis
    /// The issue now linked to this photo, new or pre-existing.
    public var issue: Issue?
    public var createdNewIssue: Bool
}

/// Connects capture → analysis → safety issue. One entry point so the camera
/// flow, the "analyse again" button and a future batch job behave identically.
public struct HelmetWorkflow: Sendable {
    private let analyzer: HelmetAnalyzing?
    private let store: LocalStore
    private let policy: HelmetThresholdPolicy
    private let evidenceURL: @Sendable (EvidencePhoto) -> URL

    /// `analyzer` is nil when no model is bundled; the workflow then records a
    /// failed analysis instead of pretending, and evidence saving is unaffected.
    public init(analyzer: HelmetAnalyzing?, store: LocalStore, policy: HelmetThresholdPolicy = .standard, evidenceURL: @escaping @Sendable (EvidencePhoto) -> URL) {
        self.analyzer = analyzer
        self.store = store
        self.policy = policy
        self.evidenceURL = evidenceURL
    }

    /// Never throws for analysis problems: those become a `.failed` analysis
    /// the user can retry. It throws only if local persistence itself fails.
    public func analyse(photo: EvidencePhoto, now: Date) async throws -> HelmetWorkflowResult {
        let analysisID = SafetyIssueFactory.analysisID(forPhoto: photo.id)
        let previous = try await store.record(HelmetAnalysis.self, id: analysisID)
        let existingIssue = try await store.record(Issue.self, id: SafetyIssueFactory.issueID(forPhoto: photo.id))

        var analysis = HelmetAnalysis(
            id: analysisID, projectID: photo.projectID, photoID: photo.id,
            modelIdentifier: analyzer?.descriptor.identifier ?? "none",
            modelVersion: analyzer?.descriptor.version ?? "none",
            policyVersion: policy.version, analysedAt: now, state: .pending,
            // A human decision survives re-analysis; the new run must not erase it.
            review: previous?.review ?? .notRequired,
            linkedIssueID: previous?.linkedIssueID ?? existingIssue?.id,
            serverVersion: previous?.serverVersion ?? 0
        )

        if let analyzer {
            do {
                let raw = try await analyzer.analyse(imageAt: evidenceURL(photo))
                let interpretation = HelmetInterpreter.interpret(observations: raw.observations, quality: raw.quality, policy: policy)
                analysis.observations = raw.observations
                analysis.findings = interpretation.findings
                analysis.equipment = interpretation.equipment.isEmpty ? nil : interpretation.equipment
                analysis.inferenceMilliseconds = raw.inferenceMilliseconds
                analysis.state = .finished(interpretation.outcome)
            } catch {
                analysis.state = .failed(Self.describe(error))
            }
        } else {
            analysis.state = .failed("No helmet model is installed in this build")
        }

        var writes: [RecordWrite] = []
        var newIssue: Issue?

        if let issue = SafetyIssueFactory.makeIssue(for: analysis, photo: photo, existingIssue: existingIssue, now: now) {
            newIssue = issue
            analysis.review = .awaitingReview
            analysis.linkedIssueID = issue.id
            let created = IssueEvent(projectID: issue.projectID, issueID: issue.id, actorID: photo.creatorID, at: now, kind: .created, note: "Machine-generated from photo analysis")
            let notification = AppNotification(projectID: issue.projectID, kind: .helmetFlag, title: "Possible missing helmet flagged", body: "Awaiting human review", createdAt: now, deepLink: .issue(projectID: issue.projectID, issueID: issue.id))
            writes.append(try RecordWrite(issue, sortDate: issue.createdAt))
            writes.append(try RecordWrite(created, parentID: issue.id, sortDate: now))
            writes.append(try RecordWrite(notification, sortDate: now))
        } else if existingIssue != nil, previous != nil {
            // Same photo analysed again: no second issue. Leave a trace in the
            // audit history so the reviewer can see it was re-run.
            if let issue = existingIssue {
                let event = IssueEvent(projectID: issue.projectID, issueID: issue.id, actorID: photo.creatorID, at: now, kind: .reanalysed, note: analysis.outcome?.summary)
                writes.append(try RecordWrite(event, parentID: issue.id, sortDate: now))
            }
        }

        writes.append(try RecordWrite(analysis, parentID: photo.id, sortDate: now, previous: previous))
        try await store.commit(writes)
        return HelmetWorkflowResult(analysis: analysis, issue: newIssue ?? existingIssue, createdNewIssue: newIssue != nil)
    }

    /// Applies a human decision to a machine-generated flag and persists the
    /// issue, the analysis and the audit event together.
    public func review(analysisID: UUID, decision: HelmetReviewDecision, reviewerID: UUID, role: Role, now: Date) async throws -> Result<HelmetReviewResult, HelmetReviewError> {
        guard let analysis = try await store.record(HelmetAnalysis.self, id: analysisID),
              let issueID = analysis.linkedIssueID,
              let issue = try await store.record(Issue.self, id: issueID) else { return .failure(.noLinkedIssue) }
        let result = SafetyIssueFactory.review(decision: decision, issue: issue, analysis: analysis, reviewerID: reviewerID, role: role, now: now)
        if case .success(let r) = result {
            try await store.commit([
                try RecordWrite(r.issue, sortDate: r.issue.createdAt, previous: issue),
                try RecordWrite(r.analysis, parentID: r.analysis.photoID, sortDate: r.analysis.analysedAt, previous: analysis),
                try RecordWrite(r.event, parentID: issue.id, sortDate: now),
            ])
        }
        return result
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case HelmetAnalyzerError.modelUnavailable(let m): "Model unavailable: \(m)"
        case HelmetAnalyzerError.imageUnreadable: "The photo could not be read"
        case HelmetAnalyzerError.inferenceFailed(let m): "Analysis failed: \(m)"
        default: error.localizedDescription
        }
    }
}
