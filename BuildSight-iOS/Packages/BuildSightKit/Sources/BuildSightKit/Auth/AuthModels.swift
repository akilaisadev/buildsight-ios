import Foundation

public struct AuthSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var userID: UUID

    public init(accessToken: String, refreshToken: String, expiresAt: Date, userID: UUID) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userID = userID
    }

    public func isExpired(at now: Date, leeway: TimeInterval = 30) -> Bool {
        expiresAt.addingTimeInterval(-leeway) <= now
    }
}

public enum AuthError: Error, Equatable, Sendable {
    case invalidCredentials
    case emailNotConfirmed
    case accountDisabled
    /// The refresh token was rejected: the user must sign in again.
    case sessionExpired
    case network
    case other(String)

    public var userMessage: String {
        switch self {
        case .invalidCredentials: "Email or password is incorrect."
        case .emailNotConfirmed: "Confirm your email address first, then sign in."
        case .accountDisabled: "This account has been disabled. Contact your project administrator."
        case .sessionExpired: "Your session has expired. Please sign in again."
        case .network: "No connection. Check your network and try again."
        case .other(let m): m
        }
    }
}

/// The identity backend. Production talks to the REST auth endpoints; tests
/// use a scripted fake.
public protocol AuthProvider: Sendable {
    func signIn(email: String, password: String) async throws -> AuthSession
    func refresh(_ session: AuthSession) async throws -> AuthSession
    func signOut(_ session: AuthSession) async throws
    func sendPasswordReset(email: String) async throws
    /// Profile, organisation and per-project roles as the SERVER defines them.
    func fetchProfile(for session: AuthSession) async throws -> UserProfile
}

/// Keychain in production; in-memory in tests.
public protocol SecureSessionStore: Sendable {
    func load() -> AuthSession?
    func save(_ session: AuthSession) throws
    func clear()
}

public enum BiometricKind: Sendable, Equatable { case faceID, touchID, opticID, none }

public enum BiometricAvailability: Equatable, Sendable {
    case available(BiometricKind)
    case notEnrolled
    case notAvailable
    case lockedOut
}

public enum BiometricResult: Equatable, Sendable {
    case success
    case cancelled          // user tapped Cancel or the system cancelled
    case failed             // face/finger not recognised
    case lockedOut          // too many failures; system requires the passcode
    case unavailable(BiometricAvailability)
}

public protocol BiometricAuthenticating: Sendable {
    func availability() -> BiometricAvailability
    func authenticate(reason: String) async -> BiometricResult
}
