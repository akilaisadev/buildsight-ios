import Testing
import Foundation
@testable import BuildSightKit

final class FakeAuth: AuthProvider, @unchecked Sendable {
    var signInResult: Result<AuthSession, AuthError>
    var refreshResult: Result<AuthSession, AuthError> = .failure(.sessionExpired)
    var profile: UserProfile
    var profileError: AuthError?
    private(set) var signOutCalls = 0
    private(set) var resetEmails: [String] = []

    init(profile: UserProfile, signIn: Result<AuthSession, AuthError>) {
        self.profile = profile
        self.signInResult = signIn
    }
    func signIn(email: String, password: String) async throws -> AuthSession { try signInResult.get() }
    func refresh(_ session: AuthSession) async throws -> AuthSession { try refreshResult.get() }
    func signOut(_ session: AuthSession) async throws { signOutCalls += 1 }
    func sendPasswordReset(email: String) async throws { resetEmails.append(email) }
    func fetchProfile(for session: AuthSession) async throws -> UserProfile {
        if let profileError { throw profileError }
        return profile
    }
}

final class MemorySessionStore: SecureSessionStore, @unchecked Sendable {
    var session: AuthSession?
    func load() -> AuthSession? { session }
    func save(_ session: AuthSession) throws { self.session = session }
    func clear() { session = nil }
}

final class FakeBiometrics: BiometricAuthenticating, @unchecked Sendable {
    var available: BiometricAvailability = .available(.faceID)
    var result: BiometricResult = .success
    private(set) var prompts = 0
    func availability() -> BiometricAvailability { available }
    func authenticate(reason: String) async -> BiometricResult { prompts += 1; return result }
}

@MainActor
@Suite("Session, biometrics and account handling")
struct SessionManagerTests {
    let user = UserProfile(id: Fixture.supervisor, displayName: "Sam", email: "sam@site.test", organisationName: "BuildWorks", memberships: [ProjectMembership(projectID: Fixture.projectA, role: .supervisor)])
    func validSession(for id: UUID = Fixture.supervisor, expiresIn: TimeInterval = 3600) -> AuthSession {
        AuthSession(accessToken: "a", refreshToken: "r", expiresAt: Fixture.now.addingTimeInterval(expiresIn), userID: id)
    }
    func makeManager(auth: FakeAuth, store: MemorySessionStore = MemorySessionStore(), bio: FakeBiometrics = FakeBiometrics()) -> SessionManager {
        let defaults = UserDefaults(suiteName: "bs.session.\(UUID().uuidString)")!
        return SessionManager(auth: auth, sessions: store, biometrics: bio, defaults: defaults, clock: { Fixture.now })
    }

    @Test("Sign-in stores the session, loads the server profile and activates the app")
    func signIn() async throws {
        let store = MemorySessionStore()
        let m = makeManager(auth: FakeAuth(profile: user, signIn: .success(validSession())), store: store)
        let profile = try await m.signIn(email: " sam@site.test ", password: "pw")
        #expect(profile == user)
        #expect(m.state == .active(user))
        #expect(store.session != nil)
        #expect(m.profile?.role(in: Fixture.projectA) == .supervisor)
    }

    @Test("Wrong credentials leave the app signed out with nothing stored")
    func badCredentials() async {
        let store = MemorySessionStore()
        let m = makeManager(auth: FakeAuth(profile: user, signIn: .failure(.invalidCredentials)), store: store)
        await #expect(throws: AuthError.invalidCredentials) { try await m.signIn(email: "a", password: "b") }
        #expect(store.session == nil)
        #expect(m.state != .active(user))
    }

    @Test("Sign-out clears the secure session even when the network call would fail")
    func signOut() async throws {
        let store = MemorySessionStore()
        let auth = FakeAuth(profile: user, signIn: .success(validSession()))
        let m = makeManager(auth: auth, store: store)
        try await m.signIn(email: "a", password: "b")
        await m.signOut()
        #expect(m.state == .signedOut && store.session == nil && auth.signOutCalls == 1)
    }

    @Test("Sign-out with unsynced work asks for confirmation first")
    func signOutPending() {
        let m = makeManager(auth: FakeAuth(profile: user, signIn: .failure(.network)))
        #expect(m.signOutDecision(pendingOperations: 0) == .proceed)
        #expect(m.signOutDecision(pendingOperations: 3) == .needsConfirmation(pendingCount: 3))
    }

    @Test("Launch with a valid stored session and the gate on starts locked, not active")
    func launchLocked() async {
        let store = MemorySessionStore(); store.session = validSession()
        let m = makeManager(auth: FakeAuth(profile: user, signIn: .failure(.network)), store: store)
        m.biometricGateEnabled = true
        await m.restore()
        #expect(m.state == .locked(user))
    }

    @Test("Face ID unlocks a valid session; failure, cancel and lockout keep it locked with distinct outcomes")
    func biometricOutcomes() async {
        let store = MemorySessionStore(); store.session = validSession()
        let bio = FakeBiometrics()
        let m = makeManager(auth: FakeAuth(profile: user, signIn: .failure(.network)), store: store, bio: bio)
        m.biometricGateEnabled = true
        await m.restore()

        bio.result = .failed
        #expect(await m.unlockWithBiometrics() == .failed)
        bio.result = .cancelled
        #expect(await m.unlockWithBiometrics() == .cancelled)
        bio.result = .lockedOut
        #expect(await m.unlockWithBiometrics() == .mustUsePassword)
        #expect(m.state == .locked(user))
        bio.result = .success
        #expect(await m.unlockWithBiometrics() == .unlocked)
        #expect(m.state == .active(user))
    }

    @Test("Biometrics cannot revive a session the server has rejected")
    func expiredSessionNeedsPassword() async {
        let store = MemorySessionStore(); store.session = validSession(expiresIn: -100)
        let auth = FakeAuth(profile: user, signIn: .failure(.network))
        auth.refreshResult = .failure(.sessionExpired)
        let m = makeManager(auth: auth, store: store)
        m.biometricGateEnabled = true
        await m.restore()
        #expect(m.state == .signedOut)
        #expect(store.session == nil)
    }

    @Test("A session that expires mid-use moves to expired and re-authentication needs the password of the same account")
    func midSessionExpiry() async throws {
        let auth = FakeAuth(profile: user, signIn: .success(validSession()))
        let m = makeManager(auth: auth)
        try await m.signIn(email: "a", password: "b")
        m.sessionDidExpire()
        #expect(m.state == .expired(user))

        auth.signInResult = .success(validSession(for: UUID()))          // someone else's credentials
        await #expect(throws: AuthError.self) { try await m.reauthenticate(password: "other") }
        #expect(m.state == .signedOut)
    }

    @Test("Re-authenticating as the same user resumes the session")
    func reauthenticateSameUser() async throws {
        let auth = FakeAuth(profile: user, signIn: .success(validSession()))
        let m = makeManager(auth: auth)
        try await m.signIn(email: "a", password: "b")
        m.sessionDidExpire()
        try await m.reauthenticate(password: "b")
        #expect(m.state == .active(user))
    }

    @Test("Offline launch trusts the stored session and the cached profile instead of signing the user out")
    func offlineLaunch() async throws {
        let store = MemorySessionStore()
        let auth = FakeAuth(profile: user, signIn: .success(validSession()))
        let first = makeManager(auth: auth, store: store)
        try await first.signIn(email: "a", password: "b")

        // Same defaults suite is private per manager, so rebuild with the cache in place.
        let defaults = UserDefaults(suiteName: "bs.offline.\(UUID().uuidString)")!
        let cacheWriter = SessionManager(auth: auth, sessions: store, biometrics: FakeBiometrics(), defaults: defaults, clock: { Fixture.now })
        try await cacheWriter.signIn(email: "a", password: "b")
        auth.profileError = .network
        let relaunched = SessionManager(auth: auth, sessions: store, biometrics: FakeBiometrics(), defaults: defaults, clock: { Fixture.now })
        await relaunched.restore()
        #expect(relaunched.state == .active(user))
    }

    @Test("The gate re-engages only after the grace period in the background")
    func lockAfterBackground() async throws {
        nonisolated(unsafe) var now = Fixture.now
        let auth = FakeAuth(profile: user, signIn: .success(validSession(expiresIn: 99999)))
        let defaults = UserDefaults(suiteName: "bs.grace.\(UUID().uuidString)")!
        let m = SessionManager(auth: auth, sessions: MemorySessionStore(), biometrics: FakeBiometrics(), defaults: defaults, clock: { now })
        try await m.signIn(email: "a", password: "b")
        m.biometricGateEnabled = true
        m.lockGraceSeconds = 30

        m.appDidEnterBackground(); now += 10; m.appWillEnterForeground()
        #expect(m.state == .active(user))
        m.appDidEnterBackground(); now += 45; m.appWillEnterForeground()
        #expect(m.state == .locked(user))
    }

    @Test("Enabling the gate needs one successful check; sensitive actions re-prompt only when the gate is on")
    func gateEnableAndSensitive() async throws {
        let bio = FakeBiometrics()
        let m = makeManager(auth: FakeAuth(profile: user, signIn: .success(validSession())), bio: bio)
        try await m.signIn(email: "a", password: "b")

        #expect(await m.confirmSensitiveAction(reason: "Close issue"))     // gate off: no prompt
        #expect(bio.prompts == 0)

        bio.result = .failed
        #expect(await m.enableBiometricGate() == .failed)
        #expect(!m.biometricGateEnabled)
        bio.result = .success
        #expect(await m.enableBiometricGate() == .success)
        #expect(m.biometricGateEnabled)

        bio.result = .failed
        #expect(!(await m.confirmSensitiveAction(reason: "Close issue")))
    }

    @Test("Password reset is sent through the auth provider with a trimmed address")
    func passwordReset() async throws {
        let auth = FakeAuth(profile: user, signIn: .failure(.network))
        let m = makeManager(auth: auth)
        try await m.sendPasswordReset(email: "  sam@site.test ")
        #expect(auth.resetEmails == ["sam@site.test"])
    }
}
