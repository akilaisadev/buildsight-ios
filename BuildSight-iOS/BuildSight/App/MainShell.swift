import SwiftUI
import BuildSightKit

/// What every screen in a project needs, injected once instead of threaded
/// through every initializer.
@MainActor
final class ScreenContext: ObservableObject {
    let workspace: Workspace
    let actor: ActingUser
    let data: ProjectDataModel
    init(workspace: Workspace, actor: ActingUser) {
        self.workspace = workspace
        self.actor = actor
        self.data = ProjectDataModel(projectID: actor.projectID, repository: workspace.repository)
    }
    var store: CoreDataLocalStore { workspace.store }
    var files: EvidenceFileStore { workspace.files }
    var sync: SyncCoordinator { workspace.sync }
    var issues: IssueRepository { IssueRepository(store: store) }
}

struct MainShell: View {
    @StateObject private var context: ScreenContext
    @EnvironmentObject private var router: AppRouter
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(workspace: Workspace, actor: ActingUser) {
        _context = StateObject(wrappedValue: ScreenContext(workspace: workspace, actor: actor))
    }

    var body: some View {
        Group {
            if sizeClass == .regular { PadShell() } else { PhoneShell() }
        }
        .environmentObject(context)
        // Glove-sized rows in every list (system default is 44 pt).
        .environment(\.defaultMinListRowHeight, Glove.target)
        .task { await context.data.observe() }
        .fullScreenCover(isPresented: $router.showCapture) { CaptureFlowView().environmentObject(context) }
    }
}

// MARK: - iPhone: quick capture first

struct PhoneShell: View {
    @EnvironmentObject private var router: AppRouter
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }
    @EnvironmentObject private var context: ScreenContext

    /// Capture is an action, not a place, so it sits in the middle of the tab bar
    /// and opens the camera instead of switching screens.
    private enum PhoneTab: Hashable { case app(AppTab), capture }

    /// Space the floating bar needs at the bottom of every scrolling screen (pill height + margins).
    static let barClearance: CGFloat = Glove.barClearance
    /// Landscape: width of the left rail plus its margins.
    static let railClearance: CGFloat = 104

    var body: some View {
        TabView(selection: Binding<PhoneTab>(
            get: { .app(router.tab) },
            set: { new in
                switch new {
                case .capture: router.showCapture = true      // selection snaps back to the current tab
                case .app(let tab): router.tab = tab
                }
            })) {
            appTab(.home)
            appTab(.activity)
            Color.clear
                .tabItem { Label("Capture", systemImage: "camera.fill") }
                .tag(PhoneTab.capture)
            appTab(.site)
            appTab(.tasks)
        }
        .toolbar(.hidden, for: .tabBar)

    }

    /// Figma tab bar: a floating pill with five slots. The middle slot is the
    /// orange capture button; the selected tab shows a dark circle behind its icon.
    private var floatingBar: some View {
        HStack(spacing: 0) {
            barItem(.home, "house.fill")
            barItem(.activity, "waveform.path.ecg")
            Button { router.showCapture = true } label: {
                Image(systemName: "camera.fill").font(.title2.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 74, height: 74).background(Theme.accent, in: Circle())
                    .shadow(color: Theme.accent.opacity(0.45), radius: 10, y: 4)
            }
            .offset(y: -10)
            .accessibilityLabel("Capture photo")
            .frame(maxWidth: .infinity)
            barItem(.site, "map.fill")
            barItem(.tasks, "checklist")
        }
        .padding(.horizontal, 10)
        .frame(height: 84)
        .background(Color(light: 0x1C1C1E, dark: 0xE5E5EA), in: Capsule())   // solid: no page text shows through
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Landscape: the same five items as a vertical rail on the left edge.
    private var railBar: some View {
        VStack(spacing: 0) {
            barItem(.home, "house.fill")
            barItem(.activity, "waveform.path.ecg")
            Button { router.showCapture = true } label: {
                Image(systemName: "camera.fill").font(.title2.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 66, height: 66).background(Theme.accent, in: Circle())
                    .shadow(color: Theme.accent.opacity(0.45), radius: 10, y: 4)
            }
            .accessibilityLabel("Capture photo")
            .frame(maxHeight: .infinity)
            barItem(.site, "map.fill")
            barItem(.tasks, "checklist")
        }
        .padding(.vertical, 10)
        .frame(width: 84)
        .frame(maxHeight: .infinity)
        .background(Color(light: 0x1C1C1E, dark: 0xE5E5EA), in: Capsule())
        .padding(.leading, 10)
        .padding(.vertical, 8)
    }

    private func barItem(_ tab: AppTab, _ symbol: String) -> some View {
        let selected = router.tab == tab
        return Button { router.tab = tab } label: {
            Image(systemName: symbol).font(.title3.weight(.semibold))
                .foregroundStyle(selected ? Color(light: 0x1C1C1E, dark: 0xFFFFFF) : Color(light: 0xD1D1D6, dark: 0x3A3A3C))
                .frame(width: 64, height: 64)
                .background(selected ? Color(light: 0xFFFFFF, dark: 0x000000) : Color.clear, in: Circle())
                .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func appTab(_ tab: AppTab) -> some View {
        NavigationStack(path: Binding(get: { router.paths[tab] ?? [] }, set: { router.paths[tab] = $0 })) {
            root(for: tab)
                .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
        }
        // Solid header on every screen: scrolling content never shows through the top bar.
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // The bar floats over the content (as in the Figma). Scroll content gets bottom
        // margin so the last rows scroll up above the bar and stay reachable.
        // Applied to the whole stack, so EVERY screen in it (however it was opened: route,
        // NavigationLink, sheet-free push) leaves room for the floating bar at the bottom.
        .contentMargins(isLandscape ? .leading : .bottom, isLandscape ? Self.railClearance : Self.barClearance, for: .scrollContent)
        // A soft fade to the page colour under the bar, so text scrolling past the bottom
        // edge (and under the home indicator) never shows behind the bar.
        .overlay(alignment: isLandscape ? .leading : .bottom) {
            if isLandscape {
                railBar
            } else {
                floatingBar.background(alignment: .bottom) {
                    LinearGradient(colors: [Theme.background.opacity(0), Theme.background, Theme.background], startPoint: .top, endPoint: .bottom)
                        .frame(height: Glove.barClearance + 40)
                        .ignoresSafeArea(edges: .bottom)
                        .allowsHitTesting(false)
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .tabItem { Label(tab.title, systemImage: tab.symbol) }
        .tag(PhoneTab.app(tab))
    }

    @ViewBuilder private func root(for tab: AppTab) -> some View {
        switch tab {
        case .home: HomeView()
        case .activity: ActivityView()
        case .site: SiteMapView()
        case .tasks: TaskListView(initialBucket: .today)
        }
    }
}

// MARK: - iPad: supervision with sidebar, list and detail

struct PadShell: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var context: ScreenContext

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $router.sidebar) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationTitle(context.data.snapshot?.project.name ?? "BuildSight")
            .safeAreaInset(edge: .bottom) {
                Button { router.showCapture = true } label: { Label("Capture Photo", systemImage: "camera.fill") }
                    .buttonStyle(PrimaryButtonStyle()).padding()
            }
        } detail: {
            NavigationStack(path: $router.detailPath) {
                detail.navigationDestination(for: Route.self) { RouteDestination(route: $0) }
            }
            .id(router.sidebar)
        }
    }

    @ViewBuilder private var detail: some View {
        switch router.sidebar ?? .dashboard {
        case .dashboard: HomeView()
        case .activity: ActivityView()
        case .map: SiteMapView()
        case .issues: IssueReviewSplit(filter: IssueFilter())
        case .helmetFlags: IssueReviewSplit(filter: IssueFilter(machineGeneratedOnly: true))
        case .tasks: TaskListView(initialBucket: .today)
        case .inspections: InspectionListView()
        case .notifications: NotificationsView()
        case .sync: SyncCenterView()
        case .settings: SettingsView()
        }
    }
}

struct RouteDestination: View {
    let route: Route
    var body: some View {
        switch route {
        case .issue(let id): IssueDetailView(issueID: id)
        case .task(let id): TaskDetailView(taskID: id)
        case .inspection(let id): InspectionRunView(inspectionID: id)
        case .photo(let id): PhotoDetailView(photoID: id)
        case .issueList(let filter): IssueListView(filter: filter)
        case .taskList(let bucket): TaskListView(initialBucket: bucket)
        case .inspections: InspectionListView()
        case .notifications: NotificationsView()
        case .syncCenter: SyncCenterView()
        case .settings: SettingsView()
        }
    }
}
