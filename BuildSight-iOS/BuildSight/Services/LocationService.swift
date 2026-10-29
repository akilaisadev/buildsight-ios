import Foundation
import CoreLocation
import BuildSightKit

/// Core Location wrapper. Asks for when-in-use access, returns the best fix
/// obtained inside the timeout, and reports WHY a fix is missing instead of
/// ever returning a default coordinate.
final class LocationService: NSObject, LocationProviding, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<LocationFix, Never>] = [:]
    private var best: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var permission: LocationPermission {
        switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorizedAlways: .always
        case .authorizedWhenInUse: manager.accuracyAuthorization == .reducedAccuracy ? .approximateOnly : .whenInUse
        @unknown default: .denied
        }
    }

    func requestAuthorisation() { if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() } }

    func currentFix(timeout: TimeInterval) async -> LocationFix {
        guard CLLocationManager.locationServicesEnabled() else { return .unavailable(.servicesDisabled) }
        switch manager.authorizationStatus {
        case .denied: return .unavailable(.permissionDenied)
        case .restricted: return .unavailable(.permissionRestricted)
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: break
        }
        // A fix newer than 10 s is good enough and saves a GPS wake-up.
        if let recent = manager.location, abs(recent.timestamp.timeIntervalSinceNow) < 10, recent.horizontalAccuracy >= 0 {
            return fix(from: recent)
        }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock(); waiters[id] = continuation; lock.unlock()
            DispatchQueue.main.async { self.manager.requestLocation() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(id, with: self?.bestFix() ?? .unavailable(.timedOut))
            }
        }
    }

    private func bestFix() -> LocationFix? { lock.lock(); defer { lock.unlock() }; return best.map(fix(from:)) }

    private func fix(from l: CLLocation) -> LocationFix {
        .gps(GeoPoint(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude, horizontalAccuracy: l.horizontalAccuracy))
    }

    private func finish(_ id: UUID, with fix: LocationFix) {
        lock.lock(); let c = waiters.removeValue(forKey: id); lock.unlock()
        c?.resume(returning: fix)
    }

    private func finishAll(with fix: LocationFix) {
        lock.lock(); let all = waiters; waiters = [:]; lock.unlock()
        all.values.forEach { $0.resume(returning: fix) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0 else { return }
        lock.lock(); best = l; lock.unlock()
        finishAll(with: fix(from: l))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let reason: LocationUnavailableReason = (error as? CLError)?.code == .denied ? .permissionDenied : .noFixYet
        finishAll(with: .unavailable(reason))
    }
}
