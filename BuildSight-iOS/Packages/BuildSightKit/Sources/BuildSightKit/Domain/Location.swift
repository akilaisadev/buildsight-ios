import Foundation

public struct GeoPoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Radius in metres of the 68% confidence circle reported by Core Location.
    public var horizontalAccuracy: Double

    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
    }

    /// Core Location reports a negative accuracy for an invalid fix, and 0,0 is
    /// the classic "no data" value; neither should ever be stored as a position.
    public var isUsable: Bool {
        horizontalAccuracy >= 0
            && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
            && !(latitude == 0 && longitude == 0)
    }
}

public enum LocationUnavailableReason: String, Codable, Sendable {
    case permissionDenied
    case permissionRestricted
    case servicesDisabled
    case noFixYet
    case timedOut
    /// The photo was uploaded from the library, so the phone's current position is not where it was taken.
    case imported
}

/// A GPS reading, or an explicit statement that we do not have one. We never
/// invent coordinates: indoors the site area (chosen manually or by QR) is the
/// location, and `unavailable` records why the GPS part is missing.
public enum LocationFix: Codable, Hashable, Sendable {
    case gps(GeoPoint)
    case unavailable(LocationUnavailableReason)

    public var point: GeoPoint? {
        if case .gps(let p) = self, p.isUsable { return p }
        return nil
    }

    /// Fixes coarser than this are drawn on the map with an accuracy ring and
    /// labelled "approximate" in detail views.
    public static let approximateThresholdMetres: Double = 50

    public var isApproximate: Bool {
        guard let p = point else { return false }
        return p.horizontalAccuracy > Self.approximateThresholdMetres
    }
}
