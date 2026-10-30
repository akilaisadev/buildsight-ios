import WidgetKit
import SwiftUI
import BuildSightKit

// MARK: - Look

private enum Palette {
    static let ink = Color(widgetHex: 0x121214)
    static let panel = Color(widgetHex: 0x26262B)
    static let orange = Color(widgetHex: 0xFF5A00)
    static let amber = Color(widgetHex: 0xFFB020)
    static let green = Color(widgetHex: 0x30D158)
    static let red = Color(widgetHex: 0xFF453A)
    static let dim = Color.white.opacity(0.62)
    static let track = Color.white.opacity(0.12)
}

private extension Color {
    init(widgetHex hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

private extension WidgetSnapshot {
    /// Ring colour: red if something critical is open, orange if flags wait for a person, else green.
    var tint: Color {
        switch status {
        case .critical: Palette.red
        case .needsReview: Palette.orange
        case .allClear: Palette.green
        }
    }
}

struct WidgetBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.panel, Palette.ink], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Palette.orange.opacity(0.38), .clear], center: .topTrailing, startRadius: 4, endRadius: 190)
        }
    }
}

// MARK: - Pieces

private struct BrandHeader: View {
    var project: String?
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "viewfinder").font(.system(size: 11, weight: .heavy)).foregroundStyle(Palette.orange)
            Text("BUILDSIGHT").font(.system(size: 10, weight: .heavy)).tracking(1.2).foregroundStyle(.white)
            if let project {
                Text("·").foregroundStyle(Palette.dim)
                Text(project).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.dim).lineLimit(1)
            }
        }
    }
}

/// Ring that fills as the review backlog grows (full at 10 or more); a check mark when empty.
private struct BacklogRing: View {
    let snapshot: WidgetSnapshot
    var lineWidth: CGFloat = 9

    var body: some View {
        ZStack {
            Circle().stroke(Palette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: snapshot.unreviewedFlags == 0 ? 1 : max(snapshot.backlogShare, 0.07))
                .stroke(AngularGradient(colors: [snapshot.tint.opacity(0.5), snapshot.tint], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if snapshot.unreviewedFlags == 0 {
                VStack(spacing: 1) {
                    Image(systemName: "checkmark").font(.system(size: 26, weight: .heavy)).foregroundStyle(Palette.green)
                    Text("ALL CLEAR").font(.system(size: 8, weight: .heavy)).tracking(0.8).foregroundStyle(Palette.dim)
                }
            } else {
                VStack(spacing: 0) {
                    Text("\(snapshot.unreviewedFlags)")
                        .font(.system(size: 36, weight: .heavy, design: .rounded)).minimumScaleFactor(0.6)
                        .foregroundStyle(.white).contentTransition(.numericText())
                    Text("TO REVIEW").font(.system(size: 8, weight: .heavy)).tracking(0.8).foregroundStyle(Palette.dim)
                }
            }
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: Int
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
                .frame(width: 24, height: 24).background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.dim)
            Spacer(minLength: 4)
            Text("\(value)").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(.white).contentTransition(.numericText())
        }
    }
}

private struct BarRow: View {
    let label: String
    let value: Int
    let maxValue: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.dim)
                Spacer()
                Text("\(value)").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule().fill(LinearGradient(colors: [color.opacity(0.6), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: value == 0 ? 0 : max(8, geo.size.width * CGFloat(value) / CGFloat(max(maxValue, 1))))
                }
            }
            .frame(height: 8)
        }
    }
}

private struct Freshness: View {
    let date: Date
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8, weight: .bold))
            Text("Updated \(date, style: .relative) ago").lineLimit(1)
        }
        .font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.dim.opacity(0.8))
    }
}

// MARK: - Layouts

struct SmallLayout: View {
    let s: WidgetSnapshot
    var body: some View {
        VStack(spacing: 6) {
            BrandHeader().frame(maxWidth: .infinity, alignment: .leading)
            BacklogRing(snapshot: s, lineWidth: 8).padding(.horizontal, 6)
            Text(s.projectName).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.dim).lineLimit(1)
        }
    }
}

struct MediumLayout: View {
    let s: WidgetSnapshot
    var body: some View {
        HStack(spacing: 16) {
            BacklogRing(snapshot: s, lineWidth: 10).frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 8) {
                BrandHeader(project: s.projectName)
                StatRow(label: "Confirmed", value: s.confirmedFindings, symbol: "checkmark.shield.fill", color: Palette.green)
                StatRow(label: "Flagged today", value: s.flagsToday, symbol: "bolt.fill", color: Palette.amber)
                StatRow(label: "Critical open", value: s.openCritical, symbol: "exclamationmark.triangle.fill", color: s.openCritical > 0 ? Palette.red : Palette.dim)
                Freshness(date: s.generatedAt)
            }
        }
    }
}

struct LargeLayout: View {
    let s: WidgetSnapshot
    var body: some View {
        let top = max(s.unreviewedFlags, s.confirmedFindings, s.flagsToday, s.openCritical, 1)
        VStack(alignment: .leading, spacing: 14) {
            BrandHeader(project: s.projectName)
            HStack(spacing: 16) {
                BacklogRing(snapshot: s, lineWidth: 12).frame(width: 128, height: 128)
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.openCritical > 0 ? "Needs attention" : s.unreviewedFlags > 0 ? "Flags waiting" : "Nothing waiting")
                        .font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    Text(s.openCritical > 0 ? "\(s.openCritical) critical issue\(s.openCritical == 1 ? "" : "s") still open."
                         : s.unreviewedFlags > 0 ? "A person needs to confirm or dismiss them."
                         : "Every helmet flag has been reviewed.")
                        .font(.system(size: 12)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 11) {
                BarRow(label: "To review", value: s.unreviewedFlags, maxValue: top, color: Palette.orange)
                BarRow(label: "Confirmed findings", value: s.confirmedFindings, maxValue: top, color: Palette.green)
                BarRow(label: "Flagged today", value: s.flagsToday, maxValue: top, color: Palette.amber)
                BarRow(label: "Critical open", value: s.openCritical, maxValue: top, color: Palette.red)
            }
            Spacer(minLength: 0)
            HStack {
                if let area = s.topAreaName {
                    Label("Most flags: \(area)", systemImage: "mappin.and.ellipse")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                }
                Spacer(minLength: 8)
                Freshness(date: s.generatedAt)
            }
        }
    }
}

// MARK: - Lock Screen

private struct CircularLayout: View {
    let s: WidgetSnapshot
    var body: some View {
        #if os(iOS)
        Gauge(value: s.unreviewedFlags == 0 ? 1 : s.backlogShare) {
            Image(systemName: "viewfinder")
        } currentValueLabel: {
            Text("\(s.unreviewedFlags)")
        }
        .gaugeStyle(.accessoryCircular)
        #else
        Text("\(s.unreviewedFlags)")
        #endif
    }
}

struct RectangularLayout: View {
    let s: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("BuildSight", systemImage: "viewfinder").font(.caption.weight(.heavy))
            Text(s.unreviewedFlags == 0 ? "All flags reviewed" : "\(s.unreviewedFlags) flag\(s.unreviewedFlags == 1 ? "" : "s") to review")
                .font(.headline)
            Text("\(s.openCritical) critical · \(s.flagsToday) today").font(.caption)
        }
    }
}

// MARK: - Entry point

struct FlagEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct FlagWidgetView: View {
    let entry: FlagEntry
    @Environment(\.widgetFamily) private var family

    private var isLockScreen: Bool {
        family == .accessoryCircular || family == .accessoryRectangular || family == .accessoryInline
    }

    var body: some View {
        Group {
            if let s = entry.snapshot { content(s) } else { empty }
        }
        .containerBackground(for: .widget) {
            if isLockScreen { Color.clear } else { WidgetBackdrop() }
        }
    }

    @ViewBuilder private func content(_ s: WidgetSnapshot) -> some View {
        Group {
            switch family {
            case .systemSmall: SmallLayout(s: s)
            case .systemMedium: MediumLayout(s: s)
            case .systemLarge, .systemExtraLarge: LargeLayout(s: s)
            case .accessoryCircular: CircularLayout(s: s)
            case .accessoryRectangular: RectangularLayout(s: s)
            case .accessoryInline: Text(s.unreviewedFlags == 0 ? "BuildSight: all clear" : "BuildSight: \(s.unreviewedFlags) to review")
            default: SmallLayout(s: s)
            }
        }
        .widgetURL(DeepLink.helmetFlags(projectID: s.projectID, unreviewedOnly: true).url)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("BuildSight, \(s.projectName). \(s.unreviewedFlags) helmet flags to review, \(s.confirmedFindings) confirmed, \(s.flagsToday) flagged today, \(s.openCritical) critical open.")
    }

    @ViewBuilder private var empty: some View {
        if isLockScreen {
            Label("Open BuildSight", systemImage: "viewfinder")
        } else {
            VStack(spacing: 8) {
                Image(systemName: "viewfinder").font(.system(size: 28, weight: .heavy)).foregroundStyle(Palette.orange)
                Text("Open BuildSight to load your project")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white).multilineTextAlignment(.center)
            }
        }
    }
}
