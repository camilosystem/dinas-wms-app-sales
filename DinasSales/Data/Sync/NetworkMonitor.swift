import Foundation
import Network
import os

/// Observa la conectividad, **solo para informar** (banner "sin conexión").
///
/// Decisión de producto: la sincronización es SIEMPRE manual, disparada por el vendedor.
/// El monitor NO dispara sync al reconectar — el vendedor necesita control y certeza de
/// qué se sincronizó y cuándo. Aquí no hay ningún efecto secundario más allá de publicar
/// `isOnline`.
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.dinas.sales.network")

    /// `autoStart: false` en tests, para dirigir el estado con `handle(online:)`.
    init(autoStart: Bool = true) {
        guard autoStart else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.handle(online: online) }
        }
        monitor.start(queue: queue)
    }

    /// Actualiza el estado de conectividad. Solo publica `isOnline`; sin más efectos.
    /// Interno para poder simular transiciones en tests.
    func handle(online: Bool) {
        isOnline = online
        AppLog.network.debug("red \(online ? "online" : "offline", privacy: .public)")
    }

    deinit {
        monitor.cancel()
    }
}
