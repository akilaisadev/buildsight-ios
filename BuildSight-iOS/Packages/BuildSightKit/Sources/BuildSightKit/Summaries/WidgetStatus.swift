import Foundation

/// What the widget's ring and wording should say, decided from the snapshot's counts.
public enum WidgetStatus: Equatable, Sendable {
    case critical(Int)
    case needsReview(Int)
    case allClear
}

extension WidgetSnapshot {
    /// Critical issues come first, then flags waiting for a person, otherwise all clear.
    public var status: WidgetStatus {
        if openCritical > 0 { return .critical(openCritical) }
        if unreviewedFlags > 0 { return .needsReview(unreviewedFlags) }
        return .allClear
    }

    /// How full the backlog ring is: one tenth per unreviewed flag, full at ten or more.
    public var backlogShare: Double { min(max(Double(unreviewedFlags), 0) / 10, 1) }
}
