import SwiftUI
import BuildSightKit

/// Every screen the app can push. One Hashable type so deep links, dashboard
/// tiles and timeline rows all navigate through the same mechanism.
enum Route: Hashable {
    case issue(UUID)
    case task(UUID)
    case inspection(UUID)
    case photo(UUID)
    case issueList(IssueFilter)
    case taskList(TaskBucket)
    case inspections
    case notifications
    case syncCenter
    case settings
}

enum AppTab: String, CaseIterable, Identifiable {
    case home, activity, site, tasks
    var id: String { rawValue }
    var title: String { switch self { case .home: "Home"; case .activity: "Activity"; case .site: "Site"; case .tasks: "Tasks" } }
    var symbol: String { switch self { case .home: "house.fill"; case .activity: "clock.arrow.circlepath"; case .site: "map.fill"; case .tasks: "checklist" } }
}

/// iPad sidebar adds destinations that live behind buttons on iPhone.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard, activity, map, issues, helmetFlags, tasks, inspections, notifications, sync, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: "Dashboard"; case .activity: "Activity"; case .map: "Site Map"; case .issues: "Issues"
        case .helmetFlags: "Helmet Flags"; case .tasks: "Tasks"; case .inspections: "Inspections"
        case .notifications: "Notifications"; case .sync: "Sync Center"; case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2.fill"; case .activity: "clock.arrow.circlepath"; case .map: "map.fill"
        case .issues: "exclamationmark.bubble.fill"; case .helmetFlags: "person.crop.badge.exclamationmark"
        case .tasks: "checklist"; case .inspections: "checkmark.seal.fill"; case .notifications: "bell.fill"
        case .sync: "arrow.triangle.2.circlepath"; case .settings: "gearshape.fill"
        }
    }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .home
    @Published var sidebar: SidebarItem? = .dashboard
    @Published var paths: [AppTab: [Route]] = [:]
    @Published var detailPath: [Route] = []
    @Published var showCapture = false
    @Published var pendingDeepLink: DeepLink?

    func push(_ route: Route, in tab: AppTab) { paths[tab, default: []].append(route) }

    /// Navigates for a deep link on the current layout. Links for another
    /// project are ignored: the app only ever shows the selected project.
    func open(_ link: DeepLink, activeProject: UUID?, isRegular: Bool) {
        guard link.projectID == activeProject else { return }
        switch link {
        case .issue(_, let id): go(.issue(id), tab: .home, sidebar: .issues, isRegular: isRegular)
        case .task(_, let id): go(.task(id), tab: .tasks, sidebar: .tasks, isRegular: isRegular)
        case .inspection(_, let id): go(.inspection(id), tab: .home, sidebar: .inspections, isRegular: isRegular)
        case .map: tab = .site; sidebar = .map
        case .helmetFlags(_, let unreviewed): go(.issueList(IssueFilter(openOnly: false, machineGeneratedOnly: true, unreviewedOnly: unreviewed)), tab: .home, sidebar: .helmetFlags, isRegular: isRegular)
        }
    }

    private func go(_ route: Route, tab: AppTab, sidebar: SidebarItem, isRegular: Bool) {
        if isRegular { self.sidebar = sidebar; detailPath = [route] }
        else { self.tab = tab; paths[tab] = [route] }
    }
}
