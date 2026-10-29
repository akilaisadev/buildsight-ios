import Foundation
import SwiftUI
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
    let sync: SyncCoordinator
    let notifications = NotificationScheduler()
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
        let analyzer = Self.loadAnalyzer()
        analyzerDescriptor = analyzer?.descriptor
        let evidence = files
        helmet = HelmetWorkflow(analyzer: analyzer, store: store) { evidence.url(forFilename: $0.localFilename) }

        let backend = SupabaseBackend(config: config, tokens: tokens, files: files)
        let engine = SyncEngine(store: store, backend: backend)
        let snapshots = UserDefaultsWidgetSnapshotStore(suiteName: AppGroup.identifier)
        let publisher = WidgetSnapshotPublisher(repository: repository, snapshots: snapshots) { WidgetCenter.shared.reloadAllTimelines() }
        let selection = self.selection
        sync = SyncCoordinator(engine: engine, pull: PullService(store: store, remote: backend), store: store, widget: publisher, reminders: notifications, actorProvider: { selection.actor }, projectIDs: { profile.projectIDs }, onPulled: { await selection.load() }, onAuthExpired: { session.sessionDidExpire() })
    }

    private static func loadAnalyzer() -> CoreMLHelmetAnalyzer? {
        // Prefer the multi-class PPE model; fall back to the helmet-only one.
        if let url = Bundle.main.url(forResource: "PPEDetector", withExtension: "mlmodelc"),
           let analyzer = try? CoreMLHelmetAnalyzer(modelURL: url, descriptor: .ppeYOLOv8s) {
            return analyzer
        }
        guard let url = Bundle.main.url(forResource: "HelmetDetector", withExtension: "mlmodelc") else { return nil }
        return try? CoreMLHelmetAnalyzer(modelURL: url, descriptor: .candidateKeremberkeYOLOv8n)
    }
}

enum AppGroup { static let identifier = "group.com.buildsight.app" }

@MainActor
final class AppEnvironment: ObservableObject {
    let session: SessionManager
    let config: BackendConfig?
    let tokens: AuthTokenSource?
    @Published private(set) var workspace: Workspace?
    @Published var launchError: String?

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
}

private struct UnconfiguredAuth: AuthProvider {
    func signIn(email: String, password: String) async throws -> AuthSession { throw AuthError.other("The backend is not configured in this build.") }
    func refresh(_ session: AuthSession) async throws -> AuthSession { throw AuthError.sessionExpired }
    func signOut(_ session: AuthSession) async throws {}
    func sendPasswordReset(email: String) async throws { throw AuthError.other("The backend is not configured in this build.") }
    func fetchProfile(for session: AuthSession) async throws -> UserProfile { throw AuthError.sessionExpired }
}
