import Foundation
import SwiftUI
import os
import WidgetKit
import BuildSightKit

/// Backend settings come from Info.plist (filled from an .xcconfig that is not
/// committed). If they are missing the app says so, instead of pretending.
enum BackendSettings {
    static var config: BackendConfig? {
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: "BuildSightBackendURL") as? String,
              let key = Bundle.main.object(forInfoDictionaryKey: "BuildSightAnonKey") as? String,
              let url = URL(string: urlString), url.scheme == "https", !key.isEmpty, !key.hasPrefix("$(") else { return nil }
        return BackendConfig(baseURL: url, anonKey: key)
    }
}

/// Everything that exists only while one account is signed in. Built on sign-in
/// and thrown away on sign-out, which is what keeps accounts isolated: each
/// account gets its own database file and its own evidence folder.
@MainActor
final class Workspace: ObservableObject {
    let profile: UserProfile
    let store: CoreDataLocalStore
    let files: EvidenceFileStore
    let selection: ProjectSelection
    let location: LocationService
    let helmet: HelmetWorkflow
    let analyzerDescriptor: HelmetModelDescriptor?
    /// Set when a model is bundled but could not be loaded, so the app never reports a broken
    /// model as "no model installed".
    let analyzerProblem: String?
    let sync: SyncCoordinator
    let notifications = NotificationScheduler()
    /// Arrival/departure alerts for sites with a location in the project data.
    lazy var geofence = GeofenceService { [notifications] id, title, body in
        await notifications.alert(id: id, title: title, body: body, deepLink: nil)
    }
    let repository: ProjectRepository
    let sessionGate: ReauthenticationGate

    init(profile: UserProfile, config: BackendConfig, tokens: AuthTokenSource, session: SessionManager) throws {
        self.profile = profile
        sessionGate = session
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let account = support.appendingPathComponent("Accounts/\(profile.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        store = try CoreDataLocalStore(storeURL: account.appendingPathComponent("BuildSight.sqlite"))
        files = try EvidenceFileStore(directory: account.appendingPathComponent("Evidence", isDirectory: true))
        repository = ProjectRepository(store: store)
        selection = ProjectSelection(profile: profile, repository: repository)
        location = LocationService()

        // The detector is optional at build time: if no model is bundled the
        // workflow records a failed analysis and capture still works.
        let loaded = Self.loadAnalyzer()
        let analyzer = loaded.analyzer
        analyzerDescriptor = analyzer?.descriptor
        analyzerProblem = loaded.problem
        let evidence = files
        helmet = HelmetWorkflow(analyzer: analyzer, store: store) { evidence.url(forFilename: $0.localFilename) }

        let backend = SupabaseBackend(config: config, tokens: tokens, files: files)
        let engine = SyncEngine(store: store, backend: backend)
        let snapshots = UserDefaultsWidgetSnapshotStore(suiteName: AppGroup.identifier)
        let publisher = WidgetSnapshotPublisher(repository: repository, snapshots: snapshots) { WidgetCenter.shared.reloadAllTimelines() }
        let selection = self.selection
        sync = SyncCoordinator(engine: engine, pull: PullService(store: store, remote: backend), store: store, widget: publisher, reminders: notifications, actorProvider: { selection.actor }, projectIDs: { profile.projectIDs }, onPulled: { await selection.load() }, onAuthExpired: { session.sessionDidExpire() })
    }

    private static func loadAnalyzer() -> (analyzer: CoreMLHelmetAnalyzer?, problem: String?) {
        // Prefer the newest multi-class PPE model, then the older one, then the helmet-only model.
        var problem: String?
        let candidates: [(String, HelmetModelDescriptor)] = [("PPEDetectorV2", .ppeSafetyVisionV2), ("PPEDetector", .ppeYOLOv8s), ("HelmetDetector", .candidateKeremberkeYOLOv8n)]
        for (name, descriptor) in candidates {
            guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else { continue }
            do {
                return (try CoreMLHelmetAnalyzer(modelURL: url, descriptor: descriptor), problem)
            } catch {
                problem = "\(name) is bundled but could not be loaded: \(error.localizedDescription)"
                Logger(subsystem: "com.buildsight.app", category: "model").error("\(problem ?? "", privacy: .public)")
            }
        }
        return (nil, problem)
    }
}

/// The app group shared with the widget. It follows the bundle id (group.<bundle id>, set in
/// Info.plist from BUILDSIGHT_BUNDLE_ID) so each developer team registers its own group; a
/// fixed name can only belong to one team in the world.
enum AppGroup {
    static let identifier = Bundle.main.object(forInfoDictionaryKey: "BuildSightAppGroup") as? String ?? "group.com.buildsight99.app"
}

@MainActor
final class AppEnvironment: ObservableObject {
    let session: SessionManager
    let config: BackendConfig?
    let tokens: AuthTokenSource?
    @Published private(set) var workspace: Workspace?
    @Published var launchError: String?
    let biometricLogin = BiometricLoginStore()
    /// Set right after a password sign-in, so the signed-in screen can ask "Use Face ID next time?".
    @Published var biometricOffer: BiometricLoginOffer?

    init() {
        let config = BackendSettings.config
        self.config = config
        let sessions = KeychainSessionStore()
        let auth: AuthProvider = config.map { SupabaseAuthProvider(config: $0) } ?? UnconfiguredAuth()
        tokens = config.map { _ in AuthTokenSource(store: sessions, auth: auth) }
        session = SessionManager(auth: auth, sessions: sessions, biometrics: BiometricService())
    }

    func start() async {
        await session.restore()
        rebuildWorkspace()
    }

    /// Opens (or closes) the per-account workspace to match the session.
    func rebuildWorkspace() {
        guard let profile = session.profile, let config, let tokens else { workspace = nil; return }
        if workspace?.profile.id == profile.id { return }
        do {
            let w = try Workspace(profile: profile, config: config, tokens: tokens, session: session)
            workspace = w
            Task { await w.selection.load(); await w.sync.syncNow() }
        } catch { launchError = "Couldn't open local storage: \(error.localizedDescription)" }
    }

    func signedOut() { workspace = nil }

    // MARK: - Face ID / Touch ID sign-in

    /// Called after a successful password sign-in. Only offers when biometrics work and this
    /// account's login isn't already saved.
    func offerBiometricLogin(email: String, password: String) {
        guard BiometricLabel.current != nil, biometricLogin.savedEmail != email else { return }
        biometricOffer = BiometricLoginOffer(email: email, password: password)
    }

    func declineBiometricOffer() { biometricOffer = nil }

    /// Confirms Face ID / Touch ID works, then saves the login. Returns a message only when something failed.
    func acceptBiometricOffer() async -> String? {
        guard let offer = biometricOffer, let label = BiometricLabel.current else { return nil }
        biometricOffer = nil
        switch await BiometricService().authenticate(reason: "Turn on sign-in with \(label.name)") {
        case .success: break
        case .cancelled: return nil
        default: return "\(label.name) didn't confirm, so sign-in with it stays off."
        }
        do { try biometricLogin.save(email: offer.email, password: offer.password); return nil }
        catch { return "Couldn't save the \(label.name) sign-in on this device." }
    }
}

struct BiometricLoginOffer: Equatable {
    let email: String
    let password: String
}

private struct UnconfiguredAuth: AuthProvider {
    func signIn(email: String, password: String) async throws -> AuthSession { throw AuthError.other("The backend is not configured in this build.") }
    func refresh(_ session: AuthSession) async throws -> AuthSession { throw AuthError.sessionExpired }
    func signOut(_ session: AuthSession) async throws {}
    func sendPasswordReset(email: String) async throws { throw AuthError.other("The backend is not configured in this build.") }
    func fetchProfile(for session: AuthSession) async throws -> UserProfile { throw AuthError.sessionExpired }
}
