// swift-tools-version: 5.10
import PackageDescription

// BuildSightKit holds everything that can be verified without a simulator:
// the domain model, business rules, helmet-result interpretation, the sync
// engine and the Core Data stack. The app target only adds SwiftUI and
// hardware services on top. macOS is listed so `swift test` runs on a laptop.
let package = Package(
    name: "BuildSightKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BuildSightKit", targets: ["BuildSightKit"]),
    ],
    targets: [
        .target(name: "BuildSightKit"),
        .testTarget(name: "BuildSightKitTests", dependencies: ["BuildSightKit"]),
    ]
)
