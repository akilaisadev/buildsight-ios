import SwiftUI
import BuildSightKit

struct HomeView: View {
    @EnvironmentObject private var context: ScreenContext
    @EnvironmentObject private var router: AppRouter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model = DashboardViewModel()
    @State private var showProjects = false
    @State private var showReportChoice = false
    @State private var showReportForm = false

    var body: some View {
        ScrollView {
            if let snapshot = context.data.snapshot {
                VStack(alignment: .leading, spacing: 20) {
                    heroHeader(snapshot)
                    if !model.stopWorkAreaNames.isEmpty { stopWorkBanner }
                    statsRow
                    actionCards
                    nextUpCard(snapshot)
                    flagCard
                    areasSection(snapshot)
                    recent(snapshot)
                }
                .padding(.horizontal, 16).padding(.top, 8)   // bottom space comes from the shared bar clearance
            } else if let error = context.data.loadError {
                ErrorBanner(message: error).padding()
            } else {
                ProgressView().padding(40)
            }
        }
        .background(Theme.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            Button { showProjects = true } label: { Label("Switch Project", systemImage: "arrow.left.arrow.right") }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { open(.notifications) } label: {
                    Image(systemName: "bell").overlay(alignment: .topTrailing) {
                        if let s = context.data.snapshot, s.notifications.contains(where: { !$0.isRead }) { Circle().fill(Theme.accent).frame(width: 10, height: 10) }
                    }
                }
                .accessibilityLabel(unreadLabel)
            }
            ToolbarItem(placement: .topBarTrailing) { Button { open(.settings) } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings") }
        }
        .onChange(of: context.data.snapshot?.issues.count) { _, _ in refresh() }
        .task(id: context.data.snapshot?.notifications.count) { refresh() }
        .onChange(of: context.data.snapshot == nil) { _, _ in refresh() }
        .sheet(isPresented: $showProjects) { ProjectSwitcher() }
        .sheet(isPresented: $showReportForm) { ReportIssueView() }
        .confirmationDialog("Report an issue", isPresented: $showReportChoice, titleVisibility: .visible) {
            Button("Take a Photo") { router.showCapture = true }
            Button("Report Without Photo") { showReportForm = true }
            Button("Cancel", role: .cancel) {}
        } message: { Text("A photo is the best evidence. Use the form when the camera can't be used.") }
    }

    private var unreadLabel: String {
        let n = context.data.snapshot?.notifications.filter { !$0.isRead }.count ?? 0
        return n == 0 ? "Notifications" : "Notifications, \(n) unread"
    }

    private func refresh() { if let s = context.data.snapshot { model.update(from: s) } }
    private func open(_ route: Route) {
        if sizeClass == .regular { router.detailPath.append(route) } else { router.push(route, in: .home) }
    }

    /// Figma header: status tag, large project name, location in orange.
    private func heroHeader(_ s: ProjectSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(s.project.status.rawValue.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.accent, in: Capsule())
                Text("\(context.actor.role.displayName.uppercased())").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            }
            Text(s.project.name).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
            Label(s.project.locationName, systemImage: "mappin.and.ellipse").font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.accentText)
        }
        .padding(.top, 4)
    }

    /// Figma stats row: the first number in orange, labels in small caps.
    private var statsRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(model.tiles.prefix(3).enumerated()), id: \.offset) { index, tile in
                Button { navigate(tile.destination) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(tile.value)").font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(index == 0 ? Theme.accentText : Theme.text)
                        Text(tile.title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    /// Figma action cards: a large white "Report Issue" card, with two outlined buttons beside it.
    private var actionCards: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { showReportChoice = true } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: "exclamationmark.circle").font(.title2).foregroundStyle(Theme.accentText)
                    Spacer(minLength: 28)
                    Text("Report Issue").font(.title2.weight(.bold)).foregroundStyle(.black)
                }
                .padding(18).frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(spacing: 12) {
                outlinedAction("Inspection", "doc.text.magnifyingglass") { open(.inspections) }
                outlinedAction("Daily Report", "doc.plaintext") { router.tab = .activity }
            }
        }
        .padding(.vertical, 6)
    }

    private func outlinedAction(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: Glove.target + 8, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// The worker's next step: the task due soonest in this project. Tapping opens the task list.
    @ViewBuilder private func nextUpCard(_ s: ProjectSnapshot) -> some View {
        if let next = s.tasks.min(by: { $0.dueDate < $1.dueDate }) {
            Button { open(.taskList(.today)) } label: {
                HStack(spacing: 14) {
                    Image(systemName: "checklist").font(.title2).foregroundStyle(Theme.onAccent)
                        .frame(width: 56, height: 56)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NEXT UP").font(.caption2.weight(.bold)).foregroundStyle(Theme.accentText)
                        Text(next.title).font(.headline).foregroundStyle(Theme.text).lineLimit(2)
                        Text("Due \(formatted(next.dueDate, style: .dateTime.day().month(.abbreviated)))")
                            .font(.subheadline).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.body.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens your task list")
        }
    }

    private var stopWorkBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Stop-work notice active", systemImage: "hand.raised.fill").font(.headline)
            Text(model.stopWorkAreaNames.joined(separator: ", ")).font(.subheadline)
            Text("This is a digital notice in BuildSight. It does not stop any equipment.").font(.footnote)
        }
        .foregroundStyle(Theme.status("critical").fg).padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.status("critical").bg, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .accessibilityElement(children: .combine)
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            ForEach(model.tiles) { tile in
                Button { navigate(tile.destination) } label: {
                    Card {
                        VStack(alignment: .leading, spacing: 4) {
                            Image(systemName: symbol(for: tile.destination)).font(.title3.weight(.semibold)).foregroundStyle(Theme.accentText).accessibilityHidden(true)
                            Text("\(tile.value)").font(.system(.largeTitle, design: .rounded).bold())
                            Text(tile.title).font(.subheadline.weight(.semibold))
                            Text(tile.caption).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Shows the matching records")
            }
        }
    }

    private func symbol(for d: DashboardTile.Destination) -> String {
        switch d {
        case .issues: "exclamationmark.bubble.fill"
        case .tasks: "checklist"
        case .inspections: "checkmark.seal.fill"
        case .timelineToday: "clock.arrow.circlepath"
        case .helmetFlags: "person.crop.badge.exclamationmark"
        case .map: "map.fill"
        }
    }

    private func navigate(_ d: DashboardTile.Destination) {
        switch d {
        case .issues(let f): open(.issueList(f))
        case .tasks(let b): open(.taskList(b))
        case .inspections: open(.inspections)
        case .timelineToday:
            router.tab = .activity; router.sidebar = .activity
        case .helmetFlags(let unreviewed): open(.issueList(IssueFilter(machineGeneratedOnly: true, unreviewedOnly: unreviewed)))
        case .map: router.tab = .site; router.sidebar = .map
        }
    }

    /// What the numbers mean is printed next to them; there is no safety score.
    private var flagCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Helmet detection")
                if let h = model.summary?.helmet {
                    Text("\(h.unreviewed) awaiting review · \(h.confirmed) confirmed · \(h.dismissed) dismissed").font(.subheadline)
                }
                Text("Flags are suggestions from an on-device detector. Only a reviewer's confirmation makes one a finding. No flags does not mean the site is safe: workers outside the photo are never assessed.")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func areasSection(_ s: ProjectSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Site areas")
            ForEach(s.areas) { area in
                let open = s.issues.filter { $0.areaID == area.id && $0.status.isOpenWork && $0.review != .dismissed }.count
                Button { self.open(.issueList(IssueFilter(areaID: area.id, openOnly: true))) } label: {
                    Card {
                        HStack { Text(area.displayName).font(.body.weight(.semibold)); Spacer(); Text("\(open) open").foregroundStyle(Theme.secondaryText); Image(systemName: "chevron.right").foregroundStyle(Theme.secondaryText).accessibilityHidden(true) }
                            .frame(minHeight: 28)
                    }
                }
                .buttonStyle(.plain)
            }
            if s.areas.isEmpty { Text("No areas have been synced for this project yet.").font(.subheadline).foregroundStyle(Theme.secondaryText) }
        }
    }

    private func recent(_ s: ProjectSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Today's Log")
                Spacer()
                Button("VIEW ALL") { router.tab = .activity }.font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            }
            if model.recentActivity.isEmpty { Text("Nothing recorded yet. Capture a photo to start the timeline.").foregroundStyle(Theme.secondaryText) }
            ForEach(model.recentActivity) { event in
                Card { TimelineRow(event: event, snapshot: s) }
            }
        }
    }
}

struct ProjectSwitcher: View {
    @EnvironmentObject private var context: ScreenContext
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(context.workspace.selection.projects) { p in
                Button {
                    context.workspace.selection.select(p.id); dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) { Text(p.name).font(.headline); Text(p.locationName).font(.subheadline).foregroundStyle(Theme.secondaryText) }
                        Spacer()
                        if p.id == context.actor.projectID { Image(systemName: "checkmark").accessibilityLabel("Current project") }
                    }.frame(minHeight: 44)
                }
            }
            .navigationTitle("Projects").inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
