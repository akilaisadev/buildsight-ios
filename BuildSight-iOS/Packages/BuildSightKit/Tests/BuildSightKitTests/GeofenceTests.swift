import Testing
import Foundation
@testable import BuildSightKit

@Suite("Site geofencing")
struct GeofenceTests {
    private func project(_ name: String, _ centre: GeoPoint?, status: Project.Status = .active) -> Project {
        Project(id: UUID(), name: name, locationName: "Colombo", status: status, startDate: Date(), endDate: Date(), managerName: "PM", centre: centre)
    }
    private let colombo = GeoPoint(latitude: 6.9271, longitude: 79.8612, horizontalAccuracy: 0)

    @Test("A project with a location becomes a region at that location")
    func regionFromProject() throws {
        let p = project("Central Tower", colombo)
        let region = try #require(GeofencePlanner.regions(for: [p]).first)
        #expect(region.projectID == p.id)
        #expect(region.latitude == 6.9271 && region.longitude == 79.8612)
        #expect(region.identifier == "site." + p.id.uuidString)
    }

    @Test("Projects without a location, with impossible coordinates, or completed are skipped")
    func skipsUnusable() {
        let regions = GeofencePlanner.regions(for: [
            project("No centre", nil),
            project("Bad latitude", GeoPoint(latitude: 120, longitude: 79, horizontalAccuracy: 0)),
            project("Null island", GeoPoint(latitude: 0, longitude: 0, horizontalAccuracy: 0)),
            project("Finished", colombo, status: .completed),
        ])
        #expect(regions.isEmpty)
    }

    @Test("Never more than the 20 regions iOS allows")
    func capsAtTwenty() {
        let many = (0..<30).map { project("Site \($0)", colombo) }
        #expect(GeofencePlanner.regions(for: many).count == GeofencePlanner.maxRegions)
    }

    @Test("Radius is clamped to a reliable range", arguments: [(10.0, 100.0), (150.0, 150.0), (5000.0, 1000.0)])
    func radiusClamped(requested: Double, expected: Double) throws {
        let region = try #require(GeofencePlanner.regions(for: [project("Site", colombo)], radius: requested).first)
        #expect(region.radius == expected)
    }

    @Test("Alert wording names the site and never claims it is safe")
    func wording() {
        let enter = GeofencePlanner.message(for: .entered, site: "Central Tower")
        let exit = GeofencePlanner.message(for: .exited, site: "Central Tower")
        #expect(enter.title == "Arrived at Central Tower")
        #expect(exit.title == "Left Central Tower")
        #expect(!(enter.body + exit.body).lowercased().contains("safe"))
    }
}
