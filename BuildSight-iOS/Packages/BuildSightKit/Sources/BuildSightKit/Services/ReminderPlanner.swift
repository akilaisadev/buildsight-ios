import Foundation

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var issueAssignments = true
    public var taskReminders = true
    public var inspectionReminders = true
    public var helmetFlags = true
    /// Minutes before a due time that a reminder fires.
    public var reminderLeadMinutes = 30

    public init() {}
}

public struct ReminderRequest: Equatable, Sendable {
    public var identifier: String
    public var title: String
    public var body: String
    public var fireDate: Date
    public var deepLink: DeepLink
}

/// Decides which LOCAL reminders should exist. Scheduling them with
/// UserNotifications is the app layer's job; keeping the decision pure makes it
/// testable and makes it easy to re-plan from scratch after any change.
///
/// These are device-local reminders. They are not remote push notifications,
/// which need an APNs-backed server and are documented separately.
public enum ReminderPlanner {
    /// iOS keeps at most 64 pending local notifications per app.
    public static let maxPending = 50

    public static func plan(tasks: [TaskItem], inspections: [Inspection], assignedTo userID: UUID, preferences: NotificationPreferences, now: Date) -> [ReminderRequest] {
        var out: [ReminderRequest] = []
        let lead = TimeInterval(preferences.reminderLeadMinutes * 60)

        if preferences.taskReminders {
            for t in tasks where t.status != .completed && t.assigneeID == userID {
                let fire = max(t.dueDate.addingTimeInterval(-lead), now.addingTimeInterval(5))
                guard t.dueDate > now else { continue }   // overdue items are surfaced in-app, not re-notified
                out.append(ReminderRequest(identifier: "task-\(t.id.uuidString)", title: "Task due soon", body: t.title, fireDate: fire, deepLink: .task(projectID: t.projectID, taskID: t.id)))
            }
        }
        if preferences.inspectionReminders {
            for i in inspections where i.completedAt == nil && i.inspectorID == userID {
                guard let due = i.dueDate, due > now else { continue }
                let fire = max(due.addingTimeInterval(-lead), now.addingTimeInterval(5))
                out.append(ReminderRequest(identifier: "inspection-\(i.id.uuidString)", title: "Inspection due", body: i.templateName, fireDate: fire, deepLink: .inspection(projectID: i.projectID, inspectionID: i.id)))
            }
        }
        return Array(out.sorted { $0.fireDate < $1.fireDate }.prefix(maxPending))
    }
}
