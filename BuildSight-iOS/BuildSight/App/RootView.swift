import SwiftUI
import BuildSightKit

/// Gatekeeper: nothing is reachable before authentication, and the biometric
/// lock covers the app whenever the session is `.locked`.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var launchFinished = false

    var body: some View {
        ZStack {
        Group {
            switch environment.session.state {
            case .restoring:
                Color.clear
            case .signedOut:
                SignInView()
            case .locked(let profile):
                LockView(profile: profile)
            case .active, .expired:
                if let workspace = environment.workspace { WorkspaceRoot(workspace: workspace) }
                else if let error = environment.launchError { EmptyStateView(symbol: "externaldrive.badge.xmark", title: "Storage problem", message: error) }
                else { ProgressView().task { environment.rebuildWorkspace() } }
            }
        }
        if !launchFinished || environment.session.state == .restoring {
            LaunchBuildingView().transition(.opacity).zIndex(1)
        }
        }
        .animation(.default, value: environment.session.state)
        .onChange(of: environment.session.state) { _, _ in environment.rebuildWorkspace() }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.1 : 2.8)) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { launchFinished = true }
            }
        }
    }
}

/// Wraps the signed-in experience: project gate, expired-session banner, deep links.
struct WorkspaceRoot: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("geofence.enabled") private var geofenceOn = true

    var body: some View {
        Group {
            if workspace.selection.activeProjectID == nil {
                ProjectPickerView(workspace: workspace, selection: workspace.selection)
            } else if let actor = workspace.selection.actor {
                MainShell(workspace: workspace, actor: actor)
                    .id(actor.projectID)      // switching project rebuilds every screen's state
            }
        }
        .safeAreaInset(edge: .top) {
            if case .expired = environment.session.state { ExpiredSessionBanner() }
        }
        // Re-plan site regions whenever the project list or the setting changes.
        .task(id: "\(workspace.selection.projects.map(\.id))-\(geofenceOn)") {
            workspace.geofence.update(GeofencePlanner.regions(for: workspace.selection.projects), enabled: geofenceOn)
        }
        .onChange(of: router.pendingDeepLink) { _, link in
            guard let link else { return }
            router.open(link, activeProject: workspace.selection.activeProjectID, isRegular: sizeClass == .regular)
            router.pendingDeepLink = nil
        }
    }
}

struct ExpiredSessionBanner: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var password = ""
    @State private var error: String?
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Label("Session expired. Your records are safe on this device. Tap to sign in and resume syncing.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold)).multilineTextAlignment(.leading)
                .foregroundStyle(Theme.status("critical").fg).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.status("critical").bg)
        }
        .sheet(isPresented: $showing) {
            NavigationStack {
                Form {
                    Section("Confirm your password") { SecureField("Password", text: $password).textContentType(.password) }
                    if let error { Section { ErrorBanner(message: error) } }
                }
                .navigationTitle("Sign in again").inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showing = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sign In") {
                            Task {
                                do { try await environment.session.reauthenticate(password: password); showing = false; password = "" }
                                catch let e as AuthError { error = e.userMessage }
                                catch { self.error = error.localizedDescription }
                            }
                        }.disabled(password.isEmpty)
                    }
                }
            }
        }
    }
}
