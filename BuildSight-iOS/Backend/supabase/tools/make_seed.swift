// Prints SQL that seeds one organisation, project, site areas and team members.
// Payloads are encoded with the app's own types and codec, then decoded again
// before printing, so a shape mismatch fails here and not on a phone.
//
//   swiftc -parse-as-library … make_seed.swift -lBuildSightKit -o make-seed
//   ./make-seed --project "Tower A" --location "Site address" \
//       --user <auth-user-uuid>:projectManager:"Alex Lee" \
//       --user <auth-user-uuid>:siteWorker:"Sam Tan" > seed.sql
//
// Run the output in the Supabase SQL editor AFTER schema.sql and after the auth
// users exist (Authentication → Users → Add user). Roles: siteWorker, engineer,
// supervisor, inspector, projectManager. Run it ONCE per project: ids are generated
// fresh each time, so running a second seed creates a second project.
import Foundation
import BuildSightKit

@main
struct MakeSeed {
    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        var project = "Demo Site", location = "Site office", org = "Demo Organisation", managerName: String?
        var users: [(UUID, Role, String)] = []
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
        }
        project = value("--project") ?? project
        location = value("--location") ?? location
        org = value("--org") ?? org
        managerName = value("--manager")
        // Add users to a project that is already seeded (no new org, project or areas).
        let existingProject = value("--existing-project").flatMap(UUID.init(uuidString:))
        let existingOrg = value("--existing-org").flatMap(UUID.init(uuidString:))
        while let spec = value("--user") {
            let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let id = UUID(uuidString: parts[0]), let role = Role(rawValue: parts[1]), !parts[2].isEmpty else {
                FileHandle.standardError.write(Data("bad --user '\(spec)': expected <uuid>:<role>:<display name>\n".utf8)); exit(2)
            }
            users.append((id, role, parts[2]))
        }
        guard !users.isEmpty else { FileHandle.standardError.write(Data("need at least one --user\n".utf8)); exit(2) }

        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))   // whole seconds round-trip exactly
        let projectID = existingProject ?? UUID(), orgID = existingOrg ?? UUID()
        let adding = existingProject != nil
        if adding && existingOrg == nil { FileHandle.standardError.write(Data("--existing-project needs --existing-org\n".utf8)); exit(2) }
        let manager = managerName ?? users.first { $0.1 == .projectManager }?.2 ?? users[0].2
        let proj = Project(id: projectID, name: project, locationName: location, status: .active,
                           startDate: now, endDate: now.addingTimeInterval(365 * 86_400), managerName: manager, centre: nil, updatedAt: now)
        let areas = ["Ground Floor": "G", "Level 1": "1", "Roof": "R"].sorted { $0.key < $1.key }
            .map { SiteArea(id: UUID(), projectID: projectID, name: $0.key, level: $0.value) }
        let team = users.map { TeamMember(userID: $0.0, projectID: projectID, displayName: $0.2, role: $0.1) }

        let encoder = RecordCodec.makeEncoder(), decoder = RecordCodec.makeDecoder()
        func row<R: SyncableRecord & Equatable>(_ r: R, id: UUID, type: RecordType, createdBy: UUID) throws -> String {
            let data = try encoder.encode(r)
            guard try decoder.decode(R.self, from: data) == r else { throw NSError(domain: "seed", code: 1, userInfo: [NSLocalizedDescriptionKey: "round-trip mismatch for \(type)"]) }
            let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "''")
            return "  ('\(id)', '\(type.rawValue)', '\(projectID)', now(), '\(json)'::jsonb, '\(createdBy)')"
        }
        let creator = users[0].0
        var rows: [String] = []
        if !adding {
            rows.append(try row(proj, id: projectID, type: .project, createdBy: creator))
            for a in areas { rows.append(try row(a, id: a.id, type: .siteArea, createdBy: creator)) }
        }
        for t in team { rows.append(try row(t, id: t.id, type: .teamMember, createdBy: creator)) }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

        let orgInsert = adding ? "" : "insert into organisations (id, name) values ('\(orgID)', \(q(org)));\n"
        let projectInsert = adding ? "" : "insert into projects (id, organisation_id, payload) values ('\(projectID)', '\(orgID)', '{}'::jsonb);\n"
        let profileRows = users.map { "  ('\($0.0)', \(q($0.2)), '\(orgID)')" }.joined(separator: ",\n")
        let memberRows = users.map { "  ('\(projectID)', '\($0.0)', '\($0.1.rawValue)')" }.joined(separator: ",\n")
        // Organisation and project rows must exist before profiles/memberships reference them.
        print("-- Generated by make_seed.swift. Run in the Supabase SQL editor after schema.sql.")
        print("begin;")
        print(orgInsert + projectInsert, terminator: "")
        print("insert into profiles (id, display_name, organisation_id) values")
        print(profileRows)
        print("on conflict (id) do update set display_name = excluded.display_name, organisation_id = excluded.organisation_id;")
        print("insert into memberships (project_id, user_id, role) values")
        print(memberRows)
        print("on conflict do nothing;")
        print("insert into records (id, type, project_id, sort_date, payload, created_by) values")
        print(rows.joined(separator: ",\n"))
        print("on conflict (id) do nothing;")
        print("commit;")
    }
}
