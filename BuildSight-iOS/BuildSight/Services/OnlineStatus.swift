import Foundation
import Network

/// Live "is there a connection" flag for screens that need one (sign-in). A hint only: a connected
/// phone can still fail to reach the server, so real request errors are still shown as they happen.
@MainActor
final class OnlineStatus: ObservableObject {
    @Published private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "buildsight.online-status"))
    }

    deinit { monitor.cancel() }
}
