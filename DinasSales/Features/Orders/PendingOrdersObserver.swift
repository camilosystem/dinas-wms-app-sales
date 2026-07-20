import Foundation
import GRDB

/// Cuenta reactiva de órdenes **confirmadas pendientes de subir**, para el badge de la
/// pestaña Órdenes. Se actualiza sola cuando se confirma o se sincroniza una orden.
@MainActor
final class PendingOrdersObserver: ObservableObject {
    @Published private(set) var count = 0

    private let database: AppDatabase
    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase) {
        self.database = database
        start()
    }

    /// Reinicia la observación sobre la cola ACTUAL de la base (★ tras reabrir por cambio de
    /// usuario: la cola vieja se descarta y se observa el archivo del usuario nuevo).
    func restart() { start() }

    private func start() {
        cancellable?.cancel()
        count = 0
        let observation = ValueObservation.tracking { db in
            try Order
                .filter(Column("status") == OrderStatus.confirmed.rawValue)
                .fetchCount(db)
        }
        cancellable = observation.start(
            in: database.dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { _ in },
            onChange: { [weak self] newCount in
                self?.count = newCount
            }
        )
    }
}
