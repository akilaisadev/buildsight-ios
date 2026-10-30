import Foundation

public enum TaskBucket: String, CaseIterable, Sendable {
    case today, upcoming, overdue, done

    public var displayName: String {
        switch self {
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .overdue: "Overdue"
        case .done: "Done"
        }
    }
}

public enum TaskError: Error, Equatable, Sendable {
    case notPermitted
    case invalidTransition
}

public enum TaskScheduling {
    /// Bucket used everywhere (list, badges, dashboard, notifications):
    /// done = completed, overdue = due time passed, today = due later today, upcoming = after today.
    /// `now` and the calendar are passed in so tests are deterministic.
    public static func bucket(for task: TaskItem, now: Date, calendar: Calendar = .current) -> TaskBucket {
        if task.status == .completed { return .done }
        if task.dueDate < now { return .overdue }
        return calendar.isDate(task.dueDate, inSameDayAs: now) ? .today : .upcoming
    }

    public static func grouped(_ tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> [TaskBucket: [TaskItem]] {
        var result = Dictionary(uniqueKeysWithValues: TaskBucket.allCases.map { ($0, [TaskItem]()) })
        for task in tasks { result[bucket(for: task, now: now, calendar: calendar), default: []].append(task) }
        for key in result.keys {
            result[key]?.sort { key == .done ? ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) : $0.dueDate < $1.dueDate }
        }
        return result
    }

    public static func start(_ task: TaskItem, now: Date) -> Result<TaskItem, TaskError> {
        guard task.status == .notStarted else { return .failure(.invalidTransition) }
        var t = task; t.status = .inProgress; t.updatedAt = now
        return .success(t)
    }

    public static func complete(_ task: TaskItem, now: Date) -> Result<TaskItem, TaskError> {
        guard task.status != .completed else { return .failure(.invalidTransition) }
        var t = task; t.status = .completed; t.completedAt = now; t.updatedAt = now
        return .success(t)
    }

    /// Reopening returns a completed task to In Progress and clears its
    /// completion time, so "Done" never shows a stale completion date.
    public static func reopen(_ task: TaskItem, now: Date) -> Result<TaskItem, TaskError> {
        guard task.status == .completed else { return .failure(.invalidTransition) }
        var t = task; t.status = .inProgress; t.completedAt = nil; t.updatedAt = now
        return .success(t)
    }
}
