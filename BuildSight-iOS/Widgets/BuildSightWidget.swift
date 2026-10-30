import WidgetKit
import SwiftUI
import BuildSightKit

struct FlagProvider: TimelineProvider {
    private let store = UserDefaultsWidgetSnapshotStore(suiteName: Bundle.main.object(forInfoDictionaryKey: "BuildSightAppGroup") as? String ?? "group.com.buildsight99.app")

    func placeholder(in context: Context) -> FlagEntry {
        FlagEntry(date: Date(), snapshot: WidgetSnapshot(projectID: UUID(), projectName: "Project", generatedAt: Date(), unreviewedFlags: 3, confirmedFindings: 12, flagsToday: 2, topAreaName: "Level 2", openCritical: 1))
    }
    func getSnapshot(in context: Context, completion: @escaping (FlagEntry) -> Void) { completion(FlagEntry(date: Date(), snapshot: store.load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FlagEntry>) -> Void) {
        let entry = FlagEntry(date: Date(), snapshot: store.load())
        // Ask for a refresh in 30 minutes; the system may defer it.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

struct BuildSightFlagWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BuildSightFlagWidget", provider: FlagProvider()) { FlagWidgetView(entry: $0) }
            .configurationDisplayName("Site Flags")
            .description("Helmet flags waiting for review, confirmed findings and critical issues. Tap to open them.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct BuildSightWidgets: WidgetBundle {
    var body: some Widget { BuildSightFlagWidget() }
}
