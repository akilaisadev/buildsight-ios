import SwiftUI
import BuildSightKit

struct SignInView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showReset = false
    @FocusState private var focus: Field?
    private enum Field { case email, password }

    @Environment(\.horizontalSizeClass) private var sizeClass
    private var wide: Bool { sizeClass == .regular }

    var body: some View {
        Group {
            if wide {
                // Tablet: brand panel on the left, a larger form on the right.
                HStack(spacing: 0) {
                    hero(cornerRadius: 0).frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView {
                        form.frame(maxWidth: 560).padding(.horizontal, 48).padding(.vertical, 56)
                            .frame(maxWidth: .infinity)
                            .containerRelativeFrame(.vertical, alignment: .center)   // centred, still scrolls with the keyboard up
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ScrollView {
                    VStack(spacing: 28) {
                        hero(cornerRadius: 24).frame(height: 260)
                        form
                    }
                    .padding(.horizontal, 24).padding(.bottom, 32).frame(maxWidth: 440)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .sheet(isPresented: $showReset) { PasswordResetView(initialEmail: email) }
    }

    private func hero(cornerRadius: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            // The photo sits in an overlay so its own size never decides the panel's width.
            Color(white: 0.12).overlay {
                AsyncImage(url: URL(string: "https://images.unsplash.com/photo-1602757115429-b4190ae087be?w=1600&q=80")) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
            }
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.25)], startPoint: .bottom, endPoint: .top)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    BrandMark().frame(width: wide ? 52 : 36, height: wide ? 52 : 36)
                    Text("BuildSight").font(.system(size: wide ? 44 : 28, weight: .bold)).foregroundStyle(.white)
                }
                Text("Capture the site. Know the story.").font((wide ? Font.title3 : Font.body).weight(.semibold)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(wide ? 40 : 20)
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Welcome back").font(wide ? .system(size: 44, weight: .bold) : .largeTitle.bold()).padding(.top, wide ? 0 : -4)

            if environment.config == nil {
                ErrorBanner(message: "This build has no backend configured. Set BuildSightBackendURL and BuildSightAnonKey (see docs/BACKEND_SETUP.md).")
            }

            // One grouped block with a hairline between the rows, the way system sign-in forms look.
            VStack(spacing: 0) {
                TextField("Email", text: $email).emailField().focused($focus, equals: .email)
                    .padding(.horizontal, 16).frame(minHeight: fieldHeight).submitLabel(.next)
                    .onSubmit { focus = .password }
                Divider().padding(.leading, 16)
                SecureField("Password", text: $password).textContentType(.password).focused($focus, equals: .password)
                    .padding(.horizontal, 16).frame(minHeight: fieldHeight).submitLabel(.go)
                    .onSubmit(signIn)
            }
            .font(wide ? .title3 : .body)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))

            if let error { ErrorBanner(message: error) }

            VStack(spacing: 8) {
                Button(action: signIn) { if busy { ProgressView() } else { Text("Sign In") } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy || email.isEmpty || password.isEmpty || environment.config == nil)
                Button("Forgot password?") { showReset = true }
                    .font(.body.weight(.semibold)).foregroundStyle(Theme.accentText).frame(minHeight: Glove.target)
            }
        }
    }

    private var fieldHeight: CGFloat { wide ? 68 : 52 }

    private func signIn() {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { _ = try await environment.session.signIn(email: email, password: password); password = "" }
            catch let e as AuthError { error = e.userMessage }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct PasswordResetView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State var initialEmail: String
    @State private var sent = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $initialEmail).emailField()
                } footer: { Text("If an account exists for this address, a reset link will be sent. The link is emailed by the BuildSight backend.") }
                if sent { Section { Label("Check your inbox for the reset link.", systemImage: "envelope.badge.fill") } }
                if let error { Section { ErrorBanner(message: error) } }
            }
            .navigationTitle("Reset Password").inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do { try await environment.session.sendPasswordReset(email: initialEmail); sent = true; error = nil }
                            catch let e as AuthError { error = e.userMessage }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(initialEmail.isEmpty || busy)
                }
            }
        }
    }
}

/// Shown while a valid session is behind Face ID / Touch ID.
struct LockView: View {
    let profile: UserProfile
    @EnvironmentObject private var environment: AppEnvironment
    @State private var message: String?
    @State private var needsPassword = false
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill").font(.system(size: 56)).foregroundStyle(Theme.accent).accessibilityHidden(true)
            Text("BuildSight is locked").font(.title2.bold())
            Text("Signed in as \(profile.displayName)").foregroundStyle(Theme.secondaryText)
            if let message { ErrorBanner(message: message) }

            if needsPassword {
                SecureField("Account password", text: $password).textContentType(.password)
                    .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                Button("Sign In With Password") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await environment.session.reauthenticate(password: password); password = "" }
                        catch let e as AuthError { message = e.userMessage }
                        catch { message = error.localizedDescription }
                    }
                }.buttonStyle(PrimaryButtonStyle()).disabled(password.isEmpty || busy)
            } else {
                Button("Unlock") { Task { await unlock() } }.buttonStyle(PrimaryButtonStyle())
            }
            Button("Sign Out") { Task { await environment.session.signOut() } }.frame(minHeight: Glove.target)
        }
        .padding(32).frame(maxWidth: 420).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
        .task { await unlock() }
    }

    private func unlock() async {
        switch await environment.session.unlockWithBiometrics() {
        case .unlocked: message = nil
        case .cancelled: message = nil
        case .failed: message = "Not recognised. Try again."
        case .mustUsePassword: needsPassword = true; message = "Biometrics are locked. Sign in with your account password."
        case .notAvailable: needsPassword = true; message = "Biometric unlock isn't available on this device. Use your password."
        }
    }
}

struct ProjectPickerView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var sync: SyncCoordinator
    @EnvironmentObject private var environment: AppEnvironment
    var selection: ProjectSelection
    @State private var loaded = false

    init(workspace: Workspace, selection: ProjectSelection) {
        self.workspace = workspace
        self.selection = selection
        _sync = ObservedObject(wrappedValue: workspace.sync)
    }

    var body: some View {
        NavigationStack {
            List {
                if selection.projects.isEmpty && loaded {
                    EmptyStateView(symbol: "building.2", title: sync.isSyncing ? "Loading your projects…" : "No projects yet",
                                   message: sync.lastPullError ?? "You aren't a member of any project yet, or the first download hasn't finished. Use Refresh to try again.")
                }
                ForEach(selection.projects) { project in
                    Button { selection.select(project.id) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "building.2.fill").font(.title3).foregroundStyle(Theme.onAccent)
                                .frame(width: 40, height: 40).background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name).font(.headline).foregroundStyle(Theme.text)
                                Text(project.locationName).font(.subheadline).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
                        }.frame(minHeight: 52, alignment: .leading)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if sync.isSyncing { ProgressView() }
                    Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(sync.isSyncing)
                    Menu {
                        Text(workspace.profile.email)
                        Button("Sign Out", role: .destructive) { Task { await environment.session.signOut() } }
                    } label: { Label("Account", systemImage: "person.crop.circle") }
                }
            }
            .refreshable { await refresh() }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        await selection.load()
        await workspace.sync.syncNow()
        await selection.load()
        loaded = true
    }
}
