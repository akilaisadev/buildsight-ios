import Foundation
import CoreLocation
import os
import BuildSightKit

/// Watches site regions (from `GeofencePlanner`) and raises a local alert when the
/// worker arrives at or leaves a site. iOS delivers these even when the app is closed,
/// once the user grants "Always" location access.
@MainActor
final class GeofenceService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var names: [String: String] = [:]
    private let alert: (String, String, String) async -> Void
    private let log = Logger(subsystem: "com.buildsight.app", category: "geofence")

    init(alert: @escaping (String, String, String) async -> Void) {
        self.alert = alert
        super.init()
        manager.delegate = self
    }

    var isAvailable: Bool { CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) }

    /// Replaces the monitored regions. Called whenever the project list or the setting changes.
    func update(_ regions: [SiteRegion], enabled: Bool) {
        for region in manager.monitoredRegions where region.identifier.hasPrefix(GeofencePlanner.identifierPrefix) {
            manager.stopMonitoring(for: region)
        }
        names = [:]
        guard enabled, isAvailable, !regions.isEmpty else { log.info("geofencing off (\(regions.count) regions)"); return }
        if manager.authorizationStatus != .authorizedAlways { manager.requestAlwaysAuthorization() }
        for r in regions {
            let circle = CLCircularRegion(center: CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude), radius: r.radius, identifier: r.identifier)
            circle.notifyOnEntry = true
            circle.notifyOnExit = true
            names[r.identifier] = r.name
            manager.startMonitoring(for: circle)
        }
        log.info("monitoring \(regions.count) site regions")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in await self.fire(.entered, id) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in await self.fire(.exited, id) }
    }

    private func fire(_ event: GeofenceEvent, _ identifier: String) async {
        guard let name = names[identifier] else { return }
        log.info("\(event == .entered ? "entered" : "left") \(name, privacy: .public)")
        let message = GeofencePlanner.message(for: event, site: name)
        await alert("geo-\(identifier)-\(Int(Date().timeIntervalSince1970))", message.title, message.body)
    }
}
