import Foundation
import Network
import os

/// Observa la conectividad y dispara una acción al RECUPERAR la red (transición
/// offline → online). La app es offline-first; esto solo aprovecha la reconexión
/// para sincronizar sin que el vendedor tenga que pulsar nada.
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline = true
    /// Se invoca al recuperar la conexión (no en el primer estado ni en cada cambio).
    var onReconnect: () -> Void = {}

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.dinas.sales.network")
    private var wasOffline = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.handle(online: online) }
        }
        monitor.start(queue: queue)
    }

    private func handle(online: Bool) {
        let recovered = online && wasOffline
        wasOffline = !online
        isOnline = online
        AppLog.network.debug("red \(online ? "online" : "offline", privacy: .public)")
        if recovered {
            AppLog.network.info("red recuperada → auto-sync")
            onReconnect()
        }
    }

    deinit {
        monitor.cancel()
    }
}
