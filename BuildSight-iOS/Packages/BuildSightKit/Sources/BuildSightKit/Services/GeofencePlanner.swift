import Foundation

/// A circular area around a site that the phone watches for arrivals and departures.
public struct SiteRegion: Equatable, Sendable {
    public let identifier: String
    public let projectID: UUID
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let radius: Double
}

public enum GeofenceEvent: Equatable, Sendable {
    case entered
    case exited
}

/// Turns projects (real data from the server) into the regions the app monitors.
/// Pure logic, so the rules are unit tested without Core Location.
public enum GeofencePlanner {
    /// iOS monitors at most 20 regions per app.
    public static let maxRegions = 20
    public static let defaultRadius: Double = 150
    /// Smaller regions are unreliable with GPS drift; larger ones fire far from site.
    public static let radiusRange: ClosedRange<Double> = 100...1000
    public static let identifierPrefix = "site."

    public static func regions(for projects: [Project], radius: Double = defaultRadius) -> [SiteRegion] {
        let clamped = min(max(radius, radiusRange.lowerBound), radiusRange.upperBound)
        let regions = projects.compactMap { project -> SiteRegion? in
            guard project.status != .completed, let centre = project.centre,
                  (-90...90).contains(centre.latitude), (-180...180).contains(centre.longitude),
                  !(centre.latitude == 0 && centre.longitude == 0) else { return nil }
            return SiteRegion(identifier: identifierPrefix + project.id.uuidString, projectID: project.id,
                              name: project.name, latitude: centre.latitude, longitude: centre.longitude, radius: clamped)
        }
        return Array(regions.prefix(maxRegions))
    }

    /// Wording for the alert. Factual, never claims the site is safe.
    public static func message(for event: GeofenceEvent, site: String) -> (title: String, body: String) {
        switch event {
        case .entered: ("Arrived at \(site)", "You're on site. Open BuildSight to capture today's evidence.")
        case .exited: ("Left \(site)", "Anything not yet uploaded will sync when you're back online.")
        }
    }
}
