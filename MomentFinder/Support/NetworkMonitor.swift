import Foundation
import Network

final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var expensive = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            expensive = path.isExpensive || path.isConstrained
            lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "MomentFinder.NetworkMonitor"))
    }

    deinit {
        monitor.cancel()
    }

    var isExpensive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expensive
    }
}
