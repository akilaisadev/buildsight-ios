import Foundation
import Network

/// Reports reachability so sync can start the moment a connection returns.
/// This is a hint only: a "satisfied" path does not guarantee the server is
/// reachable, so the sync engine still treats real request failures as truth.
@MainActor
final class ConnectivityMonitor {
    private let monitor = NWPathMonitor()
    private(set) var isOnline = true
    var onChange: ((Bool) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                self.onChange?(online)
            }
        }
        monitor.start(queue: DispatchQueue(label: "buildsight.connectivity"))
    }

    func stop() { monitor.cancel() }
}
