import Foundation
import GRDB

/// Motor de sincronización. La sincronización es un evento aparte del uso normal:
/// la app opera offline y sincroniza cuando hay red.
///
/// - Bajada: `GET /sync/catalog` y `GET /sync/clients` (con `since` desde `sync_state`).
/// - Subida: órdenes confirmadas → `POST /orders` (idempotente por `client_uuid`).
@MainActor
final class SyncEngine: ObservableObject {
    private let database: AppDatabase
    private let api: SyncDownAPI & SyncUpAPI

    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?

    init(database: AppDatabase, api: SyncDownAPI & SyncUpAPI) {
        self.database = database
        self.api = api
    }

    private var ordersRepo: OrdersRepository { OrdersRepository(database: database) }

    /// Sincronización completa: sube órdenes confirmadas y baja catálogo + clientes.
    /// Sube primero para no perder trabajo del vendedor si la bajada falla.
    func sync() async {
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        var problems: [String] = []

        let failedUploads = await pushConfirmedOrders()
        if failedUploads > 0 { problems.append("\(failedUploads) orden(es) sin subir") }

        do {
            try await pullCatalog()
            try await pullClients()
        } catch {
            problems.append("bajada de datos")
        }

        if !problems.isEmpty {
            lastError = "No se completó: " + problems.joined(separator: ", ") + "."
        }
    }

    /// Solo bajada (usado por el pull-to-refresh de catálogo/clientes).
    func syncDown() async {
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }
        do {
            try await pullCatalog()
            try await pullClients()
        } catch {
            lastError = "No se pudo sincronizar. Revisa la conexión."
        }
    }

    // MARK: - Subida

    /// Sube todas las órdenes confirmadas y las marca sincronizadas. Devuelve cuántas
    /// fallaron. El reintento es seguro: `client_uuid` hace idempotente el `POST /orders`
    /// (una orden ya recibida responde 200 y no se duplica).
    @discardableResult
    func pushConfirmedOrders() async -> Int {
        let repo = ordersRepo
        let pending: [Order]
        do {
            pending = try repo.confirmedOrders()
        } catch {
            return 1
        }

        var failed = 0
        for order in pending {
            do {
                let lines = try repo.lines(orderUUID: order.clientUUID)
                let accepted = try await api.postOrder(order, lines: lines)
                try repo.markSynced(orderUUID: order.clientUUID,
                                    orderNumber: accepted.orderNumber)
            } catch {
                failed += 1   // se reintenta en la próxima sync (mismo UUID)
            }
        }
        return failed
    }

    // MARK: - Bajada

    /// Descarga el delta de catálogo desde la última marca y lo persiste (upsert).
    func pullCatalog() async throws {
        let since = try watermark(for: "catalog")
        let page = try await api.fetchCatalog(since: since)
        try await database.dbQueue.write { db in
            for item in page.items {
                try item.save(db)   // insert o update por PK (item_code)
            }
            try SyncState(resource: "catalog", lastSyncedAt: page.serverTime).save(db)
        }
    }

    /// Descarga el delta de clientes asignados y lo persiste (upsert).
    func pullClients() async throws {
        let since = try watermark(for: "clients")
        let page = try await api.fetchClients(since: since)
        try await database.dbQueue.write { db in
            for client in page.clients {
                try client.save(db)
            }
            try SyncState(resource: "clients", lastSyncedAt: page.serverTime).save(db)
        }
    }

    /// Marca de agua (`since`) guardada para un recurso, o `nil` en la primera bajada.
    private func watermark(for resource: String) throws -> Date? {
        try database.dbQueue.read { db in
            try SyncState.fetchOne(db, key: resource)?.lastSyncedAt
        }
    }
}
