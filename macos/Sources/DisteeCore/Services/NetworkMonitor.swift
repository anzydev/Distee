import Foundation
import Network

/// `NWPathMonitor` wrapper. The only place Network.framework is used: WebSockets go
/// through `URLSessionWebSocketTask` per Phase 1, but path changes are the cheapest
/// reliable signal for "reconnect now".
public final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.distee.network-monitor")
    private let lock = NSLock()
    private var started = false

    /// Called with `true` when a usable path appears.
    public var onPathChange: ((Bool) -> Void)?

    public init() {}

    public var isSatisfied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return monitor.currentPath.status == .satisfied
    }

    public func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            self?.onPathChange?(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        guard started else { lock.unlock(); return }
        started = false
        lock.unlock()
        monitor.cancel()
    }
}
