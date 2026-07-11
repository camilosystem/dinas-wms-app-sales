import Foundation
import GRDB
import os

/// Motor de sincronización. La sincronización es un evento aparte del uso normal:
/// la app opera offline y sincroniza cuando hay red.
///
/// - Bajada: `GET /sync/catalog` y `GET /sync/clients` (con `since` desde `sync_state`).
/// - Subida: órdenes confirmadas → `POST /orders` (idempotente por `client_uuid`).
@MainActor
final class SyncEngine: ObservableObject {
    private let database: AppDatabase
    private let api: SyncDownAPI & SyncUpAPI
    /// Se invoca cuando el middleware responde 401 (token ausente/expirado) → re-login.
    var onUnauthorized: () -> Void

    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?
    /// Momento (hora del dispositivo) de la última sincronización exitosa. Persistido
    /// para sobrevivir reinicios de la app. `nil` si nunca se sincronizó.
    @Published private(set) var lastSyncedAt: Date?

    private let now: () -> Date
    private let defaults: UserDefaults
    private static let lastSyncKey = "sync.lastSyncedAt"

    init(database: AppDatabase,
         api: SyncDownAPI & SyncUpAPI,
         onUnauthorized: @escaping () -> Void = {},
         now: @escaping () -> Date = Date.init,
         defaults: UserDefaults = .standard) {
        self.database = database
        self.api = api
        self.onUnauthorized = onUnauthorized
        self.now = now
        self.defaults = defaults
        self.lastSyncedAt = defaults.object(forKey: Self.lastSyncKey) as? Date
    }

    /// Registra una sincronización exitosa (actualiza y persiste el timestamp).
    private func recordSyncSuccess() {
        let timestamp = now()
        lastSyncedAt = timestamp
        defaults.set(timestamp, forKey: Self.lastSyncKey)
    }

    private var ordersRepo: OrdersRepository { OrdersRepository(database: database) }

    /// Sincronización completa: sube órdenes confirmadas y baja catálogo + clientes.
    /// Sube primero para no perder trabajo del vendedor si la bajada falla.
    /// Si ya hay una sincronización en curso, no hace nada (evita subidas duplicadas
    /// por, p. ej., el botón manual y el auto-sync al reconectar disparando a la vez).
    func sync() async {
        guard beginSync() else {
            AppLog.sync.debug("sync ignorada: ya hay una en curso")
            return
        }
        defer { endSync() }

        AppLog.sync.info("sync iniciada")
        do {
            let failedUploads = try await pushConfirmedOrders()
            try await pullCatalog()
            try await pullClients()
            recordSyncSuccess()
            if failedUploads > 0 {
                AppLog.sync.warning("sync completada con \(failedUploads, privacy: .public) orden(es) sin subir")
                lastError = "\(failedUploads) orden(es) sin subir. Se reintentará."
            } else {
                AppLog.sync.info("sync completada")
            }
        } catch APIError.unauthorized {
            AppLog.sync.warning("sync: 401 no autorizado → re-login")
            onUnauthorized()
        } catch {
            AppLog.sync.error("sync falló: \(String(describing: error), privacy: .public)")
            lastError = "No se pudo sincronizar. Revisa la conexión."
        }
    }

    /// Solo bajada (usado por el pull-to-refresh de catálogo/clientes).
    func syncDown() async {
        guard beginSync() else { return }
        defer { endSync() }

        AppLog.sync.info("bajada iniciada")
        do {
            try await pullCatalog()
            try await pullClients()
            recordSyncSuccess()
            AppLog.sync.info("bajada completada")
        } catch APIError.unauthorized {
            AppLog.sync.warning("bajada: 401 no autorizado → re-login")
            onUnauthorized()
        } catch {
            AppLog.sync.error("bajada falló: \(String(describing: error), privacy: .public)")
            lastError = "No se pudo sincronizar. Revisa la conexión."
        }
    }

    /// Reserva el turno de sincronización de forma atómica y devuelve `true` si se
    /// obtuvo. Es la sección crítica del guard anti-concurrencia:
    ///
    /// Al estar aislada en el `@MainActor` y **no contener ningún `await`**, la
    /// comprobación (`guard !isSyncing`) y el seteo (`isSyncing = true`) se ejecutan sin
    /// puntos de suspensión, así que ninguna otra llamada puede entrelazarse entre
    /// ambas. Si ya hay una sync en curso, devuelve `false`. El flag se limpia siempre
    /// con `endSync()` desde un `defer` (incluso si la sync falla o lanza).
    private func beginSync() -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        lastError = nil
        return true
    }

    private func endSync() {
        isSyncing = false
    }

    // MARK: - Subida

    /// Sube todas las órdenes confirmadas y las marca sincronizadas. Devuelve cuántas
    /// fallaron por causas transitorias (red/servidor). El reintento es seguro:
    /// `client_uuid` hace idempotente el `POST /orders` (una orden ya recibida responde
    /// 200 y no se duplica). Un 401 se propaga para forzar re-login.
    @discardableResult
    func pushConfirmedOrders() async throws -> Int {
        let repo = ordersRepo
        let pending = try repo.confirmedOrders()
        if !pending.isEmpty {
            AppLog.sync.info("subiendo \(pending.count, privacy: .public) orden(es) confirmada(s)")
        }

        var failed = 0
        for order in pending {
            do {
                let lines = try repo.lines(orderUUID: order.clientUUID)
                let accepted = try await api.postOrder(order, lines: lines)
                try repo.markSynced(orderUUID: order.clientUUID,
                                    orderNumber: accepted.orderNumber)
                AppLog.sync.info("orden \(order.clientUUID, privacy: .public) sincronizada")
            } catch APIError.unauthorized {
                throw APIError.unauthorized   // token expirado → detener y re-login
            } catch {
                failed += 1                   // transitorio: se reintenta (mismo UUID)
                AppLog.sync.error("orden \(order.clientUUID, privacy: .public) no se pudo subir: \(String(describing: error), privacy: .public)")
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
        AppLog.sync.info("catálogo: \(page.items.count, privacy: .public) ítem(s) actualizados")
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
        AppLog.sync.info("clientes: \(page.clients.count, privacy: .public) actualizados")
    }

    /// Marca de agua (`since`) guardada para un recurso, o `nil` en la primera bajada.
    private func watermark(for resource: String) throws -> Date? {
        try database.dbQueue.read { db in
            try SyncState.fetchOne(db, key: resource)?.lastSyncedAt
        }
    }
}
