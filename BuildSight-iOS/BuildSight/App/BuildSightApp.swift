import SwiftUI
import BuildSightKit

@main
struct BuildSightApp: App {
    @StateObject private var environment = AppEnvironment()
    @StateObject private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearanceSetting.key) private var appearanceRaw = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .phonePreviewIfRequested()
                .environmentObject(environment)
                .environmentObject(router)
                // Light, Dark or System (day/night), chosen in Settings. Both palettes are contrast-tested.
                .preferredColorScheme(AppearanceSetting.colorScheme(appearanceRaw))
                // Follows the system Light/Dark setting. Both palettes are in
                // DesignTokens and contrast-tested. See docs/DESIGN_DECISIONS.md.
                .tint(Theme.accentText)
                .task { await environment.start() }
                .onOpenURL { url in
                    if let link = DeepLink(url: url) { router.pendingDeepLink = link }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background: environment.session.appDidEnterBackground()
                    case .active:
                        environment.session.appWillEnterForeground()
                        if let w = environment.workspace { Task { await w.sync.syncNow() } }
                    default: break
                    }
                }
        }
    }
}
