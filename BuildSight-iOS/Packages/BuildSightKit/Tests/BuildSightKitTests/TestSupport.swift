import Foundation
@testable import BuildSightKit

// Swift Testing also exports a type named `Issue`; this module-level alias makes
// the domain type win everywhere in the test target.
typealias Issue = BuildSightKit.Issue

/// Fixed fixtures so every test states only what it is about. Dates and the
/// calendar are pinned: tests must not depend on the machine's clock or zone.
enum Fixture {
    static let projectA = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    static let projectB = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!
    static let areaA = UUID(uuidString: "AAAAAAAA-0000-4000-8000-0000000000A1")!
    static let areaB = UUID(uuidString: "BBBBBBBB-0000-4000-8000-0000000000B1")!
    static let worker = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!
    static let supervisor = UUID(uuidString: "00000000-0000-4000-8000-000000000022")!
    static let otherSupervisor = UUID(uuidString: "00000000-0000-4000-8000-000000000033")!

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Colombo")!
        return c
    }

    /// 25 Sep 2026, 12:00 in Colombo.
    static let now: Date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!

    static func date(day: Int, hour: Int = 12, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    static let gps = LocationFix.gps(GeoPoint(latitude: 6.9271, longitude: 79.8612, horizontalAccuracy: 8))

    static func issue(status: IssueStatus = .open, assignee: UUID? = nil, resolvedBy: UUID? = nil, review: HumanReviewStatus = .notRequired, origin: IssueOrigin = .manual, project: UUID = projectA, priority: Priority = .medium) -> Issue {
        Issue(projectID: project, areaID: project == projectA ? areaA : areaB, title: "Crack", details: "", category: .structural, priority: priority, status: status, assigneeID: assignee, reporterID: worker, resolvedByID: resolvedBy, createdAt: now, location: gps, origin: origin, review: review)
    }

    static func photo(project: UUID = projectA) -> EvidencePhoto {
        EvidencePhoto(projectID: project, areaID: project == projectA ? areaA : areaB, creatorID: worker, capturedAt: now, location: gps, category: .safety, note: "", localFilename: "p.jpg", pixelWidth: 1600, pixelHeight: 1200)
    }

    static func task(status: TaskItem.Status = .notStarted, due: Date, project: UUID = projectA) -> TaskItem {
        TaskItem(projectID: project, title: "Task", assigneeID: worker, creatorID: supervisor, priority: .medium, status: status, dueDate: due, createdAt: date(day: 20))
    }

    static let sharpImage = ImageQuality(pixelWidth: 1600, pixelHeight: 1200, sharpness: 150)

    static func obs(_ label: HelmetLabel, _ score: Double, x: Double = 0.1, y: Double = 0.1, w: Double = 0.2, h: Double = 0.2) -> HelmetObservation {
        HelmetObservation(label: label, score: score, box: NormalizedRect(x: x, y: y, width: w, height: h))
    }
}
