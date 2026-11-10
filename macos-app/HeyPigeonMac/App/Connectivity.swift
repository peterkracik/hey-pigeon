// Whether the Mac has a network path. The sync timer skips its rounds
// while there is none (each used to run into the same error every 30
// seconds) and runs one the moment the path is back; the toolbar says
// "Offline" with how many changes are waiting to be sent.

import Foundation
import Network

@MainActor
@Observable
final class Connectivity {
    static let shared = Connectivity()

    /// True until the system says otherwise: a monitor that has not
    /// reported yet must not hold a sync back.
    private(set) var isOnline = true
    /// Called when the path comes back after being away.
    @ObservationIgnored var onReconnect: (() -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "app.heypigeon.connectivity", qos: .utility))
    }

    private func update(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        if online { onReconnect?() }
    }
}
