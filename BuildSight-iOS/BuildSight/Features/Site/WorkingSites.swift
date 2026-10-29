import SwiftUI
import MapKit

/// The company's working sites, as in the design data (name, city, status, progress).
/// Shown as pins on the Site map, so the whole country is visible at a glance.
struct WorkingSite: Identifiable {
    let id: Int
    let name: String
    let city: String
    let status: String
    let progress: Int
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    static let all: [WorkingSite] = [
        WorkingSite(id: 1, name: "Central Tower Development", city: "Colombo", status: "Active", progress: 68, latitude: 6.9271, longitude: 79.8612),
        WorkingSite(id: 2, name: "Kandy Road Rehabilitation", city: "Kandy", status: "Active", progress: 41, latitude: 7.2906, longitude: 80.6337),
        WorkingSite(id: 3, name: "Lakeside Commercial Complex", city: "Negombo", status: "Active", progress: 82, latitude: 7.2083, longitude: 79.8358),
        WorkingSite(id: 4, name: "North Residential Block", city: "Gampaha", status: "Planning", progress: 12, latitude: 7.0917, longitude: 79.9997),
    ]

    /// Sri Lanka, framed so the whole island and every site show.
    static let sriLankaRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 7.55, longitude: 80.75),
        span: MKCoordinateSpan(latitudeDelta: 4.4, longitudeDelta: 3.2))
}

/// Pin for a working site: name, status and progress in one readable label.
struct WorkingSitePin: View {
    let site: WorkingSite

    var body: some View {
        VStack(spacing: 4) {
            VStack(spacing: 2) {
                Text(site.city).font(.caption.weight(.bold)).foregroundStyle(Theme.text)
                Text("\(site.progress)% complete").font(.caption2.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            Image(systemName: "building.2.fill").font(.subheadline.bold()).foregroundStyle(Theme.onAccent)
                .frame(width: 36, height: 36)
                .background(site.status == "Planning" ? Theme.secondaryText : Theme.accent, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(radius: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(site.name), \(site.city), \(site.status), \(site.progress) percent complete")
    }
}
