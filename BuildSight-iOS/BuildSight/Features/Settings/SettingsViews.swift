import SwiftUI
import AVFoundation
import UserNotifications
import BuildSightKit

struct NotificationsView: View {
    @EnvironmentObject private var context: ScreenContext
    @EnvironmentObject private var router: AppRouter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: NotificationsViewModel?

    var body: some View {
        Group {
            if let s = context.data.snapshot, let model {
                @Bindable var model = model
                List {
                    GloveChoice(options: [GloveOption(label: "All", value: false), GloveOption(label: "Unread", symbol: "circle.fill", value: true)], selection: $model.showUnreadOnly)
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    let items = model.items(in: s)
                    if items.isEmpty { EmptyStateView(symbol: "bell.slash", title: "You're up to date", message: "Assignments, flags and reminders for this project appear here.").listRowBackground(Color.clear) }
                    ForEach(items) { n in
                        Button {
                            Task { await model.open(n) }
                            if let link = n.deepLink { router.open(link, activeProject: context.actor.projectID, isRegular: sizeClass == .regular) }
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: n.isRead ? "circle" : "circle.fill").font(.caption2).foregroundStyle(Theme.accentText).padding(.top, 6).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(n.title).font(.headline); Text(n.body).font(.subheadline).foregroundStyle(Theme.secondaryText)
                                    Text(n.createdAt, style: .relative).font(.caption).foregroundStyle(Theme.secondaryText)
                                }
                            }.frame(minHeight: 44).accessibilityElement(children: .combine).accessibilityValue(n.isRead ? "Read" : "Unread")
                        }
                    }
                }
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Mark All Read") { Task { await model.markAllRead(projectID: context.actor.projectID) } } } }
            } else { ProgressView() }
        }
        .navigationTitle("Notifications")
        .task { if model == nil { model = NotificationsViewModel(repository: NotificationRepository(store: context.store)) } }
    }
}

struct SyncCenterView: View {
    @EnvironmentObject private var context: ScreenContext
    @State private var model: SyncCenterViewModel?

    var body: some View {
        List {
            if let model {
                Section {
                    HStack { Label(context.sync.isOnline ? "Online" : "Offline", systemImage: context.sync.isOnline ? "wifi" : "wifi.slash"); Spacer()
                        if let at = context.sync.lastSyncedAt { Text("Last sync \(at, style: .relative) ago").font(.caption).foregroundStyle(Theme.secondaryText) } }
                    Text("\(model.summary.pending) waiting · \(model.summary.uploading) uploading · \(model.summary.failed) need a retry").font(.subheadline)
                    Button { Task { await model.syncNow() } } label: { if model.isSyncing { ProgressView() } else { Text("Sync Now") } }.buttonStyle(PrimaryButtonStyle())
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                } footer: { Text("Records are saved on this device first. A record only shows Synced after the server confirmed it.") }
                if model.rows.isEmpty { Section { EmptyStateView(symbol: "checkmark.icloud", title: "Everything is synced", message: "No changes are waiting to upload.") } }
                Section("Queue") {
                    ForEach(model.rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title).font(.headline)
                            Text("\(row.recordType.rawValue) · \(Self.phaseText(row.phase))").font(.subheadline).foregroundStyle(Theme.secondaryText)
                        }
                        .accessibilityElement(children: .combine)
                        .swipeActions {
                            if case .failed = row.phase { Button("Retry") { Task { await model.retry(row.id) } }.tint(Theme.accentText) }
                            Button("Stop Syncing", role: .destructive) { Task { await model.discard(row.id) } }
                        }
                    }
                }
            }
        }
        .navigationTitle("Sync Center")
        .task { if model == nil { model = SyncCenterViewModel(store: context.store, engine: context.sync.engine) }; await model?.observe() }
    }

    static func phaseText(_ p: SyncRow.Phase) -> String {
        switch p {
        case .waiting: "Waiting"
        case .uploading: "Uploading"
        case .retrying(let at): "Will retry \(at.formatted(.relative(presentation: .named)))"
        case .failed(let m): "Rejected: \(m)"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var context: ScreenContext
    @EnvironmentObject private var environment: AppEnvironment
    @State private var prefs = Preferences.notificationPreferences
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var biometricMessage: String?
    @State private var confirmSignOut: SignOutDecision?
    @State private var showSyncCenter = false
    @AppStorage(AppearanceSetting.key) private var appearanceRaw = "system"
    @AppStorage("geofence.enabled") private var geofenceOn = true

    private var session: SessionManager { environment.session }

    var body: some View {
        Form {
            Section {
                GloveChoice(options: [
                    GloveOption(label: "System", symbol: "circle.lefthalf.filled", value: "system"),
                    GloveOption(label: "Light", symbol: "sun.max.fill", value: "light"),
                    GloveOption(label: "Dark", symbol: "moon.fill", value: "dark"),
                ], selection: $appearanceRaw)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            } header: { Text("Appearance") } footer: {
                Text("System switches to Dark automatically at night.")
            }
            Section("Profile") {
                let p = context.workspace.profile
                LabeledContent("Name", value: p.displayName); LabeledContent("Email", value: p.email)
                LabeledContent("Organisation", value: p.organisationName)
                LabeledContent("Role here", value: context.actor.role.displayName)
                LabeledContent("Projects", value: "\(p.memberships.count)")
            }
            Section {
                Toggle("Require Face ID / Touch ID", isOn: Binding(get: { session.biometricGateEnabled }, set: { on in Task { await setGate(on) } }))
                if let biometricMessage { Text(biometricMessage).font(.footnote).foregroundStyle(Theme.status("critical").fg) }
            } header: { Text("Security") } footer: { Text("Biometrics lock the app on this device. They don't replace signing in: the server still checks your account and project role on every request.") }

            Section("Permissions") {
                permission("Camera", status: cameraText)
                permission("Location", status: locationText)
                permission("Notifications", status: notificationText)
                Button("Open iOS Settings") { openSettings() }
            }
            Section {
                Toggle("Issue assignments", isOn: $prefs.issueAssignments)
                Toggle("Task due reminders", isOn: $prefs.taskReminders)
                Toggle("Inspection reminders", isOn: $prefs.inspectionReminders)
                Toggle("Helmet flags", isOn: $prefs.helmetFlags)
                Stepper("Remind \(prefs.reminderLeadMinutes) min before", value: $prefs.reminderLeadMinutes, in: 5...120, step: 5)
                if notificationStatus == .notDetermined { Button("Allow Reminders") { Task { _ = await context.workspace.notifications.requestAuthorisation(); await refresh() } } }
            } header: { Text("Notifications") } footer: { Text("Reminders are scheduled on this device and work offline. Remote push notifications from the server are not part of this build.") }

            Section {
                Toggle("Site arrival alerts", isOn: $geofenceOn).frame(minHeight: Glove.target)
            } header: { Text("Location") } footer: {
                Text("Alerts when you arrive at or leave a site. Needs location access set to Always.")
            }
            Section("Site") {
                NavigationLink { AreaQRCodesView() } label: { Label("Area QR codes", systemImage: "qrcode") }
                    .frame(minHeight: Glove.target)
            }
            Section("Data") {
                NavigationLink("Sync Center", value: Route.syncCenter)
                if let d = context.workspace.analyzerDescriptor { LabeledContent("Helmet model", value: "\(d.identifier) \(d.version)") }
                else { Text("No helmet model is installed in this build. Photos are still saved; analysis is unavailable.").font(.footnote).foregroundStyle(Theme.secondaryText) }
            }
            Section { Button("Sign Out", role: .destructive) { Task { await requestSignOut() } } }
        }
        .navigationTitle("Settings")
        .onChange(of: prefs) { _, new in Preferences.notificationPreferences = new; Task { await context.sync.refreshDerivedState() } }
        .task { await refresh() }
        .confirmationDialog("Sign out with unsynced work?", isPresented: Binding(get: { confirmSignOut != nil }, set: { if !$0 { confirmSignOut = nil } }), titleVisibility: .visible) {
            Button("Sync First") { Task { await context.sync.syncNow(); await requestSignOut() } }
            Button("Sign Out and Keep Changes on This Device", role: .destructive) { Task { await finishSignOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if case .needsConfirmation(let n)? = confirmSignOut { Text("\(n) change(s) haven't reached the server. Kept changes stay on this device and sync the next time this same account signs in.") }
        }
    }

    private func setGate(_ on: Bool) async {
        biometricMessage = nil
        if on {
            switch await session.enableBiometricGate() {
            case .success: break
            case .cancelled: break
            case .failed: biometricMessage = "Not recognised, so Face ID stays off."
            case .lockedOut: biometricMessage = "Biometrics are locked on this device."
            case .unavailable(.notEnrolled): biometricMessage = "No Face ID or Touch ID is set up on this device."
            case .unavailable: biometricMessage = "Biometrics aren't available on this device."
            }
        } else { session.disableBiometricGate() }
    }

    private func requestSignOut() async {
        let pending = (try? await context.store.pendingOperations().count) ?? 0
        let decision = session.signOutDecision(pendingOperations: pending)
        if decision == .proceed { await finishSignOut() } else { confirmSignOut = decision }
    }
    private func finishSignOut() async {
        context.workspace.notifications.clearAll()
        await session.signOut()
        environment.signedOut()
    }

    private func refresh() async {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        notificationStatus = await context.workspace.notifications.authorisationStatus()
    }

    private func permission(_ name: String, status: String) -> some View { LabeledContent(name, value: status) }
    private var cameraText: String { switch cameraStatus { case .authorized: "Allowed"; case .denied: "Off"; case .restricted: "Restricted"; default: "Not asked yet" } }
    private var locationText: String {
        switch context.workspace.location.permission { case .whenInUse, .always: "Allowed"; case .approximateOnly: "Approximate only"; case .denied: "Off"; case .restricted: "Restricted"; case .notDetermined: "Not asked yet" }
    }
    private var notificationText: String { switch notificationStatus { case .authorized, .provisional, .ephemeral: "Allowed"; case .denied: "Off"; default: "Not asked yet" } }

    private func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }
}
