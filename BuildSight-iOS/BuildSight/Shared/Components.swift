import SwiftUI
import BuildSightKit

/// Status is always text + an SF Symbol, never colour alone.
struct StatusChip: View {
    let label: String
    var symbol: String?
    var tone: String = "low"

    var body: some View {
        let c = Theme.status(tone)
        Label {
            Text(label)
        } icon: {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
        }
        .font(.footnote.weight(.semibold))
        .labelStyle(.titleAndIcon)
        .foregroundStyle(c.fg)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(c.bg, in: Capsule())
    }
}

extension Priority {
    var tone: String { switch self { case .critical: "critical"; case .high: "high"; case .medium: "medium"; case .low: "low" } }
    var symbol: String { switch self { case .critical: "exclamationmark.octagon.fill"; case .high: "exclamationmark.triangle.fill"; case .medium: "minus.circle.fill"; case .low: "arrow.down.circle.fill" } }
}

extension IssueStatus {
    var tone: String { switch self { case .open: "high"; case .inProgress: "info"; case .resolved, .verified: "success"; case .closed: "low" } }
    var symbol: String { switch self { case .open: "circle"; case .inProgress: "clock.fill"; case .resolved: "checkmark.circle"; case .verified: "checkmark.seal.fill"; case .closed: "lock.fill" } }
}

struct PriorityChip: View {
    let priority: Priority
    var body: some View { StatusChip(label: priority.displayName, symbol: priority.symbol, tone: priority.tone) }
}

struct IssueStatusChip: View {
    let status: IssueStatus
    var body: some View { StatusChip(label: status.displayName, symbol: status.symbol, tone: status.tone) }
}

struct ReviewChip: View {
    let review: HumanReviewStatus
    var body: some View {
        switch review {
        case .awaitingReview: StatusChip(label: "Machine flag · awaiting review", symbol: "eye.trianglebadge.exclamationmark", tone: "high")
        case .confirmed: StatusChip(label: "Confirmed by reviewer", symbol: "checkmark.shield.fill", tone: "success")
        case .corrected: StatusChip(label: "Corrected by reviewer", symbol: "pencil.circle.fill", tone: "info")
        case .dismissed: StatusChip(label: "Dismissed by reviewer", symbol: "xmark.circle.fill", tone: "low")
        case .notRequired: EmptyView()
        }
    }
}

struct SyncBadge: View {
    let state: SyncState?
    var body: some View {
        switch state {
        case .synced?: Label("Synced", systemImage: "checkmark.icloud").foregroundStyle(Theme.status("success").fg)
        case .uploading?: Label("Uploading", systemImage: "arrow.triangle.2.circlepath.icloud").foregroundStyle(Theme.status("info").fg)
        case .failed?: Label("Retry pending", systemImage: "exclamationmark.icloud").foregroundStyle(Theme.status("critical").fg)
        case .pending?, nil: Label("Waiting to sync", systemImage: "icloud.and.arrow.up").foregroundStyle(Theme.secondaryText)
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.bordered) }
        }
        .padding(.vertical, 24)
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(Theme.status("critical").fg)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.status("critical").bg, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Section title that VoiceOver can jump between.
struct SectionHeader: View {
    let title: String
    var body: some View { Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader) }
}

func formatted(_ date: Date, style: Date.FormatStyle = .dateTime.day().month(.abbreviated).hour().minute()) -> String { date.formatted(style) }

/// Loading placeholder: grey shapes in the shape of a record list, so the screen
/// has its layout while data loads instead of a bare spinner.
struct SkeletonList: View {
    var rows = 3
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 4).frame(width: 150, height: 14)
                        RoundedRectangle(cornerRadius: 4).frame(width: 220, height: 18)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            }
        }
        .foregroundStyle(Theme.secondaryText.opacity(0.25))
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

/// On regular-width screens (iPad) centre content in a readable column instead of
/// stretching it edge to edge: about 760 pt wide with extra side margin, so long lines
/// of text stay comfortable and cards don't run to the screen edges. Phones and
/// compact widths (Split View, Slide Over) are untouched.
struct ReadableColumn: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    static let maxWidth: CGFloat = 760

    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content
                .frame(maxWidth: Self.maxWidth)
                .frame(maxWidth: .infinity)
                .background(Theme.background)
        } else {
            content
        }
    }
}

extension View {
    func readableColumn() -> some View { modifier(ReadableColumn()) }
}
