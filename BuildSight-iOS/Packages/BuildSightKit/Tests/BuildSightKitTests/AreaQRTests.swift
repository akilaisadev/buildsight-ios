import Testing
import Foundation
@testable import BuildSightKit

@Suite("Area QR codes")
struct AreaQRTests {
    @Test("A code printed for an area reads back to the same project and area")
    func roundTrip() throws {
        let project = UUID(), area = UUID()
        let printed = "buildsight://area/\(project.uuidString)/\(area.uuidString)"
        let parsed = try #require(AreaQRPayload.parse(printed))
        #expect(parsed.projectID == project)
        #expect(parsed.areaID == area)
    }

    @Test("Codes that are not BuildSight area codes are rejected")
    func rejectsOtherCodes() {
        #expect(AreaQRPayload.parse("https://example.com") == nil)
        #expect(AreaQRPayload.parse("buildsight://issue/x/y") == nil)
    }
}
