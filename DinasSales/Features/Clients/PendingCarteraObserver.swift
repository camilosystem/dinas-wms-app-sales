import Foundation
import GRDB

/// Cuenta reactiva de movimientos de cartera **en cola pendientes de subir** (pagos y solicitudes
/// de crédito `queued`), para avisar en Home que hay algo sin sincronizar — igual que
/// `PendingOrdersObserver` con las órdenes. Se actualiza sola al reportar/encolar o al sincronizar.
@MainActor
final class PendingCarteraObserver: ObservableObject {
    @Published private(set) var paymentsCount = 0
    @Published private(set) var creditsCount = 0

    var total: Int { paymentsCount + creditsCount }

    private let database: AppDatabase
    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase) {
        self.database = database
        start()
    }

    /// Reinicia la observación sobre la cola ACTUAL (★ tras reabrir por cambio de usuario).
    func restart() { start() }

    private func start() {
        cancellable?.cancel()
        paymentsCount = 0
        creditsCount = 0
        let queued = QueueSyncStatus.queued.rawValue
        let observation = ValueObservation.tracking { db -> [Int] in
            [try AccountPayment.filter(Column("sync_status") == queued).fetchCount(db),
             try CreditRequest.filter(Column("sync_status") == queued).fetchCount(db)]
        }
        cancellable = observation.start(
            in: database.dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { _ in },
            onChange: { [weak self] counts in
                self?.paymentsCount = counts[0]
                self?.creditsCount = counts[1]
            }
        )
    }
}
