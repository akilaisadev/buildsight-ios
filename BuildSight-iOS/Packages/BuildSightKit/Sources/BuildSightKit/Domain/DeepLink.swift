import Foundation

/// Destinations reachable from a widget, a notification or the dashboard.
/// One type for all three so the URL scheme is defined in exactly one place.
public enum DeepLink: Codable, Hashable, Sendable {
    case issue(projectID: UUID, issueID: UUID)
    case helmetFlags(projectID: UUID, unreviewedOnly: Bool)
    case map(projectID: UUID)
    case task(projectID: UUID, taskID: UUID)
    case inspection(projectID: UUID, inspectionID: UUID)

    public static let scheme = "buildsight"

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .issue(let p, let i):
            c.host = "issue"; c.path = "/\(p.uuidString)/\(i.uuidString)"
        case .helmetFlags(let p, let unreviewed):
            c.host = "helmet-flags"; c.path = "/\(p.uuidString)"
            c.queryItems = [URLQueryItem(name: "unreviewed", value: unreviewed ? "1" : "0")]
        case .map(let p):
            c.host = "map"; c.path = "/\(p.uuidString)"
        case .task(let p, let t):
            c.host = "task"; c.path = "/\(p.uuidString)/\(t.uuidString)"
        case .inspection(let p, let i):
            c.host = "inspection"; c.path = "/\(p.uuidString)/\(i.uuidString)"
        }
        // The components above only hold fixed strings and UUIDs, so this
        // cannot fail; the fallback keeps the type total without a force unwrap.
        return c.url ?? URL(fileURLWithPath: "/")
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }.compactMap { UUID(uuidString: $0) }
        let rawCount = url.pathComponents.filter { $0 != "/" }.count
        guard parts.count == rawCount else { return nil }   // a malformed id invalidates the link
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        switch (host, parts.count) {
        case ("issue", 2): self = .issue(projectID: parts[0], issueID: parts[1])
        case ("helmet-flags", 1):
            let unreviewed = query.first { $0.name == "unreviewed" }?.value == "1"
            self = .helmetFlags(projectID: parts[0], unreviewedOnly: unreviewed)
        case ("map", 1): self = .map(projectID: parts[0])
        case ("task", 2): self = .task(projectID: parts[0], taskID: parts[1])
        case ("inspection", 2): self = .inspection(projectID: parts[0], inspectionID: parts[1])
        default: return nil
        }
    }

    public var projectID: UUID {
        switch self {
        case .issue(let p, _), .helmetFlags(let p, _), .map(let p), .task(let p, _), .inspection(let p, _): p
        }
    }
}

/// Payload printed on site-area QR codes: `buildsight://area/<project>/<area>`.
/// Kept separate from `DeepLink` because scanning must validate against the
/// *selected* project and reject codes that belong to another site.
public struct AreaQRPayload: Equatable, Sendable {
    public let projectID: UUID
    public let areaID: UUID

    public enum ValidationError: Error, Equatable, Sendable {
        case notABuildSightCode
        case wrongProject
        case unknownArea
    }

    public static func parse(_ raw: String) -> AreaQRPayload? {
        guard let url = URL(string: raw), url.scheme == DeepLink.scheme, url.host == "area" else { return nil }
        let ids = url.pathComponents.filter { $0 != "/" }.compactMap { UUID(uuidString: $0) }
        guard ids.count == 2, url.pathComponents.filter({ $0 != "/" }).count == 2 else { return nil }
        return AreaQRPayload(projectID: ids[0], areaID: ids[1])
    }

    /// Resolves a scanned string to one of the active project's areas.
    public static func resolve(_ raw: String, activeProject: UUID, areas: [SiteArea]) -> Result<SiteArea, ValidationError> {
        guard let payload = parse(raw) else { return .failure(.notABuildSightCode) }
        guard payload.projectID == activeProject else { return .failure(.wrongProject) }
        guard let area = areas.first(where: { $0.id == payload.areaID && $0.projectID == activeProject }) else {
            return .failure(.unknownArea)
        }
        return .success(area)
    }

    public static func makeString(projectID: UUID, areaID: UUID) -> String {
        "\(DeepLink.scheme)://area/\(projectID.uuidString)/\(areaID.uuidString)"
    }
}
