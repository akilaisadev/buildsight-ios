import Foundation
import SwiftUI
import WidgetKit
import BuildSightKit

/// Decides WHEN to sync; `SyncEngine` decides HOW. Triggers: a local change
/// (requestSync), the app becoming active, and connectivity returning. After
/// each drain it pulls server changes, refreshes the widget snapshot and
/// re-plans local reminders, so those never drift from the stored data.
@MainActor
final class SyncCoordinator: SyncTriggering, ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var lastReport: SyncReport?
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var isOnline = true
    /// Why the last download failed, so the UI can say so instead of showing an unexplained empty list.
    @Published private(set) var lastPullError: String?

    let engine: SyncEngine
    private let pull: PullService
    private let store: LocalStore
    private let widget: WidgetSnapshotPublisher
    private let reminders: NotificationScheduler
    private let actorProvider: () -> ActingUser?
    /// Every project the signed-in user belongs to. The first sync must download
    /// these BEFORE a project is selected, otherwise the project list can never fill.
    private let projectIDs: () -> [UUID]
    private let onPulled: @MainActor () async -> Void
    private let onAuthExpired: () -> Void
    private let connectivity = ConnectivityMonitor()
    private var cursors: [UUID: Date] = [:]
    private var pending: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    /// Unread count seen last time; nil until the first load, so existing items never alert on launch.
    private var lastUnread: Int?

    init(engine: SyncEngine, pull: PullService, store: LocalStore, widget: WidgetSnapshotPublisher, reminders: NotificationScheduler, actorProvider: @escaping () -> ActingUser?, projectIDs: @escaping () -> [UUID], onPulled: @escaping @MainActor () async -> Void, onAuthExpired: @escaping () -> Void) {
        self.engine = engine
        self.pull = pull
        self.store = store
        self.widget = widget
        self.reminders = reminders
        self.actorProvider = actorProvider
        self.projectIDs = projectIDs
        self.onPulled = onPulled
        self.onAuthExpired = onAuthExpired
        connectivity.onChange = { [weak self] online in
            self?.isOnline = online
            if online { Task { await self?.requestSync() } }
        }
        connectivity.start()
        startPolling()
    }

    /// Apple's push service needs a paid developer account, which this build does not use.
    /// Instead the app checks the server every minute while it is open; new items raise a local alert.
    private func startPolling() {
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await self?.syncNow()
            }
        }
    }

    nonisolated func requestSync() async { await MainActor.run { self.schedule() } }

    /// Coalesces bursts of local changes into one drain.
    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { await self?.syncNow() }
        }
    }

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let report = await engine.drain()
        lastReport = report
        if report.authExpired { onAuthExpired() }

        if !report.stoppedOffline, !report.authExpired {
            var failure: String?
            var appliedAny = false
            let projects = Set(projectIDs()).union(actorProvider().map { [$0.projectID] } ?? [])
            for projectID in projects {
                do {
                    let result = try await pull.pull(projectID: projectID, since: cursors[projectID])
                    if let latest = result.latestUpdate { cursors[projectID] = latest }
                    if result.applied > 0 { appliedAny = true }
                } catch {
                    failure = Self.describe(error)
                }
            }
            lastPullError = failure
            if failure == nil { lastSyncedAt = Date() }
            if appliedAny { await onPulled() }
        } else if report.stoppedOffline {
            lastPullError = "You appear to be offline."
        }
        await refreshDerivedState()
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case RemoteError.offline: "You appear to be offline."
        case RemoteError.unauthorized: "Your session has expired. Sign in again."
        case RemoteError.transient(let m): "The server had a problem (\(m)). Try again."
        case RemoteError.rejected(let m): "The server refused the request: \(m)"
        default: error.localizedDescription
        }
    }

    func refreshDerivedState() async {
        guard let actor = actorProvider() else { return }
        await widget.publish(projectID: actor.projectID)
        let repo = ProjectRepository(store: store)
        if let snap = try? await repo.snapshot(projectID: actor.projectID) {
            let unread = snap.notifications.filter { !$0.isRead }
            if let previous = lastUnread, unread.count > previous, let newest = unread.first {
                await reminders.alert(id: "new-\(newest.id.uuidString)", title: newest.title, body: newest.body, deepLink: newest.deepLink)
            }
            lastUnread = unread.count
            let plan = ReminderPlanner.plan(tasks: snap.tasks, inspections: snap.inspections, assignedTo: actor.userID, preferences: Preferences.notificationPreferences, now: Date())
            await reminders.apply(plan)
        }
    }
}

/// Notification preferences persisted per device.
enum Preferences {
    private static let key = "notification.preferences"
    static var notificationPreferences: NotificationPreferences {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(NotificationPreferences.self, from: $0) } ?? NotificationPreferences() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}
