import SwiftUI
import MapKit
import BuildSightKit

/// Control Tower: records with a real GPS fix as annotations. Records without
/// one are listed under the map rather than pinned at an invented position.
struct SiteMapView: View {
    @EnvironmentObject private var context: ScreenContext
    @EnvironmentObject private var router: AppRouter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var model = MapViewModel()
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedID: String?
    @State private var showMissing = false

    var body: some View {
        Group {
            if let s = context.data.snapshot {
                let projection = model.projection(for: s)
                ZStack(alignment: .bottom) {
                    Map(position: $position, selection: $selectedID) {
                        UserAnnotation()
                        ForEach(WorkingSite.all) { site in
                            Annotation(site.name, coordinate: site.coordinate, anchor: .bottom) { WorkingSitePin(site: site) }
                        }
                        ForEach(projection.items) { item in
                            let c = CLLocationCoordinate2D(latitude: item.point.latitude, longitude: item.point.longitude)
                            Annotation(item.title, coordinate: c, anchor: .bottom) {
                                MapPin(kind: item.ref.kind, approximate: item.isApproximate)
                            }.tag(item.id)
                            if item.isApproximate { MapCircle(center: c, radius: item.point.horizontalAccuracy).foregroundStyle(Theme.accent.opacity(0.12)) }
                        }
                    }
                    .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
                    .mapStyle(.standard(elevation: .realistic))
                    .ignoresSafeArea()   // the map fills the whole screen, under the header and to the bottom edge
                    .tint(.blue)         // neutral: MapKit shows the tint if tiles fail to load (the app accent is orange)

                    VStack(spacing: 8) {
                        if projection.items.isEmpty {
                            Card { Text("No GPS positions yet. Pins appear here when photos or issues are saved with a location.").font(.footnote).foregroundStyle(Theme.secondaryText) }
                        }
                        if let notice = model.permissionNotice() { ErrorBanner(message: notice) }
                        if let item = projection.items.first(where: { $0.id == selectedID }) { selectionCard(item, s) }
                        filterBar
                    }
                    // The tab bar is a safe-area inset above this, so only a small margin is needed here.
                    .padding(.leading, verticalSizeClass == .compact ? 104 : 12).padding(.trailing, 12).padding(.bottom, verticalSizeClass == .compact ? 12 : 24)   // chips sit just above the tab bar   // bar (84) + its margin (8) + a 12 pt gap, measured from the safe-area bottom
                }
                .overlay(alignment: .topTrailing) {
                    if !projection.withoutLocation.isEmpty {
                        Button { showMissing = true } label: { Label("\(projection.withoutLocation.count) without GPS", systemImage: "location.slash").font(.footnote.weight(.semibold)).padding(8).background(.regularMaterial, in: Capsule()) }
                            .padding(10)
                    }
                }
                .sheet(isPresented: $showMissing) { MissingLocationList(refs: projection.withoutLocation, snapshot: s) }
                .onAppear { frame(projection, project: s.project) }
            } else { ProgressView() }
        }
        .navigationTitle("Site")
        .toolbarBackground(.hidden, for: .navigationBar)   // transparent header over the map
        .task { model.updatePermission(context.workspace.location.permission) }
    }

    private func frame(_ projection: MapProjection, project: Project) {
        if let first = projection.items.first {
            let lats = projection.items.map(\.point.latitude), lons = projection.items.map(\.point.longitude)
            let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
            let span = MKCoordinateSpan(latitudeDelta: max(0.002, (lats.max()! - lats.min()!) * 1.6), longitudeDelta: max(0.002, (lons.max()! - lons.min()!) * 1.6))
            _ = first
            position = .region(MKCoordinateRegion(center: center, span: span))
        } else if let c = project.centre {
            position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude), span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
        } else {
            // No GPS records yet: show Sri Lanka with the working sites.
            position = .region(WorkingSite.sriLankaRegion)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(TimelineKind.allCases, id: \.self) { kind in
                    let on = model.visibleKinds.contains(kind)
                    Button { model.toggle(kind) } label: {
                        Label(kind.displayName, systemImage: TimelineRow.symbol(kind)).font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).frame(minHeight: Glove.target)
                            .background(on ? Theme.accent : Theme.surface, in: Capsule())
                            .foregroundStyle(on ? Theme.onAccent : Theme.text)
                            .overlay(Capsule().stroke(Theme.secondaryText.opacity(0.4)))
                    }
                    .accessibilityLabel("\(kind.displayName) pins")
                    .accessibilityValue(on ? "shown" : "hidden")
                }
            }
        }
    }

    private func selectionCard(_ item: MapItem, _ s: ProjectSnapshot) -> some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.ref.kind.displayName).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    Text(item.title).font(.headline)
                    Text(item.isApproximate ? "Approximate position (±\(Int(item.point.horizontalAccuracy)) m)" : "GPS position (±\(Int(item.point.horizontalAccuracy)) m)").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("Open") {
                    let route = item.ref.route
                    if sizeClass == .regular { router.detailPath.append(route) } else { router.push(route, in: .site) }
                }.buttonStyle(.borderedProminent).tint(Theme.accentText)
            }
        }
    }
}

struct MapPin: View {
    let kind: TimelineKind
    let approximate: Bool
    var body: some View {
        Image(systemName: TimelineRow.symbol(kind))
            .font(.subheadline.bold()).foregroundStyle(Theme.onAccent)
            .frame(width: 36, height: 36).background(kind == .helmetFlag ? Color(hex: 0xFF8A5B) : Theme.accent, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2)).shadow(radius: 2)
            .accessibilityLabel("\(kind.displayName)\(approximate ? ", approximate position" : "")")
    }
}

struct MissingLocationList: View {
    let refs: [RecordRef]
    let snapshot: ProjectSnapshot
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(refs, id: \.id) { ref in Label(title(ref), systemImage: TimelineRow.symbol(ref.kind)) }
                .navigationTitle("No GPS position").inlineNavigationTitle()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .overlay(alignment: .bottom) { Text("These records were saved without GPS (permission off or no signal). They still belong to their site area.").font(.footnote).padding() }
        }
    }
    private func title(_ r: RecordRef) -> String {
        switch r.kind {
        case .issue, .helmetFlag: snapshot.issue(r.id)?.title ?? "Issue"
        case .photo: snapshot.photo(r.id)?.note.nonEmpty ?? "Photo"
        case .inspection: snapshot.inspections.first { $0.id == r.id }?.templateName ?? "Inspection"
        case .task: snapshot.tasks.first { $0.id == r.id }?.title ?? "Task"
        }
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
