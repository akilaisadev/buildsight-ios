import Foundation
import Observation

// MARK: - Timeline

@MainActor
@Observable
public final class TimelineViewModel {
    public var filter: TimelineFilter
    private let calendar: Calendar

    public init(filter: TimelineFilter = TimelineFilter(), calendar: Calendar = .current) {
        self.filter = filter
        self.calendar = calendar
    }

    public func sections(for snapshot: ProjectSnapshot) -> [TimelineSection] {
        let events = TimelineBuilder.events(projectID: snapshot.project.id, photos: snapshot.photos, issues: snapshot.issues, inspections: snapshot.inspections, tasks: snapshot.tasks)
        return TimelineBuilder.sections(events, filter: filter, calendar: calendar)
    }

    /// Status choices offered by the filter come from the data actually present.
    public func availableStatuses(for snapshot: ProjectSnapshot) -> [String] {
        let events = TimelineBuilder.events(projectID: snapshot.project.id, photos: snapshot.photos, issues: snapshot.issues, inspections: snapshot.inspections, tasks: snapshot.tasks)
        return Array(Set(events.map(\.statusLabel))).sorted()
    }

    public func setToday(now: Date) {
        let start = calendar.startOfDay(for: now)
        filter.dateRange = start...(calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) ?? now)
    }

    public func clear() { filter = TimelineFilter() }
}

// MARK: - Map

@MainActor
@Observable
public final class MapViewModel {
    public var visibleKinds: Set<TimelineKind> = Set(TimelineKind.allCases)
    public var selected: RecordRef?
    public private(set) var locationPermission: LocationPermission

    public init(locationPermission: LocationPermission = .notDetermined) {
        self.locationPermission = locationPermission
    }

    public func updatePermission(_ p: LocationPermission) { locationPermission = p }

    public func projection(for snapshot: ProjectSnapshot) -> MapProjection {
        let all = MapProjector.project(projectID: snapshot.project.id, photos: snapshot.photos, issues: snapshot.issues, inspections: snapshot.inspections, tasks: snapshot.tasks)
        return MapProjection(
            items: all.items.filter { visibleKinds.contains($0.ref.kind) },
            withoutLocation: all.withoutLocation.filter { visibleKinds.contains($0.kind) }
        )
    }

    public func toggle(_ kind: TimelineKind) {
        if visibleKinds.contains(kind) { visibleKinds.remove(kind) } else { visibleKinds.insert(kind) }
    }

    /// Explains why pins might be missing, so an empty map is never a mystery.
    public func permissionNotice() -> String? {
        switch locationPermission {
        case .denied: "Location access is off. Records you capture won't get GPS positions. You can turn it on in Settings."
        case .restricted: "Location is restricted on this device, so new records are saved without GPS."
        case .approximateOnly: "Approximate location is on. New records get a rough position with a wide accuracy ring."
        default: nil
        }
    }
}

// MARK: - Notifications

@MainActor
@Observable
public final class NotificationsViewModel {
    public var showUnreadOnly = false
    private let repository: NotificationRepository
    private let clock: @Sendable () -> Date

    public init(repository: NotificationRepository, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.repository = repository
        self.clock = clock
    }

    public func items(in snapshot: ProjectSnapshot) -> [AppNotification] {
        snapshot.notifications.filter { !showUnreadOnly || !$0.isRead }.sorted { $0.createdAt > $1.createdAt }
    }

    public func unreadCount(in snapshot: ProjectSnapshot) -> Int { snapshot.notifications.filter { !$0.isRead }.count }

    public func open(_ n: AppNotification) async { try? await repository.markRead(n, now: clock()) }
    public func markAllRead(projectID: UUID) async { try? await repository.markAllRead(projectID: projectID, now: clock()) }
}

// MARK: - Sync Center

public struct SyncRow: Identifiable, Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case waiting
        case uploading
        case retrying(at: Date)
        case failed(String)
    }
    public var id: UUID
    public var title: String
    public var recordType: RecordType
    public var phase: Phase
    public var attempts: Int
}

@MainActor
@Observable
public final class SyncCenterViewModel {
    public private(set) var rows: [SyncRow] = []
    public private(set) var summary = SyncSummary()
    public private(set) var isSyncing = false
    public private(set) var lastReport: SyncReport?

    private let store: LocalStore
    private let engine: SyncEngine
    private let titleFor: @Sendable (PendingOperation) -> String

    public init(store: LocalStore, engine: SyncEngine, titleFor: @escaping @Sendable (PendingOperation) -> String = { defaultSyncRowTitle($0) }) {
        self.store = store
        self.engine = engine
        self.titleFor = titleFor
    }

    public func reload() async {
        let ops = (try? await store.pendingOperations()) ?? []
        rows = ops.map { op in
            let phase: SyncRow.Phase
            switch op.state {
            case .inFlight: phase = .uploading
            case .failed: phase = .failed(op.lastError ?? "Rejected by the server")
            case .pending:
                if let due = op.nextAttemptAt, op.attempts > 0 { phase = .retrying(at: due) } else { phase = .waiting }
            }
            return SyncRow(id: op.id, title: titleFor(op), recordType: op.recordType, phase: phase, attempts: op.attempts)
        }
        summary = (try? await store.syncSummary(projectID: nil)) ?? SyncSummary()
    }

    public func observe() async {
        await reload()
        for await _ in store.changes() { if Task.isCancelled { break }; await reload() }
    }

    public func syncNow() async {
        isSyncing = true
        lastReport = await engine.drain()
        isSyncing = false
        await reload()
    }

    public func retry(_ id: UUID) async { await engine.retry(id); await syncNow() }
    public func discard(_ id: UUID) async { try? await store.discardOperation(id); await reload() }
}

/// Best human label for a queued operation, read from its payload.
public func defaultSyncRowTitle(_ op: PendingOperation) -> String {
    guard let json = try? JSONValue.parse(op.payload).objectValue else { return op.recordType.rawValue }
    for key in ["title", "templateName", "note", "localFilename"] {
        if case .string(let s)? = json[key], !s.isEmpty { return s }
    }
    return op.recordType.rawValue
}
