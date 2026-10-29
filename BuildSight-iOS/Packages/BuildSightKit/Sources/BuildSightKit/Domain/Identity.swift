import Foundation

/// Role is held per project: the same person can be a supervisor on one site
/// and a plain engineer on another, so permissions are never stored globally.
public enum Role: String, Codable, CaseIterable, Sendable {
    case siteWorker
    case engineer
    case supervisor
    case inspector
    case projectManager

    public var displayName: String {
        switch self {
        case .siteWorker: "Site Worker"
        case .engineer: "Engineer"
        case .supervisor: "Supervisor"
        case .inspector: "Inspector"
        case .projectManager: "Project Manager"
        }
    }
}

public struct ProjectMembership: Codable, Hashable, Sendable {
    public var projectID: UUID
    public var role: Role

    public init(projectID: UUID, role: Role) {
        self.projectID = projectID
        self.role = role
    }
}

public struct UserProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String
    public var email: String
    public var organisationName: String
    public var memberships: [ProjectMembership]

    public init(id: UUID, displayName: String, email: String, organisationName: String, memberships: [ProjectMembership]) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.organisationName = organisationName
        self.memberships = memberships
    }

    public func role(in projectID: UUID) -> Role? {
        memberships.first { $0.projectID == projectID }?.role
    }

    public var projectIDs: [UUID] { memberships.map(\.projectID) }
}

/// Something the app lets a user do. Server-side policies are the real gate;
/// this table exists so the UI hides actions the server would reject anyway.
public enum Capability: Sendable {
    case reportIssue
    case progressIssue          // start / resolve
    case verifyIssue
    case closeIssue
    case reopenIssue
    case reviewHelmetFlag
    case createTask
    case runInspection
    case raiseEmergencyStop
    case clearEmergencyStop
}

public extension Role {
    func can(_ capability: Capability) -> Bool {
        switch capability {
        case .reportIssue:
            return true
        case .progressIssue:
            return self != .inspector
        case .verifyIssue:
            return [.supervisor, .inspector, .projectManager].contains(self)
        case .closeIssue, .reopenIssue, .clearEmergencyStop:
            return [.supervisor, .projectManager].contains(self)
        case .reviewHelmetFlag:
            return [.supervisor, .inspector, .projectManager].contains(self)
        case .createTask:
            return self != .siteWorker
        case .runInspection:
            return [.inspector, .supervisor, .engineer].contains(self)
        case .raiseEmergencyStop:
            // Anyone on site may call a stop; only supervisors can clear it.
            return true
        }
    }
}
