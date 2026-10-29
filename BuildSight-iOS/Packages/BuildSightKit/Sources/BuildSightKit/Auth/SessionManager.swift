import Foundation
import Observation

public enum SessionState: Equatable, Sendable {
    case restoring
    case signedOut
    /// A valid session exists but the app is gated behind Face ID / Touch ID.
    case locked(UserProfile)
    case active(UserProfile)
    /// Backend says the session is dead. Local data stays readable by this
    /// user (offline-first) but nothing syncs until they sign in again.
    case expired(UserProfile)
}

public enum SignOutDecision: Equatable, Sendable {
    case proceed
    /// Unsynced work exists. The UI must ask: wait for sync, keep it on the
    /// device for the next sign-in of this same account, or discard it.
    case needsConfirmation(pendingCount: Int)
}

public enum BiometricGateOutcome: Equatable, Sendable {
    case unlocked
    case cancelled
    case failed
    /// Biometrics are locked by the system; only the account password can proceed.
    case mustUsePassword
    case notAvailable
}

/// Owns "who is signed in and may they see the app right now".
///
/// Biometrics only gate access to an ALREADY authenticated backend session.
/// They never mint or replace one: if the session has expired, Face ID alone
/// cannot get the user back in, which is exactly the proposal's requirement.
@MainActor
@Observable
public final class SessionManager {
    public private(set) var state: SessionState = .restoring
    public private(set) var session: AuthSession?
    public var biometricGateEnabled: Bool {
        didSet { defaults.set(biometricGateEnabled, forKey: Keys.gate) }
    }
    /// Seconds in the background before the gate re-engages.
    public var lockGraceSeconds: TimeInterval = 30

    private let auth: AuthProvider
    private let sessions: SecureSessionStore
    private let biometrics: BiometricAuthenticating
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    private var backgroundedAt: Date?

    private enum Keys {
        static let gate = "session.biometricGate"
        static let lastUser = "session.lastUserID"
    }

    public init(auth: AuthProvider, sessions: SecureSessionStore, biometrics: BiometricAuthenticating, defaults: UserDefaults = .standard, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.auth = auth
        self.sessions = sessions
        self.biometrics = biometrics
        self.defaults = defaults
        self.clock = clock
        self.biometricGateEnabled = defaults.bool(forKey: Keys.gate)
    }

    public var profile: UserProfile? {
        switch state {
        case .locked(let p), .active(let p), .expired(let p): p
        default: nil
        }
    }

    /// The account whose local database should be open, if any. Account switches
    /// are detected by comparing against the previous sign-in.
    public var lastSignedInUserID: UUID? { defaults.string(forKey: Keys.lastUser).flatMap(UUID.init(uuidString:)) }

    // MARK: - Launch

    public func restore() async {
        guard let stored = sessions.load() else { state = .signedOut; return }
        do {
            let current = stored.isExpired(at: clock()) ? try await auth.refresh(stored) : stored
            if current != stored { try? sessions.save(current) }
            session = current
            let profile = try await auth.fetchProfile(for: current)
            state = biometricGateEnabled && biometrics.availability() != .notAvailable ? .locked(profile) : .active(profile)
        } catch AuthError.sessionExpired, AuthError.accountDisabled {
            // Without a profile we cannot show anything; the cached profile
            // would come from local storage, which the app layer supplies.
            sessions.clear()
            session = nil
            state = .signedOut
        } catch {
            // Offline launch: trust the stored session; the server re-checks on every call.
            session = stored
            if let cached = cachedProfile(for: stored.userID) {
                state = biometricGateEnabled ? .locked(cached) : .active(cached)
            } else {
                state = .signedOut
            }
        }
    }

    // MARK: - Sign in / out

    @discardableResult
    public func signIn(email: String, password: String) async throws -> UserProfile {
        let newSession = try await auth.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
        let profile = try await auth.fetchProfile(for: newSession)
        try sessions.save(newSession)
        cache(profile)
        defaults.set(newSession.userID.uuidString, forKey: Keys.lastUser)
        session = newSession
        state = .active(profile)
        return profile
    }

    public func sendPasswordReset(email: String) async throws {
        try await auth.sendPasswordReset(email: email.trimmingCharacters(in: .whitespaces))
    }

    /// Call before `signOut` with the number of unsynced operations.
    public func signOutDecision(pendingOperations: Int) -> SignOutDecision {
        pendingOperations > 0 ? .needsConfirmation(pendingCount: pendingOperations) : .proceed
    }

    /// Local data is intentionally left in place: it belongs to this account's
    /// own database file and is only readable after signing in as that account.
    public func signOut() async {
        if let session { try? await auth.signOut(session) }   // best effort; local sign-out must not depend on the network
        sessions.clear()
        session = nil
        state = .signedOut
    }

    /// Called when a backend call returns 401 and refresh fails.
    public func sessionDidExpire() {
        if let profile { state = .expired(profile) }
    }

    /// Re-establishes an expired session with the password (biometrics cannot).
    public func reauthenticate(password: String) async throws {
        guard let profile else { return }
        let newSession = try await auth.signIn(email: profile.email, password: password)
        guard newSession.userID == profile.id else {
            // A different account answered: treat as account change, not a refresh.
            await signOut()
            throw AuthError.other("That password belongs to a different account.")
        }
        try sessions.save(newSession)
        session = newSession
        state = .active(profile)
    }

    // MARK: - Biometric gate

    public func unlockWithBiometrics() async -> BiometricGateOutcome {
        guard case .locked(let profile) = state else { return .unlocked }
        switch await biometrics.authenticate(reason: "Unlock BuildSight") {
        case .success:
            state = .active(profile)
            return .unlocked
        case .cancelled: return .cancelled
        case .failed: return .failed
        case .lockedOut: return .mustUsePassword
        case .unavailable: return .notAvailable
        }
    }

    /// Fresh biometric check before sensitive actions such as closing an issue.
    /// Returns true when the action may proceed.
    public func confirmSensitiveAction(reason: String) async -> Bool {
        guard biometricGateEnabled, biometrics.availability() != .notAvailable else { return true }
        return await biometrics.authenticate(reason: reason) == .success
    }

    /// Turning the gate on requires one successful check, so a user cannot lock
    /// themselves behind a method that does not work on this device.
    public func enableBiometricGate() async -> BiometricResult {
        let result = await biometrics.authenticate(reason: "Turn on Face ID for BuildSight")
        if result == .success { biometricGateEnabled = true }
        return result
    }

    public func disableBiometricGate() { biometricGateEnabled = false }

    public func appDidEnterBackground() { backgroundedAt = clock() }

    public func appWillEnterForeground() {
        defer { backgroundedAt = nil }
        guard biometricGateEnabled, case .active(let profile) = state, let left = backgroundedAt else { return }
        if clock().timeIntervalSince(left) >= lockGraceSeconds { state = .locked(profile) }
    }

    // MARK: - Profile cache (so an offline launch can still show the user)

    private func cache(_ profile: UserProfile) {
        if let data = try? RecordCodec.makeEncoder().encode(profile) { defaults.set(data, forKey: "session.profile.\(profile.id.uuidString)") }
    }

    private func cachedProfile(for id: UUID) -> UserProfile? {
        defaults.data(forKey: "session.profile.\(id.uuidString)").flatMap { try? RecordCodec.makeDecoder().decode(UserProfile.self, from: $0) }
    }
}
