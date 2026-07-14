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
    /// Resultado legible de la última sincronización (éxito o error). El vendedor SIEMPRE
    /// ve qué pasó: cuántas órdenes se enviaron, cuántas quedaron pendientes, o el error.
    @Published private(set) var feedback: SyncFeedback?
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
            let pendingBefore = (try? ordersRepo.confirmedOrders().count) ?? 0
            let failed = try await pushConfirmedOrders()
            try await pullCatalog()
            try await pullClients()
            recordSyncSuccess()
            let uploaded = max(0, pendingBefore - failed)
            feedback = Self.makeFeedback(uploaded: uploaded, failed: failed)
            AppLog.sync.info("sync completada: \(uploaded, privacy: .public) enviada(s), \(failed, privacy: .public) pendiente(s)")
        } catch APIError.unauthorized {
            AppLog.sync.warning("sync: 401 no autorizado → re-login")
            onUnauthorized()
            feedback = SyncFeedback(
                message: "Tu sesión expiró. Reconéctate para sincronizar; tus órdenes siguen guardadas.",
                isError: true
            )
        } catch {
            AppLog.sync.error("sync falló: \(String(describing: error), privacy: .public)")
            feedback = SyncFeedback(
                message: "No se pudo sincronizar. Tus órdenes siguen guardadas; reintenta cuando tengas señal.",
                isError: true
            )
        }
    }

    /// Construye el mensaje de resultado de una sincronización con subida.
    private static func makeFeedback(uploaded: Int, failed: Int) -> SyncFeedback {
        if failed > 0 {
            let prefix = uploaded == 0
                ? "No se pudo enviar ninguna orden"
                : "\(uploaded) orden(es) enviada(s), \(failed) sin enviar"
            return SyncFeedback(
                message: "\(prefix). Las pendientes siguen guardadas; reintenta.",
                isError: true
            )
        }
        if uploaded > 0 {
            return SyncFeedback(message: "Se enviaron \(uploaded) orden(es). Datos actualizados.",
                                isError: false)
        }
        return SyncFeedback(message: "Datos actualizados.", isError: false)
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
            feedback = SyncFeedback(message: "Datos actualizados.", isError: false)
            AppLog.sync.info("bajada completada")
        } catch APIError.unauthorized {
            AppLog.sync.warning("bajada: 401 no autorizado → re-login")
            onUnauthorized()
            feedback = SyncFeedback(message: "Tu sesión expiró. Reconéctate para sincronizar.",
                                    isError: true)
        } catch {
            AppLog.sync.error("bajada falló: \(String(describing: error), privacy: .public)")
            feedback = SyncFeedback(message: "No se pudo sincronizar. Revisa la conexión.",
                                    isError: true)
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
        feedback = nil
        return true
    }

    private func endSync() {
        isSyncing = false
    }

    // MARK: - Subida

    /// Sube todas las órdenes confirmadas y las marca sincronizadas. Devuelve cuántas
    /// fallaron por causas TRANSITORIAS (red/timeout/5xx) — esas se reintentan. Un error
    /// PERMANENTE (400/404) marca la orden como rechazada y deja de reintentarla. Un 401
    /// se propaga para forzar re-login. El reintento es idempotente por `client_uuid`.
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
                                    orderNumber: accepted.orderNumber,
                                    creditVerdict: accepted.status.flatMap(CreditVerdict.init(rawValue:)),
                                    holdReason: accepted.holdReason.flatMap(HoldReason.init(rawValue:)))
                AppLog.sync.info("orden \(order.clientUUID, privacy: .public) sincronizada")
            } catch APIError.unauthorized {
                throw APIError.unauthorized   // token expirado → detener y re-login
            } catch let error as APIError where error.isPermanent {
                rejectOrder(order, error: error, repo: repo)   // 400/404: no se reintenta
            } catch {
                failed += 1                   // transitorio: se reintenta (mismo UUID)
                AppLog.sync.error("orden \(order.clientUUID, privacy: .public) no se pudo subir: \(String(describing: error), privacy: .public)")
            }
        }
        return failed
    }

    /// Sube UNA orden confirmada (p. ej. un vencido que el vendedor decide enviar). Viaja
    /// con su `taken_at` original. Un error permanente la marca rechazada. `true` si subió.
    @discardableResult
    func pushOrder(_ order: Order) async -> Bool {
        let repo = ordersRepo
        do {
            let lines = try repo.lines(orderUUID: order.clientUUID)
            let accepted = try await api.postOrder(order, lines: lines)
            try repo.markSynced(orderUUID: order.clientUUID, orderNumber: accepted.orderNumber,
                                creditVerdict: accepted.status.flatMap(CreditVerdict.init(rawValue:)),
                                holdReason: accepted.holdReason.flatMap(HoldReason.init(rawValue:)))
            AppLog.sync.info("orden \(order.clientUUID, privacy: .public) enviada (individual)")
            return true
        } catch let error as APIError where error.isPermanent {
            rejectOrder(order, error: error, repo: repo)
            return false
        } catch {
            AppLog.sync.error("orden \(order.clientUUID, privacy: .public) no se pudo enviar: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Marca una orden como rechazada con el motivo del servidor (o uno genérico).
    private func rejectOrder(_ order: Order, error: APIError, repo: OrdersRepository) {
        let reason = error.serverMessage ?? "El servidor rechazó la orden (\(error.serverStatus))."
        try? repo.markRejected(orderUUID: order.clientUUID, reason: reason)
        AppLog.sync.error("orden \(order.clientUUID, privacy: .public) RECHAZADA: \(reason, privacy: .public)")
    }

    /// Borra las marcas de agua para que el PRÓXIMO sync baje el set COMPLETO (sin `since`)
    /// y lo reconcilie. Se llama al hacer login online (el vendedor pudo cambiar).
    func resetWatermarks() {
        try? database.dbQueue.write { db in
            _ = try SyncState.deleteAll(db)
        }
        AppLog.sync.info("marcas de sync reseteadas (próxima bajada será completa)")
    }

    // MARK: - Bajada

    /// Descarga el catálogo. Con `since` (delta) hace upsert; sin `since` (bajada COMPLETA)
    /// reconcilia: quita los ítems que ya no están en el servidor, salvo los referenciados
    /// por órdenes locales (esos se conservan marcados `active = false`).
    func pullCatalog() async throws {
        let since = try watermark(for: "catalog")
        let page = try await api.fetchCatalog(since: since)
        try await database.dbQueue.write { db in
            for item in page.items {
                try item.save(db)   // insert o update por PK (item_code)
            }
            if since == nil {
                try Self.reconcileItems(db, returned: Set(page.items.map(\.itemCode)))
            }
            try SyncState(resource: "catalog", lastSyncedAt: page.serverTime).save(db)
        }
        AppLog.sync.info("catálogo: \(page.items.count, privacy: .public) ítem(s) actualizados")
    }

    /// Descarga los clientes asignados. Igual que el catálogo: delta = upsert; completo =
    /// reconcilia (nunca borra un cliente con órdenes locales; lo marca `active = false`).
    func pullClients() async throws {
        let since = try watermark(for: "clients")
        let page = try await api.fetchClients(since: since)
        try await database.dbQueue.write { db in
            for client in page.clients {
                try client.save(db)
            }
            if since == nil {
                try Self.reconcileClients(db, returned: Set(page.clients.map(\.clientCode)))
            }
            try SyncState(resource: "clients", lastSyncedAt: page.serverTime).save(db)
        }
        AppLog.sync.info("clientes: \(page.clients.count, privacy: .public) actualizados")
    }

    /// Ítems locales que ya no vienen del servidor: se borran, salvo los que tengan líneas
    /// en órdenes locales (se conservan marcados inactivos). Nunca se pierde una transacción.
    nonisolated static func reconcileItems(_ db: Database, returned: Set<String>) throws {
        for item in try Item.fetchAll(db) where !returned.contains(item.itemCode) {
            let referenced = try OrderLine
                .filter(Column("item_code") == item.itemCode).fetchCount(db) > 0
            if referenced {
                var kept = item
                kept.active = false
                try kept.update(db)
            } else {
                try item.delete(db)
            }
        }
    }

    /// Clientes locales que ya no vienen del servidor: se borran, salvo los que tengan
    /// órdenes locales (se conservan marcados inactivos, con la orden visible/enviable).
    nonisolated static func reconcileClients(_ db: Database, returned: Set<String>) throws {
        for client in try Client.fetchAll(db) where !returned.contains(client.clientCode) {
            let referenced = try Order
                .filter(Column("client_code") == client.clientCode).fetchCount(db) > 0
            if referenced {
                var kept = client
                kept.active = false
                try kept.update(db)
            } else {
                try client.delete(db)
            }
        }
    }

    /// Marca de agua (`since`) guardada para un recurso, o `nil` en la primera bajada.
    private func watermark(for resource: String) throws -> Date? {
        try database.dbQueue.read { db in
            try SyncState.fetchOne(db, key: resource)?.lastSyncedAt
        }
    }
}

/// Resultado legible de una sincronización, para mostrarle al vendedor.
struct SyncFeedback: Equatable {
    let message: String
    let isError: Bool
}
