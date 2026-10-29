import Foundation
import UserNotifications
import BuildSightKit

/// Local reminders (task and inspection due times) via UserNotifications.
///
/// Three different things share the word "notification" in BuildSight:
///  1. In-app notifications: records in the Notifications tab (always works).
///  2. Local reminders: scheduled here from `ReminderPlanner`, work offline.
///  3. Remote push (APNs): needs an Apple Developer account and a server that
///     sends pushes. NOT implemented in this build; see docs/KNOWN_LIMITATIONS.md.
@MainActor
final class NotificationScheduler {
    private let center = UNUserNotificationCenter.current()

    func authorisationStatus() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }

    func requestAuthorisation() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Replaces all reminders with the planned set, so edits, completions and
    /// preference changes can never leave stale reminders behind.
    func apply(_ plan: [ReminderRequest]) async {
        let status = await authorisationStatus()
        guard status == .authorized || status == .provisional else { return }
        center.removeAllPendingNotificationRequests()
        for r in plan {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            content.userInfo = ["deepLink": r.deepLink.url.absoluteString]
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: r.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: r.identifier, content: content, trigger: trigger))
        }
    }

    /// Shows an alert right away: used for items that arrive from the server while the app is open.
    func alert(id: String, title: String, body: String, deepLink: DeepLink?) async {
        let status = await authorisationStatus()
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let deepLink { content.userInfo = ["deepLink": deepLink.url.absoluteString] }
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }

    func clearAll() { center.removeAllPendingNotificationRequests() }
}
