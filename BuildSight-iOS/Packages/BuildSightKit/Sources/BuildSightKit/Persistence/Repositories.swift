import Foundation

/// Everything one project owns, read in a single pass. Dashboard, lists, map
/// and timeline all derive from the same snapshot, which is what keeps their
/// counts consistent with each other.
public struct ProjectSnapshot: Sendable {
    public var project: Project
    public var areas: [SiteArea]
    public var members: [TeamMember]
    public var photos: [EvidencePhoto]
    public var issues: [Issue]
    public var inspections: [Inspection]
    public var tasks: [TaskItem]
    public var analyses: [HelmetAnalysis]
    public var notifications: [AppNotification]

    public func area(_ id: UUID?) -> SiteArea? { id.flatMap { id in areas.first { $0.id == id } } }
    public func areaName(_ id: UUID?) -> String { area(id)?.displayName ?? "Unassigned area" }
    public func memberName(_ userID: UUID?) -> String {
        userID.flatMap { id in members.first { $0.userID == id }?.displayName } ?? "Unassigned"
    }
    public func issue(_ id: UUID) -> Issue? { issues.first { $0.id == id } }
    public func photo(_ id: UUID) -> EvidencePhoto? { photos.first { $0.id == id } }
}

public struct ProjectRepository: Sendable {
    public let store: LocalStore
    public init(store: LocalStore) { self.store = store }

    public func projects(for profile: UserProfile) async throws -> [Project] {
        var result: [Project] = []
        for id in profile.projectIDs {
            if let project = try await store.record(Project.self, id: id) { result.append(project) }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Reading is always scoped by projectID at the query level; callers never
    /// filter a global list, so another project's data is never in memory here.
    public func snapshot(projectID: UUID) async throws -> ProjectSnapshot? {
        guard let project = try await store.record(Project.self, id: projectID) else { return nil }
        async let areas = store.records(SiteArea.self, projectID: projectID)
        async let members = store.records(TeamMember.self, projectID: projectID)
        async let photos = store.records(EvidencePhoto.self, projectID: projectID)
        async let issues = store.records(Issue.self, projectID: projectID)
        async let inspections = store.records(Inspection.self, projectID: projectID)
        async let tasks = store.records(TaskItem.self, projectID: projectID)
        async let analyses = store.records(HelmetAnalysis.self, projectID: projectID)
        async let notifications = store.records(AppNotification.self, projectID: projectID)
        return ProjectSnapshot(
            project: project, areas: try await areas.sorted { $0.name < $1.name }, members: try await members,
            photos: try await photos, issues: try await issues, inspections: try await inspections,
            tasks: try await tasks, analyses: try await analyses, notifications: try await notifications
        )
    }
}

// MARK: - Issues

public enum IssueRepositoryError: Error, Equatable, Sendable {
    case notFound
    case workflow(IssueWorkflowError)
    case notPermitted
    case emptyTitle
    case emptyComment
}

public struct IssueRepository: Sendable {
    public let store: LocalStore
    public init(store: LocalStore) { self.store = store }

    public func create(draft: IssueDraft, actor: ActingUser, location: LocationFix, now: Date) async throws -> Issue {
        guard actor.role.can(.reportIssue) else { throw IssueRepositoryError.notPermitted }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let areaID = draft.areaID else { throw IssueRepositoryError.emptyTitle }
        let issue = Issue(
            projectID: actor.projectID, areaID: areaID, title: title, details: draft.details,
            category: draft.category, priority: draft.priority, assigneeID: draft.assigneeID,
            reporterID: actor.userID, dueDate: draft.dueDate, createdAt: now,
            evidencePhotoIDs: draft.photoIDs, location: location
        )
        var writes = [try RecordWrite(issue, sortDate: now),
                      try RecordWrite(IssueEvent(projectID: issue.projectID, issueID: issue.id, actorID: actor.userID, at: now, kind: .created), parentID: issue.id, sortDate: now)]
        if let assignee = draft.assigneeID, assignee != actor.userID {
            let n = AppNotification(projectID: issue.projectID, kind: .issueAssigned, title: "Issue assigned", body: title, createdAt: now, deepLink: .issue(projectID: issue.projectID, issueID: issue.id))
            writes.append(try RecordWrite(n, sortDate: now))
        }
        try await store.commit(writes)
        try await store.deleteDraft(draft.id)
        return issue
    }

    public func transition(_ transition: IssueTransition, issueID: UUID, actor: ActingUser, reason: String?, now: Date) async throws -> Issue {
        guard let issue = try await store.record(Issue.self, id: issueID), issue.projectID == actor.projectID else { throw IssueRepositoryError.notFound }
        switch IssueWorkflow.apply(transition, to: issue, actorID: actor.userID, role: actor.role, reason: reason, now: now) {
        case .failure(let e): throw IssueRepositoryError.workflow(e)
        case .success(let (updated, event)):
            try await store.commit([try RecordWrite(updated, sortDate: updated.createdAt, previous: issue),
                                    try RecordWrite(event, parentID: issue.id, sortDate: now)])
            return updated
        }
    }

    public func comment(issueID: UUID, text: String, actor: ActingUser, now: Date) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IssueRepositoryError.emptyComment }
        guard let issue = try await store.record(Issue.self, id: issueID), issue.projectID == actor.projectID else { throw IssueRepositoryError.notFound }
        let event = IssueEvent(projectID: issue.projectID, issueID: issue.id, actorID: actor.userID, at: now, kind: .commented, note: trimmed)
        try await store.commit([try RecordWrite(event, parentID: issue.id, sortDate: now)])
    }

    public func assign(issueID: UUID, to assigneeID: UUID?, actor: ActingUser, now: Date) async throws {
        guard actor.role.can(.progressIssue) || actor.role.can(.verifyIssue) else { throw IssueRepositoryError.notPermitted }
        guard var issue = try await store.record(Issue.self, id: issueID), issue.projectID == actor.projectID else { throw IssueRepositoryError.notFound }
        let before = issue
        issue.assigneeID = assigneeID
        issue.updatedAt = now
        var writes = [try RecordWrite(issue, sortDate: issue.createdAt, previous: before),
                      try RecordWrite(IssueEvent(projectID: issue.projectID, issueID: issue.id, actorID: actor.userID, at: now, kind: .assigned(to: assigneeID)), parentID: issue.id, sortDate: now)]
        if let assigneeID, assigneeID != actor.userID {
            let n = AppNotification(projectID: issue.projectID, kind: .issueAssigned, title: "Issue assigned", body: issue.title, createdAt: now, deepLink: .issue(projectID: issue.projectID, issueID: issue.id))
            writes.append(try RecordWrite(n, sortDate: now))
        }
        try await store.commit(writes)
    }

    public func events(issueID: UUID, projectID: UUID) async throws -> [IssueEvent] {
        try await store.records(IssueEvent.self, projectID: projectID, parentID: issueID).sorted { $0.at < $1.at }
    }
}

// MARK: - Tasks

public enum TaskRepositoryError: Error, Equatable, Sendable {
    case notFound, notPermitted, emptyTitle, invalid(TaskError)
}

public struct TaskRepository: Sendable {
    public let store: LocalStore
    public init(store: LocalStore) { self.store = store }

    public func create(title: String, details: String, areaID: UUID?, assigneeID: UUID, priority: Priority, dueDate: Date, relatedIssueID: UUID?, actor: ActingUser, now: Date) async throws -> TaskItem {
        guard actor.role.can(.createTask) else { throw TaskRepositoryError.notPermitted }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TaskRepositoryError.emptyTitle }
        let task = TaskItem(projectID: actor.projectID, areaID: areaID, title: trimmed, details: details, assigneeID: assigneeID, creatorID: actor.userID, priority: priority, dueDate: dueDate, relatedIssueID: relatedIssueID, createdAt: now)
        var writes = [try RecordWrite(task, sortDate: now)]
        if assigneeID != actor.userID {
            writes.append(try RecordWrite(AppNotification(projectID: task.projectID, kind: .issueAssigned, title: "Task assigned", body: trimmed, createdAt: now, deepLink: .task(projectID: task.projectID, taskID: task.id)), sortDate: now))
        }
        try await store.commit(writes)
        return task
    }

    public enum Action: Sendable { case start, complete, reopen }

    public func perform(_ action: Action, taskID: UUID, actor: ActingUser, now: Date) async throws -> TaskItem {
        guard let task = try await store.record(TaskItem.self, id: taskID), task.projectID == actor.projectID else { throw TaskRepositoryError.notFound }
        let result: Result<TaskItem, TaskError>
        switch action {
        case .start: result = TaskScheduling.start(task, now: now)
        case .complete: result = TaskScheduling.complete(task, now: now)
        case .reopen: result = TaskScheduling.reopen(task, now: now)
        }
        switch result {
        case .failure(let e): throw TaskRepositoryError.invalid(e)
        case .success(let updated):
            try await store.commit([try RecordWrite(updated, sortDate: updated.createdAt, previous: task)])
            return updated
        }
    }
}

// MARK: - Inspections

public enum InspectionRepositoryError: Error, Equatable, Sendable {
    case notFound
    case rule(InspectionError)
}

public struct InspectionRepository: Sendable {
    public let store: LocalStore
    public init(store: LocalStore) { self.store = store }

    public func start(template: ChecklistTemplate, areaID: UUID, actor: ActingUser, location: LocationFix, dueDate: Date? = nil, now: Date) async throws -> Inspection {
        switch InspectionRules.start(template: template, projectID: actor.projectID, areaID: areaID, inspectorID: actor.userID, role: actor.role, location: location, now: now, dueDate: dueDate) {
        case .failure(let e): throw InspectionRepositoryError.rule(e)
        case .success(let inspection):
            try await store.commit([try RecordWrite(inspection, sortDate: now)])
            return inspection
        }
    }

    /// Save-progress: persists answers without any completion checks.
    public func saveProgress(_ inspection: Inspection, previous: Inspection?, now: Date) async throws {
        var copy = inspection
        copy.updatedAt = now
        try await store.commit([try RecordWrite(copy, sortDate: copy.startedAt, previous: previous)])
    }

    public func complete(_ inspection: Inspection, actor: ActingUser, now: Date) async throws -> Inspection {
        switch InspectionRules.complete(inspection, now: now) {
        case .failure(let e): throw InspectionRepositoryError.rule(e)
        case .success(let done):
            try await store.commit([try RecordWrite(done, sortDate: done.startedAt, previous: inspection)])
            return done
        }
    }

    /// Raises the stop-work notice: updates the inspection, creates the
    /// Critical issue and notifies in one atomic commit.
    public func raiseEmergencyStop(_ inspection: Inspection, reason: String, actor: ActingUser, now: Date) async throws -> (Inspection, Issue) {
        switch InspectionRules.raiseEmergencyStop(on: inspection, reason: reason, actorID: actor.userID, role: actor.role, now: now) {
        case .failure(let e): throw InspectionRepositoryError.rule(e)
        case .success(let (updated, issue)):
            let event = IssueEvent(projectID: issue.projectID, issueID: issue.id, actorID: actor.userID, at: now, kind: .created, note: "Raised from emergency stop")
            let note = AppNotification(projectID: issue.projectID, kind: .emergencyStop, title: "Emergency stop raised", body: reason, createdAt: now, deepLink: .issue(projectID: issue.projectID, issueID: issue.id))
            try await store.commit([try RecordWrite(updated, sortDate: updated.startedAt, previous: inspection),
                                    try RecordWrite(issue, sortDate: now), try RecordWrite(event, parentID: issue.id, sortDate: now),
                                    try RecordWrite(note, sortDate: now)])
            return (updated, issue)
        }
    }

    public func clearEmergencyStop(_ inspection: Inspection, actor: ActingUser, now: Date) async throws {
        switch InspectionRules.clearEmergencyStop(on: inspection, actorID: actor.userID, role: actor.role, now: now) {
        case .failure(let e): throw InspectionRepositoryError.rule(e)
        case .success(let updated): try await store.commit([try RecordWrite(updated, sortDate: updated.startedAt, previous: inspection)])
        }
    }
}

// MARK: - Notifications

public struct NotificationRepository: Sendable {
    public let store: LocalStore
    public init(store: LocalStore) { self.store = store }

    public func markRead(_ notification: AppNotification, now: Date) async throws {
        guard notification.readAt == nil else { return }
        var n = notification
        n.readAt = now
        n.updatedAt = now
        try await store.commit([try RecordWrite(n, sortDate: n.createdAt, previous: notification)])
    }

    public func markAllRead(projectID: UUID, now: Date) async throws {
        let unread = try await store.records(AppNotification.self, projectID: projectID).filter { !$0.isRead }
        try await store.commit(try unread.map { n in
            var copy = n; copy.readAt = now; copy.updatedAt = now
            return try RecordWrite(copy, sortDate: copy.createdAt, previous: n)
        })
    }
}
