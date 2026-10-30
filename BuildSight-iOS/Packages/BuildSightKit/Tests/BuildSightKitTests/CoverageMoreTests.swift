import Testing
import Foundation
@testable import BuildSightKit

private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "buildsight-test-\(UUID().uuidString)")! }

private func profile(_ memberships: [ProjectMembership]) -> UserProfile {
    UserProfile(id: Fixture.supervisor, displayName: "Sam", email: "sam@example.com", organisationName: "Org", memberships: memberships)
}

private func repository(projects: [Project]) async throws -> ProjectRepository {
    let store = try CoreDataLocalStore(storeURL: nil)
    try await store.commit(try projects.map { try RecordWrite($0, sortDate: Fixture.now) })
    return ProjectRepository(store: store)
}

@MainActor
@Suite("Project selection")
struct ProjectSelectionTests {
    let alpha = makeProject(id: Fixture.projectA, name: "Alpha Tower")
    let beta = makeProject(id: Fixture.projectB, name: "Beta Yard")

    private func both() -> UserProfile {
        profile([ProjectMembership(projectID: Fixture.projectA, role: .supervisor), ProjectMembership(projectID: Fixture.projectB, role: .engineer)])
    }

    @Test("Loading picks the first project by name and builds the acting user for it")
    func picksFirst() async throws {
        let selection = ProjectSelection(profile: both(), repository: try await repository(projects: [beta, alpha]), defaults: freshDefaults())
        await selection.load()
        #expect(selection.projects.map(\.name) == ["Alpha Tower", "Beta Yard"])
        #expect(selection.activeProjectID == Fixture.projectA)
        #expect(selection.activeProject?.name == "Alpha Tower")
        #expect(selection.actor?.role == .supervisor && selection.actor?.projectID == Fixture.projectA)
    }

    @Test("Switching project changes the role the person acts with")
    func switching() async throws {
        let selection = ProjectSelection(profile: both(), repository: try await repository(projects: [alpha, beta]), defaults: freshDefaults())
        await selection.load()
        selection.select(Fixture.projectB)
        #expect(selection.activeProjectID == Fixture.projectB)
        #expect(selection.actor?.role == .engineer)
    }

    @Test("The last project used is remembered next time")
    func remembers() async throws {
        let repo = try await repository(projects: [alpha, beta])
        let defaults = freshDefaults()
        let first = ProjectSelection(profile: both(), repository: repo, defaults: defaults)
        await first.load()
        first.select(Fixture.projectB)
        let second = ProjectSelection(profile: both(), repository: repo, defaults: defaults)
        await second.load()
        #expect(second.activeProjectID == Fixture.projectB)
    }

    @Test("A remembered project the person no longer belongs to is ignored")
    func forgetsRemoved() async throws {
        let defaults = freshDefaults()
        let me = profile([ProjectMembership(projectID: Fixture.projectA, role: .supervisor)])
        defaults.set(Fixture.projectB.uuidString, forKey: "project.selection.\(me.id.uuidString)")
        let selection = ProjectSelection(profile: me, repository: try await repository(projects: [alpha, beta]), defaults: defaults)
        await selection.load()
        #expect(selection.activeProjectID == Fixture.projectA)
    }

    @Test("Choosing nothing, or a project that isn't theirs, clears the selection", arguments: [UUID?.none, UUID()])
    func clears(_ id: UUID?) async throws {
        let selection = ProjectSelection(profile: both(), repository: try await repository(projects: [alpha, beta]), defaults: freshDefaults())
        await selection.load()
        selection.select(id)
        #expect(selection.activeProjectID == nil && selection.actor == nil && selection.activeProject == nil)
    }

    @Test("Someone with no projects has nothing selected")
    func noProjects() async throws {
        let selection = ProjectSelection(profile: profile([]), repository: try await repository(projects: [alpha]), defaults: freshDefaults())
        await selection.load()
        #expect(selection.projects.isEmpty && selection.activeProjectID == nil && selection.actor == nil)
    }

    @Test("A project that isn't in the local store yet is skipped")
    func missingLocally() async throws {
        let selection = ProjectSelection(profile: both(), repository: try await repository(projects: [beta]), defaults: freshDefaults())
        await selection.load()
        #expect(selection.projects.map(\.id) == [Fixture.projectB])
    }
}

@MainActor
@Suite("Project data model")
struct ProjectDataModelTests {
    @Test("Reloading fills in the snapshot of the project")
    func reload() async throws {
        let repo = try await repository(projects: [makeProject()])
        let model = ProjectDataModel(projectID: Fixture.projectA, repository: repo)
        #expect(model.snapshot == nil)
        await model.reload()
        #expect(model.snapshot?.project.name == "Tower A" && model.loadError == nil)
    }

    @Test("A project with no local data gives no snapshot and no error")
    func unknown() async throws {
        let model = ProjectDataModel(projectID: Fixture.projectB, repository: try await repository(projects: [makeProject()]))
        await model.reload()
        #expect(model.snapshot == nil && model.loadError == nil)
    }

    @Test("Observing picks up a record saved by any other screen")
    func observes() async throws {
        let store = try CoreDataLocalStore(storeURL: nil)
        try await store.commit([try RecordWrite(makeProject(), sortDate: Fixture.now)])
        let model = ProjectDataModel(projectID: Fixture.projectA, repository: ProjectRepository(store: store))
        let watching = Task { await model.observe() }
        defer { watching.cancel() }
        try await store.commit([try RecordWrite(Fixture.issue(), sortDate: Fixture.now)])
        for _ in 0..<60 where model.snapshot?.issues.count != 1 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.snapshot?.issues.count == 1)
    }
}

@Suite("Snapshot lookups")
struct SnapshotLookupTests {
    private let member = TeamMember(userID: Fixture.worker, projectID: Fixture.projectA, displayName: "Alex Lee", role: .siteWorker)
    private func snap(issues: [Issue] = [], photos: [EvidencePhoto] = []) -> ProjectSnapshot {
        ProjectSnapshot(project: makeProject(), areas: [SiteArea(id: Fixture.areaA, projectID: Fixture.projectA, name: "North", level: "L2")], members: [member],
                        photos: photos, issues: issues, inspections: [], tasks: [], analyses: [], notifications: [])
    }

    @Test("A known area shows its name and level")
    func knownArea() {
        #expect(snap().area(Fixture.areaA)?.displayName == "North • L2")
        #expect(snap().areaName(Fixture.areaA) == "North • L2")
    }

    @Test("A missing or unknown area is called unassigned", arguments: [UUID?.none, UUID()])
    func unknownArea(_ id: UUID?) {
        #expect(snap().area(id) == nil)
        #expect(snap().areaName(id) == "Unassigned area")
    }

    @Test("A known person shows their name; anyone else is unassigned", arguments: [(Fixture.worker, "Alex Lee"), (Fixture.supervisor, "Unassigned")])
    func people(_ c: (id: UUID, name: String)) { #expect(snap().memberName(c.id) == c.name) }

    @Test("No person at all is unassigned")
    func nobody() { #expect(snap().memberName(nil) == "Unassigned") }

    @Test("Issues and photos are found by id, or not at all")
    func finders() {
        let issue = Fixture.issue(), photo = Fixture.photo()
        let s = snap(issues: [issue], photos: [photo])
        #expect(s.issue(issue.id)?.id == issue.id && s.issue(UUID()) == nil)
        #expect(s.photo(photo.id)?.id == photo.id && s.photo(UUID()) == nil)
    }
}

@Suite("Assigning an issue")
struct AssignIssueTests {
    let supervisor = ActingUser(userID: Fixture.supervisor, displayName: "Sam", role: .supervisor, projectID: Fixture.projectA)

    private func seeded() async throws -> (IssueRepository, CoreDataLocalStore, Issue) {
        let store = try CoreDataLocalStore(storeURL: nil)
        let issue = Fixture.issue()
        try await store.commit([try RecordWrite(issue, sortDate: issue.createdAt)])
        return (IssueRepository(store: store), store, issue)
    }

    @Test("Assigning to someone else updates the issue, records it and notifies them")
    func assignsToOther() async throws {
        let (repo, store, issue) = try await seeded()
        try await repo.assign(issueID: issue.id, to: Fixture.worker, actor: supervisor, now: Fixture.now)
        #expect(try await store.record(Issue.self, id: issue.id)?.assigneeID == Fixture.worker)
        #expect(try await store.records(AppNotification.self, projectID: Fixture.projectA).count == 1)
        #expect(try await store.records(IssueEvent.self, projectID: Fixture.projectA).count == 1)
    }

    @Test("Assigning to yourself notifies nobody")
    func assignsToSelf() async throws {
        let (repo, store, issue) = try await seeded()
        try await repo.assign(issueID: issue.id, to: supervisor.userID, actor: supervisor, now: Fixture.now)
        #expect(try await store.records(AppNotification.self, projectID: Fixture.projectA).isEmpty)
    }

    @Test("Unassigning clears the person and notifies nobody")
    func unassigns() async throws {
        let (repo, store, issue) = try await seeded()
        try await repo.assign(issueID: issue.id, to: Fixture.worker, actor: supervisor, now: Fixture.now)
        try await repo.assign(issueID: issue.id, to: nil, actor: supervisor, now: Fixture.now)
        #expect(try await store.record(Issue.self, id: issue.id)?.assigneeID == nil)
        #expect(try await store.records(AppNotification.self, projectID: Fixture.projectA).count == 1)   // only the first assignment
    }

    @Test("An issue that does not exist cannot be assigned")
    func missingIssue() async throws {
        let (repo, _, _) = try await seeded()
        await #expect(throws: IssueRepositoryError.notFound) { try await repo.assign(issueID: UUID(), to: Fixture.worker, actor: supervisor, now: Fixture.now) }
    }

    @Test("An issue from another project cannot be assigned")
    func otherProject() async throws {
        let (repo, _, issue) = try await seeded()
        let outsider = ActingUser(userID: Fixture.otherSupervisor, displayName: "Out", role: .supervisor, projectID: Fixture.projectB)
        await #expect(throws: IssueRepositoryError.notFound) { try await repo.assign(issueID: issue.id, to: Fixture.worker, actor: outsider, now: Fixture.now) }
    }

    @Test("Every role may assign, because some assigning right is held by each", arguments: Role.allCases)
    func everyRole(_ role: Role) async throws {
        let (repo, store, issue) = try await seeded()
        let actor = ActingUser(userID: Fixture.otherSupervisor, displayName: "Any", role: role, projectID: Fixture.projectA)
        try await repo.assign(issueID: issue.id, to: Fixture.worker, actor: actor, now: Fixture.now)
        #expect(try await store.record(Issue.self, id: issue.id)?.assigneeID == Fixture.worker)
    }
}
