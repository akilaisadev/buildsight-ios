// Prints SQL that fills the demo project with realistic mock records (issues,
// timeline events, tasks, inspections, notifications). Records are built with the
// app's own types and decoded again before printing, so the app can read every row.
// Run once in the Supabase SQL editor after seed.sql. IDs are fresh on every run.
import Foundation
import BuildSightKit

@main
struct MakeDemoData {
    static let project = UUID(uuidString: "7EC64DFC-14F6-4FB5-AF66-3173C27A6124")!
    static let ground = UUID(uuidString: "B5ECC921-290F-4958-A4C2-41CA0D103994")!
    static let level1 = UUID(uuidString: "65E0A7B6-39C3-4D2F-8555-C8AB6D54186A")!
    static let roof = UUID(uuidString: "6ED6317A-77D7-433A-87F0-13B5BEB42425")!
    static let supervisor = UUID(uuidString: "521B06EF-9676-458F-AD7A-70F13829B78B")!
    static let worker = UUID(uuidString: "22C14C87-0C15-4EF3-BF45-01638D1B848B")!
    static let engineer = UUID(uuidString: "00D21B44-B943-444B-8A37-46CEDDBC1B28")!
    static let inspector = UUID(uuidString: "013A4813-F38B-4D21-957F-04B44F232BED")!
    static let pm = UUID(uuidString: "24D1E58D-B357-4C9D-BA63-C21F4A91CDA4")!

    static let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    static func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
    static func inDays(_ d: Double) -> Date { now.addingTimeInterval(d * 86_400) }
    /// Positions around the Colombo site, a few metres apart, so they appear as map pins.
    static func gps(_ dLat: Double, _ dLon: Double) -> LocationFix {
        .gps(GeoPoint(latitude: 6.9271 + dLat, longitude: 79.8612 + dLon, horizontalAccuracy: 8))
    }

    static let encoder = RecordCodec.makeEncoder()
    static let decoder = RecordCodec.makeDecoder()
    static var rows: [String] = []

    static func add<R: SyncableRecord & Equatable>(_ r: R, id: UUID, type: RecordType, parent: UUID? = nil, sort: Date, by: UUID) throws {
        let data = try encoder.encode(r)
        guard try decoder.decode(R.self, from: data) == r else { throw NSError(domain: "demo", code: 1, userInfo: [NSLocalizedDescriptionKey: "round-trip mismatch: \(type)"]) }
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        let p = parent.map { "'\($0)'" } ?? "null"
        rows.append("  ('\(id)', '\(type.rawValue)', '\(project)', \(p), '\(iso(sort))', '\(json)'::jsonb, '\(by)')")
    }
    static func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); return f.string(from: d) }

    static func main() throws {
        let issues: [(String, String, IssueCategory, Priority, IssueStatus, UUID, UUID?, Double, LocationFix)] = [
            ("Concrete surface defect", "Honeycombing on the east column face, about 30 cm across.", .structural, .high, .open, ground, engineer, 5, gps(0.0004, 0.0002)),
            ("Exposed wiring near stairwell", "Live cable run without conduit at the level 1 stair landing.", .electrical, .critical, .inProgress, level1, worker, 9, gps(-0.0003, 0.0005)),
            ("Rebar spacing out of tolerance", "Spacing measured at 220 mm against 150 mm on drawings.", .structural, .medium, .open, level1, engineer, 26, gps(0.0006, -0.0004)),
            ("Leaking pipe joint", "Slow leak at the riser joint above the plant room.", .plumbing, .medium, .resolved, ground, worker, 30, .unavailable(.permissionDenied)),
            ("Missing edge protection", "Roof edge barrier removed for lifting and not refitted.", .safety, .critical, .open, roof, supervisor, 2, gps(-0.0005, -0.0003)),
            ("Plaster finish uneven", "Visible ripples on the corridor wall finish.", .quality, .low, .verified, level1, nil, 50, gps(0.0002, 0.0007)),
        ]
        var issueIDs: [UUID] = []
        for (title, details, cat, pri, status, area, assignee, hours, loc) in issues {
            let created = ago(hours: hours)
            let issue = Issue(projectID: project, areaID: area, title: title, details: details, category: cat, priority: pri, status: status, assigneeID: assignee, reporterID: worker, dueDate: inDays(3), createdAt: created, location: loc)
            try add(issue, id: issue.id, type: .issue, sort: created, by: worker)
            let created_ = IssueEvent(projectID: project, issueID: issue.id, actorID: worker, at: created, kind: .created, note: "Reported on site")
            try add(created_, id: created_.id, type: .issueEvent, parent: issue.id, sort: created, by: worker)
            issueIDs.append(issue.id)
        }

        let tasks: [(String, UUID, UUID, Priority, Double)] = [
            ("Repair damaged section on east column", engineer, ground, .high, 0.3),
            ("Fit conduit to stairwell cabling", worker, level1, .critical, 0.6),
            ("Re-tie rebar to drawing spacing", engineer, level1, .medium, 2),
            ("Refit roof edge protection", supervisor, roof, .critical, 0.2),
        ]
        for (i, (title, who, area, pri, due)) in tasks.enumerated() {
            let t = TaskItem(projectID: project, areaID: area, title: title, assigneeID: who, creatorID: pm, priority: pri, dueDate: inDays(due), relatedIssueID: issueIDs[min(i, issueIDs.count - 1)], createdAt: ago(hours: 4))
            try add(t, id: t.id, type: .task, sort: t.createdAt, by: pm)
        }

        let done = Inspection(projectID: project, areaID: ground, templateName: "Structural inspection", inspectorID: inspector, startedAt: ago(hours: 28), completedAt: ago(hours: 27), dueDate: ago(hours: 24),
                              items: [InspectionItem(title: "Columns plumb and aligned", result: .pass), InspectionItem(title: "Formwork removed safely", result: .pass), InspectionItem(title: "No visible cracking", result: .pass)], location: gps(0.0001, 0.0001))
        try add(done, id: done.id, type: .inspection, sort: done.startedAt, by: inspector)
        let open = Inspection(projectID: project, areaID: roof, templateName: "Roof safety walkdown", inspectorID: inspector, startedAt: ago(hours: 1), dueDate: inDays(1),
                              items: [InspectionItem(title: "Edge protection in place", result: .fail, note: "Barrier missing on north edge"), InspectionItem(title: "Harness anchor points tagged"), InspectionItem(title: "Access hatch secured")], location: gps(-0.0004, -0.0002))
        try add(open, id: open.id, type: .inspection, sort: open.startedAt, by: inspector)

        let notes: [(AppNotification.Kind, String, String, Double)] = [
            (.issueAssigned, "Issue assigned to you", "Exposed wiring near stairwell", 8),
            (.inspectionDue, "Inspection due tomorrow", "Roof safety walkdown", 1),
            (.issueStatusChanged, "Issue resolved", "Leaking pipe joint was marked resolved", 20),
        ]
        for (kind, title, body, hours) in notes {
            let n = AppNotification(projectID: project, kind: kind, title: title, body: body, createdAt: ago(hours: hours))
            try add(n, id: n.id, type: .notification, sort: n.createdAt, by: pm)
        }

        print("-- Generated by make_demo_data.swift: mock records for the demo project. Run once.")
        print("begin;")
        print("insert into records (id, type, project_id, parent_id, sort_date, payload, created_by) values")
        print(rows.joined(separator: ",\n"))
        print("on conflict (id) do nothing;")
        print("commit;")
    }
}
