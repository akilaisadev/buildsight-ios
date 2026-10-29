import Foundation
import Observation

// MARK: - Issue detail

@MainActor
@Observable
public final class IssueDetailViewModel {
    public private(set) var events: [IssueEvent] = []
    public private(set) var errorMessage: String?
    public var comment = ""
    public var reasonText = ""

    public let issueID: UUID
    private let actor: ActingUser
    private let issues: IssueRepository
    private let workflow: HelmetWorkflow
    private let session: ReauthenticationGate
    private let sync: SyncTriggering
    private let clock: @Sendable () -> Date

    public init(issueID: UUID, actor: ActingUser, issues: IssueRepository, workflow: HelmetWorkflow, session: ReauthenticationGate, sync: SyncTriggering = NoopSyncTrigger(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.issueID = issueID
        self.actor = actor
        self.issues = issues
        self.workflow = workflow
        self.session = session
        self.sync = sync
        self.clock = clock
    }

    public func loadEvents() async {
        events = (try? await issues.events(issueID: issueID, projectID: actor.projectID)) ?? []
    }

    public func availableTransitions(for issue: Issue) -> [IssueTransition] {
        IssueWorkflow.availableTransitions(for: issue, actorID: actor.userID, role: actor.role)
    }

    public func canReviewFlag(_ issue: Issue) -> Bool {
        issue.review == .awaitingReview && actor.role.can(.reviewHelmetFlag)
    }

    /// Closing and reopening are the sensitive actions the proposal gates
    /// behind a fresh Face ID check (when the user has the gate enabled).
    public func perform(_ transition: IssueTransition, reason: String? = nil) async -> Bool {
        if transition == .close || transition == .reopen {
            guard await session.confirmSensitiveAction(reason: "Confirm to \(transition.displayName.lowercased()) this issue") else {
                errorMessage = "Confirmation was not completed."
                return false
            }
        }
        do {
            _ = try await issues.transition(transition, issueID: issueID, actor: actor, reason: reason, now: clock())
            errorMessage = nil
            reasonText = ""
            await sync.requestSync()
            await loadEvents()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    public func addComment() async {
        do {
            try await issues.comment(issueID: issueID, text: comment, actor: actor, now: clock())
            comment = ""
            errorMessage = nil
            await sync.requestSync()
            await loadEvents()
        } catch { errorMessage = Self.message(for: error) }
    }

    public func assign(to userID: UUID?) async {
        do {
            try await issues.assign(issueID: issueID, to: userID, actor: actor, now: clock())
            await sync.requestSync()
            await loadEvents()
        } catch { errorMessage = Self.message(for: error) }
    }

    public func review(_ decision: HelmetReviewDecision, analysisID: UUID) async -> Bool {
        do {
            switch try await workflow.review(analysisID: analysisID, decision: decision, reviewerID: actor.userID, role: actor.role, now: clock()) {
            case .success:
                errorMessage = nil
                await sync.requestSync()
                await loadEvents()
                return true
            case .failure(let e):
                errorMessage = Self.message(for: e)
                return false
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case IssueRepositoryError.workflow(let e):
            switch e {
            case .notAllowedFromStatus: return "That step isn't available from the current status."
            case .notPermitted: return "Your role can't do that on this issue."
            case .verifierMustDifferFromResolver: return "Someone other than the person who resolved it must verify."
            case .reasonRequired: return "Add a short reason first."
            case .helmetFlagStillAwaitingReview: return "Review the helmet flag (confirm, correct or dismiss) before closing."
            }
        case IssueRepositoryError.notPermitted: return "Your role can't do that."
        case IssueRepositoryError.emptyComment: return "Write a comment first."
        case IssueRepositoryError.notFound: return "This issue is no longer available."
        case HelmetReviewError.notPermitted: return "Only supervisors, inspectors and project managers can review helmet flags."
        case HelmetReviewError.alreadyReviewed: return "This flag has already been reviewed."
        case HelmetReviewError.reasonRequired: return "A reason is required to dismiss a flag."
        case HelmetReviewError.noLinkedIssue: return "This flag's issue could not be found."
        default: return error.localizedDescription
        }
    }
}

/// Narrow view of `SessionManager` for view models that only need the
/// re-authentication check, so they do not depend on the whole session type.
public protocol ReauthenticationGate: Sendable {
    func confirmSensitiveAction(reason: String) async -> Bool
}

/// The session manager is the production gate: it re-prompts for Face ID only
/// when the user has turned the biometric gate on.
extension SessionManager: ReauthenticationGate {}

public struct AlwaysAllowGate: ReauthenticationGate {
    public init() {}
    public func confirmSensitiveAction(reason: String) async -> Bool { true }
}

// MARK: - Report issue

@MainActor
@Observable
public final class ReportIssueViewModel {
    public var draft: IssueDraft
    public private(set) var errorMessage: String?
    public private(set) var savedIssueID: UUID?

    private let actor: ActingUser
    private let issues: IssueRepository
    private let store: LocalStore
    private let location: LocationProviding
    private let sync: SyncTriggering
    private let clock: @Sendable () -> Date

    public init(draft: IssueDraft? = nil, actor: ActingUser, photoIDs: [UUID] = [], areaID: UUID? = nil, issues: IssueRepository, store: LocalStore, location: LocationProviding, sync: SyncTriggering = NoopSyncTrigger(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.draft = draft ?? IssueDraft(projectID: actor.projectID, areaID: areaID, photoIDs: photoIDs, savedAt: clock())
        self.actor = actor
        self.issues = issues
        self.store = store
        self.location = location
        self.sync = sync
        self.clock = clock
    }

    public var canSubmit: Bool { !draft.title.trimmingCharacters(in: .whitespaces).isEmpty && draft.areaID != nil }

    /// Drafts stay on the device and are not synced. Empty drafts are not stored.
    public func saveDraft() async {
        let hasContent = !draft.title.isEmpty || !draft.details.isEmpty || !draft.photoIDs.isEmpty
        guard hasContent else { return }
        draft.savedAt = clock()
        try? await store.saveDraft(draft)
    }

    public func discardDraft() async { try? await store.deleteDraft(draft.id) }

    public func submit() async -> Bool {
        guard canSubmit else { errorMessage = "Add a title and choose a site area."; return false }
        let fix = await location.currentFix(timeout: 4)
        do {
            let issue = try await issues.create(draft: draft, actor: actor, location: fix, now: clock())
            savedIssueID = issue.id
            errorMessage = nil
            await sync.requestSync()
            return true
        } catch IssueRepositoryError.notPermitted {
            errorMessage = "Your role can't report issues on this project."
        } catch {
            errorMessage = "Couldn't save the issue: \(error.localizedDescription)"
        }
        return false
    }
}

// MARK: - Tasks

@MainActor
@Observable
public final class TaskListViewModel {
    public var bucket: TaskBucket = .today
    public private(set) var errorMessage: String?

    private let actor: ActingUser
    private let tasks: TaskRepository
    private let sync: SyncTriggering
    private let clock: @Sendable () -> Date
    private let calendar: Calendar

    public init(initialBucket: TaskBucket = .today, actor: ActingUser, tasks: TaskRepository, sync: SyncTriggering = NoopSyncTrigger(), clock: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.bucket = initialBucket
        self.actor = actor
        self.tasks = tasks
        self.sync = sync
        self.clock = clock
        self.calendar = calendar
    }

    public var canCreate: Bool { actor.role.can(.createTask) }

    public func grouped(_ snapshot: ProjectSnapshot) -> [TaskBucket: [TaskItem]] {
        TaskScheduling.grouped(snapshot.tasks, now: clock(), calendar: calendar)
    }

    public func perform(_ action: TaskRepository.Action, on taskID: UUID) async {
        do {
            _ = try await tasks.perform(action, taskID: taskID, actor: actor, now: clock())
            errorMessage = nil
            await sync.requestSync()
        } catch { errorMessage = "That change isn't possible for this task." }
    }

    public func create(title: String, details: String, areaID: UUID?, assigneeID: UUID, priority: Priority, dueDate: Date, relatedIssueID: UUID?) async -> Bool {
        do {
            _ = try await tasks.create(title: title, details: details, areaID: areaID, assigneeID: assigneeID, priority: priority, dueDate: dueDate, relatedIssueID: relatedIssueID, actor: actor, now: clock())
            errorMessage = nil
            await sync.requestSync()
            return true
        } catch TaskRepositoryError.emptyTitle {
            errorMessage = "Give the task a title."
        } catch TaskRepositoryError.notPermitted {
            errorMessage = "Your role can't create tasks."
        } catch { errorMessage = error.localizedDescription }
        return false
    }
}

// MARK: - Inspections

@MainActor
@Observable
public final class InspectionRunViewModel {
    public var inspection: Inspection
    public private(set) var errorMessage: String?
    public private(set) var completed = false
    private var lastSaved: Inspection

    private let actor: ActingUser
    private let repository: InspectionRepository
    private let sync: SyncTriggering
    private let session: ReauthenticationGate
    private let clock: @Sendable () -> Date

    public init(inspection: Inspection, actor: ActingUser, repository: InspectionRepository, session: ReauthenticationGate = AlwaysAllowGate(), sync: SyncTriggering = NoopSyncTrigger(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.inspection = inspection
        self.lastSaved = inspection
        self.actor = actor
        self.repository = repository
        self.session = session
        self.sync = sync
        self.clock = clock
        self.completed = inspection.completedAt != nil
    }

    public var isReadOnly: Bool { inspection.completedAt != nil }
    public var progress: String { "\(inspection.answeredCount) of \(inspection.items.count) answered" }

    public func set(_ result: ChecklistResult, for itemID: UUID) {
        guard !isReadOnly, let i = inspection.items.firstIndex(where: { $0.id == itemID }) else { return }
        inspection.items[i].result = result
    }

    public func setNote(_ note: String, for itemID: UUID) {
        guard !isReadOnly, let i = inspection.items.firstIndex(where: { $0.id == itemID }) else { return }
        inspection.items[i].note = note
    }

    public func attach(photoID: UUID, to itemID: UUID) {
        guard !isReadOnly, let i = inspection.items.firstIndex(where: { $0.id == itemID }) else { return }
        inspection.items[i].photoIDs.append(photoID)
    }

    public func saveProgress() async {
        do {
            try await repository.saveProgress(inspection, previous: lastSaved, now: clock())
            lastSaved = inspection
            errorMessage = nil
            await sync.requestSync()
        } catch { errorMessage = "Couldn't save progress: \(error.localizedDescription)" }
    }

    public func complete() async {
        if let rule = InspectionRules.validateCompletion(inspection) {
            errorMessage = Self.message(for: rule, inspection: inspection)
            return
        }
        do {
            inspection = try await repository.complete(inspection, actor: actor, now: clock())
            lastSaved = inspection
            completed = true
            errorMessage = nil
            await sync.requestSync()
        } catch { errorMessage = error.localizedDescription }
    }

    public func raiseEmergencyStop(reason: String) async -> Bool {
        guard await session.confirmSensitiveAction(reason: "Confirm emergency stop") else { return false }
        do {
            let (updated, _) = try await repository.raiseEmergencyStop(inspection, reason: reason, actor: actor, now: clock())
            inspection = updated
            lastSaved = updated
            errorMessage = nil
            await sync.requestSync()
            return true
        } catch InspectionRepositoryError.rule(.emergencyStopNeedsReason) {
            errorMessage = "Say why work is being stopped."
        } catch { errorMessage = error.localizedDescription }
        return false
    }

    static func message(for error: InspectionError, inspection: Inspection) -> String {
        switch error {
        case .unansweredItems(let n): "\(n) item\(n == 1 ? "" : "s") still need a result."
        case .failedItemNeedsNote(let id): "Add a note or photo for the failed item “\(inspection.items.first { $0.id == id }?.title ?? "item")”."
        case .emergencyStopNeedsReason: "Say why work is being stopped."
        case .alreadyCompleted: "This inspection is already complete."
        case .notPermitted: "Your role can't do that."
        }
    }
}
