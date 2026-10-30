import WidgetKit
import SwiftUI
import BuildSightKit

/// Home-screen helmet-flag summary for the active project.
///
/// Honest about freshness: the widget shows the snapshot the app last wrote and
/// says when that was. WidgetKit refreshes on its own budget, so this is not a
/// live view; opening the app (or any data change while the app runs) writes a
/// new snapshot and asks WidgetKit to reload.
struct FlagEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct FlagProvider: TimelineProvider {
    private let store = UserDefaultsWidgetSnapshotStore(suiteName: Bundle.main.object(forInfoDictionaryKey: "BuildSightAppGroup") as? String ?? "group.com.buildsight99.app")

    func placeholder(in context: Context) -> FlagEntry {
        FlagEntry(date: Date(), snapshot: WidgetSnapshot(projectID: UUID(), projectName: "Project", generatedAt: Date(), unreviewedFlags: 0, confirmedFindings: 0, flagsToday: 0, topAreaName: nil, openCritical: 0))
    }
    func getSnapshot(in context: Context, completion: @escaping (FlagEntry) -> Void) { completion(FlagEntry(date: Date(), snapshot: store.load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FlagEntry>) -> Void) {
        let entry = FlagEntry(date: Date(), snapshot: store.load())
        // Ask for a refresh in 30 minutes; the system may defer it.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

struct FlagWidgetView: View {
    let entry: FlagEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let s = entry.snapshot { content(s) } else {
                VStack(spacing: 6) { Image(systemName: "person.crop.badge.exclamationmark"); Text("Open BuildSight to load your project").font(.footnote).multilineTextAlignment(.center) }
            }
        }
        .containerBackground(Color(red: 0.95, green: 0.95, blue: 0.97), for: .widget)
    }

    private func content(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(s.projectName).font(.caption.weight(.semibold)).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(s.unreviewedFlags)").font(.system(size: 40, weight: .bold, design: .rounded))
                Text("helmet flags\nto review").font(.caption)
            }
            if family != .systemSmall {
                Text("\(s.confirmedFindings) confirmed findings · \(s.flagsToday) flagged today").font(.footnote)
                if let area = s.topAreaName { Text("Most flags: \(area)").font(.footnote) }
            }
            Spacer(minLength: 0)
            // Meaning and freshness, always visible.
            Text("Unreviewed = not yet judged by a person. Updated \(s.generatedAt, style: .relative) ago.").font(.caption2).foregroundStyle(Color(white: 0.23))
        }
        .foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.12))
        .widgetURL(DeepLink.helmetFlags(projectID: s.projectID, unreviewedOnly: true).url)
        .accessibilityElement(children: .combine)
    }
}

struct BuildSightFlagWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BuildSightFlagWidget", provider: FlagProvider()) { FlagWidgetView(entry: $0) }
            .configurationDisplayName("Helmet Flags")
            .description("Unreviewed helmet flags for your active project. Tap to open them.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct BuildSightWidgets: WidgetBundle {
    var body: some Widget { BuildSightFlagWidget() }
}
