// Whether the device has a network path, and what kind. The Mac's sync
// timer skips its rounds while there is none (each used to run into the
// same error every 30 seconds) and runs one the moment the path is back;
// both apps say "Offline" with how many changes are waiting to be sent;
// and bodies are fetched ahead of a click only on a path that is neither
// metered (cellular, a personal hotspot) nor in Low Data Mode.

import Foundation
import Network

@MainActor
@Observable
final class Connectivity {
    static let shared = Connectivity()

    /// True until the system says otherwise: a monitor that has not
    /// reported yet must not hold a sync back.
    private(set) var isOnline = true
    /// Cellular or a personal hotspot, and Low Data Mode: not the paths
    /// to spend on mail nobody asked to open yet.
    @ObservationIgnored private(set) var isExpensive = false
    @ObservationIgnored private(set) var isConstrained = false
    /// Called when the path comes back after being away.
    @ObservationIgnored var onReconnect: (() -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()

    /// Fetching ahead is fine here: online, unmetered, not in Low Data Mode.
    var allowsPrefetch: Bool { isOnline && !isExpensive && !isConstrained }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in self?.update(online: online, expensive: expensive, constrained: constrained) }
        }
        monitor.start(queue: DispatchQueue(label: "app.heypigeon.connectivity", qos: .utility))
    }

    private func update(online: Bool, expensive: Bool, constrained: Bool) {
        isExpensive = expensive
        isConstrained = constrained
        guard online != isOnline else { return }
        isOnline = online
        if online { onReconnect?() }
    }
}
