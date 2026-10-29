import Foundation

public enum IssueTransition: String, CaseIterable, Sendable {
    case start      // open → inProgress
    case resolve    // inProgress → resolved
    case verify     // resolved → verified
    case close      // verified → closed
    case rework     // resolved → inProgress (verifier sends it back)
    case reopen     // verified/closed → open

    public var target: IssueStatus {
        switch self {
        case .start, .rework: .inProgress
        case .resolve: .resolved
        case .verify: .verified
        case .close: .closed
        case .reopen: .open
        }
    }

    /// Sending work back or reopening must say why; it becomes audit history.
    public var requiresReason: Bool { self == .rework || self == .reopen }

    public var displayName: String {
        switch self {
        case .start: "Start Work"
        case .resolve: "Mark Resolved"
        case .verify: "Verify"
        case .close: "Close"
        case .rework: "Send Back for Rework"
        case .reopen: "Reopen"
        }
    }
}

public enum IssueWorkflowError: Error, Equatable, Sendable {
    case notAllowedFromStatus(IssueStatus)
    case notPermitted
    case verifierMustDifferFromResolver
    case reasonRequired
    case helmetFlagStillAwaitingReview
}

/// The single place that decides which issue transitions exist and who may
/// perform them. Views ask `availableTransitions`; the repository calls
/// `apply`, so a transition can never be reached by bypassing the rules.
public enum IssueWorkflow {
    private static func sourceStatuses(for transition: IssueTransition) -> [IssueStatus] {
        switch transition {
        case .start: [.open]
        case .resolve: [.inProgress]
        case .verify, .rework: [.resolved]
        case .close: [.verified]
        case .reopen: [.verified, .closed]
        }
    }

    public static func check(_ transition: IssueTransition, on issue: Issue, actorID: UUID, role: Role, reason: String? = nil) -> IssueWorkflowError? {
        guard sourceStatuses(for: transition).contains(issue.status) else {
            return .notAllowedFromStatus(issue.status)
        }
        switch transition {
        case .start, .resolve:
            // Assignees can progress their own work; otherwise it takes a role
            // with progress rights. Inspectors observe, they don't do the work.
            let isAssignee = issue.assigneeID == actorID
            guard isAssignee || role.can(.progressIssue) else { return .notPermitted }
        case .verify, .rework:
            guard role.can(.verifyIssue) else { return .notPermitted }
            if issue.resolvedByID == actorID { return .verifierMustDifferFromResolver }
        case .close:
            guard role.can(.closeIssue) else { return .notPermitted }
            // A detector-generated flag must be judged by a person before it can
            // be closed as a real finding; dismissal is the dedicated path.
            if issue.review == .awaitingReview { return .helmetFlagStillAwaitingReview }
        case .reopen:
            guard role.can(.reopenIssue) else { return .notPermitted }
        }
        if transition.requiresReason, (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .reasonRequired
        }
        return nil
    }

    public static func availableTransitions(for issue: Issue, actorID: UUID, role: Role) -> [IssueTransition] {
        IssueTransition.allCases.filter { t in
            // Reason-gated transitions are offered; the UI collects the reason.
            let probe = check(t, on: issue, actorID: actorID, role: role, reason: "x")
            return probe == nil
        }
    }

    /// Returns the updated issue plus the audit event to persist with it.
    public static func apply(_ transition: IssueTransition, to issue: Issue, actorID: UUID, role: Role, reason: String? = nil, now: Date) -> Result<(Issue, IssueEvent), IssueWorkflowError> {
        if let error = check(transition, on: issue, actorID: actorID, role: role, reason: reason) {
            return .failure(error)
        }
        var updated = issue
        let from = issue.status
        updated.status = transition.target
        updated.updatedAt = now
        switch transition {
        case .resolve: updated.resolvedByID = actorID
        case .reopen, .rework: updated.resolvedByID = nil
        case .start where issue.assigneeID == nil: updated.assigneeID = actorID
        default: break
        }
        let event = IssueEvent(
            projectID: issue.projectID, issueID: issue.id, actorID: actorID, at: now,
            kind: .statusChanged(from: from, to: updated.status),
            note: reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return .success((updated, event))
    }
}
