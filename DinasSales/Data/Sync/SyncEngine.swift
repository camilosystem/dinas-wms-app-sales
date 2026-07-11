import Foundation
import GRDB

/// Motor de sincronización. La sincronización es un evento aparte del uso normal:
/// la app opera offline y sincroniza cuando hay red.
///
/// - Bajada: `GET /sync/catalog` y `GET /sync/clients` (con `since` desde `sync_state`).
/// - Subida: órdenes confirmadas → `POST /orders` (idempotente por `client_uuid`).
///
/// Esqueleto: orquesta el flujo; el detalle de cada paso se completa en el MVP.
@MainActor
final class SyncEngine: ObservableObject {
    private let database: AppDatabase
    private let api: APIClient

    @Published private(set) var isSyncing = false

    init(database: AppDatabase, api: APIClient) {
        self.database = database
        self.api = api
    }

    /// Sincronización completa: bajada (catálogo + clientes) y subida (órdenes confirmadas).
    func syncAll() async throws {
        isSyncing = true
        defer { isSyncing = false }

        try await pullCatalog()
        try await pullClients()
        try await pushConfirmedOrders()
    }

    // MARK: - Bajada

    func pullCatalog() async throws {
        // TODO: leer `since` de sync_state, llamar api.fetchCatalog, upsert en items,
        // actualizar last_synced_at. Las imágenes se descargan aparte.
    }

    func pullClients() async throws {
        // TODO: leer `since` de sync_state, llamar api.fetchClients, upsert en clients,
        // actualizar last_synced_at. Solo clientes asignados.
    }

    // MARK: - Subida

    func pushConfirmedOrders() async throws {
        // TODO: seleccionar orders con status = .confirmed, enviar con api.postOrder
        // (mismo client_uuid en reintentos), y marcar .synced al confirmar el envío.
    }
}
