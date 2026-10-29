import Testing
import Foundation
@testable import BuildSightKit

@Suite("Issue lifecycle and permissions")
struct IssueWorkflowTests {
    @Test("Happy path walks Open → In Progress → Resolved → Verified → Closed with an audit event each step")
    func fullLifecycle() throws {
        var issue = Fixture.issue(assignee: Fixture.worker)
        let steps: [(IssueTransition, UUID, Role, IssueStatus)] = [
            (.start, Fixture.worker, .siteWorker, .inProgress),
            (.resolve, Fixture.worker, .siteWorker, .resolved),
            (.verify, Fixture.supervisor, .supervisor, .verified),
            (.close, Fixture.supervisor, .supervisor, .closed),
        ]
        for (transition, actor, role, expected) in steps {
            let (updated, event) = try IssueWorkflow.apply(transition, to: issue, actorID: actor, role: role, now: Fixture.now).get()
            #expect(updated.status == expected)
            #expect(event.kind == .statusChanged(from: issue.status, to: expected))
            #expect(event.issueID == issue.id)
            issue = updated
        }
    }

    @Test("Cannot skip a step")
    func cannotSkip() {
        let issue = Fixture.issue(status: .open)
        let error = IssueWorkflow.check(.verify, on: issue, actorID: Fixture.supervisor, role: .supervisor)
        #expect(error == .notAllowedFromStatus(.open))
    }

    @Test("A site worker cannot verify or close")
    func workerCannotVerify() {
        let resolved = Fixture.issue(status: .resolved, resolvedBy: Fixture.supervisor)
        #expect(IssueWorkflow.check(.verify, on: resolved, actorID: Fixture.worker, role: .siteWorker) == .notPermitted)
        let verified = Fixture.issue(status: .verified)
        #expect(IssueWorkflow.check(.close, on: verified, actorID: Fixture.worker, role: .siteWorker) == .notPermitted)
    }

    @Test("The person who resolved an issue cannot verify it")
    func verifierDiffersFromResolver() {
        let issue = Fixture.issue(status: .resolved, resolvedBy: Fixture.supervisor)
        #expect(IssueWorkflow.check(.verify, on: issue, actorID: Fixture.supervisor, role: .supervisor) == .verifierMustDifferFromResolver)
        #expect(IssueWorkflow.check(.verify, on: issue, actorID: Fixture.otherSupervisor, role: .supervisor) == nil)
    }

    @Test("Rework and reopen need a reason")
    func reasonsRequired() {
        let resolved = Fixture.issue(status: .resolved, resolvedBy: Fixture.worker)
        #expect(IssueWorkflow.check(.rework, on: resolved, actorID: Fixture.supervisor, role: .supervisor, reason: "  ") == .reasonRequired)
        let closed = Fixture.issue(status: .closed)
        #expect(IssueWorkflow.check(.reopen, on: closed, actorID: Fixture.supervisor, role: .supervisor, reason: nil) == .reasonRequired)
    }

    @Test("Rework returns to In Progress and clears the resolver; reopen goes back to Open")
    func reworkAndReopen() throws {
        let resolved = Fixture.issue(status: .resolved, resolvedBy: Fixture.worker)
        let (reworked, event) = try IssueWorkflow.apply(.rework, to: resolved, actorID: Fixture.supervisor, role: .supervisor, reason: "Still leaking", now: Fixture.now).get()
        #expect(reworked.status == .inProgress)
        #expect(reworked.resolvedByID == nil)
        #expect(event.note == "Still leaking")

        let closed = Fixture.issue(status: .closed)
        let (reopened, _) = try IssueWorkflow.apply(.reopen, to: closed, actorID: Fixture.supervisor, role: .projectManager, reason: "Recurred", now: Fixture.now).get()
        #expect(reopened.status == .open)
    }

    @Test("Inspectors observe but cannot start or resolve issues they are not assigned")
    func inspectorCannotProgress() {
        let issue = Fixture.issue(status: .open, assignee: Fixture.worker)
        #expect(IssueWorkflow.check(.start, on: issue, actorID: Fixture.otherSupervisor, role: .inspector) == .notPermitted)
    }

    @Test("Available transitions match what the actor may actually do")
    func availableTransitions() {
        let resolved = Fixture.issue(status: .resolved, resolvedBy: Fixture.worker)
        let supervisorOptions = IssueWorkflow.availableTransitions(for: resolved, actorID: Fixture.supervisor, role: .supervisor)
        #expect(Set(supervisorOptions) == [.verify, .rework])
        let workerOptions = IssueWorkflow.availableTransitions(for: resolved, actorID: Fixture.otherSupervisor, role: .siteWorker)
        #expect(workerOptions.isEmpty)
    }

    @Test("Machine-generated flags cannot be closed until a person has reviewed them")
    func flagMustBeReviewedBeforeClose() {
        let issue = Fixture.issue(status: .verified, review: .awaitingReview, origin: .helmetDetection(analysisID: UUID()))
        #expect(IssueWorkflow.check(.close, on: issue, actorID: Fixture.supervisor, role: .supervisor) == .helmetFlagStillAwaitingReview)
    }
}
