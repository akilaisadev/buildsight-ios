import Foundation
#if !targetEnvironment(macCatalyst)
import MetricKit
#endif

/// Saves the crash and hang reports Apple delivers through MetricKit, so a failure on a phone can be
/// shared and read instead of going unnoticed. Reports stay on the device until the user shares them.
final class DiagnosticsCollector: NSObject, @unchecked Sendable {
    static let shared = DiagnosticsCollector()

    private let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Diagnostics", isDirectory: true)

    /// Saved reports, newest first.
    var reports: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func clear() { reports.forEach { try? FileManager.default.removeItem(at: $0) } }

    func save(_ json: Data) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? json.write(to: folder.appendingPathComponent("report-\(stamp)-\(UUID().uuidString.prefix(6)).json"), options: .atomic)
    }
}

#if !targetEnvironment(macCatalyst)
extension DiagnosticsCollector: MXMetricManagerSubscriber {
    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { save(payload.jsonRepresentation()) }
    }
}
#else
extension DiagnosticsCollector { func start() {} }
#endif
