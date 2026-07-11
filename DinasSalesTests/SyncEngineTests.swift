import XCTest
import GRDB
@testable import DinasSales

/// Stub de sincronización: devuelve páginas fijas, registra el `since` recibido y
/// captura las órdenes subidas.
private final class StubSyncAPI: SyncDownAPI, SyncUpAPI {
    var catalog: CatalogPage
    var clients: ClientsPage
    private(set) var lastCatalogSince: Date??
    private(set) var lastClientsSince: Date??

    /// UUIDs de órdenes que recibió `postOrder` (para verificar reintentos).
    private(set) var postedUUIDs: [String] = []
    /// Si es no-nil, `postOrder` lanza ese error.
    var postError: Error?
    /// Si es no-nil, `fetchCatalog`/`fetchClients` lanzan ese error.
    var fetchError: Error?

    init(catalog: CatalogPage = CatalogPage(items: [], serverTime: Date(timeIntervalSince1970: 0)),
         clients: ClientsPage = ClientsPage(clients: [], serverTime: Date(timeIntervalSince1970: 0))) {
        self.catalog = catalog
        self.clients = clients
    }

    func fetchCatalog(since: Date?) async throws -> CatalogPage {
        if let fetchError { throw fetchError }
        lastCatalogSince = since
        return catalog
    }

    func fetchClients(since: Date?) async throws -> ClientsPage {
        if let fetchError { throw fetchError }
        lastClientsSince = since
        return clients
    }

    func postOrder(_ order: Order, lines: [OrderLine]) async throws -> OrderAcceptedDTO {
        if let postError { throw postError }
        postedUUIDs.append(order.clientUUID)
        return OrderAcceptedDTO(clientUUID: order.clientUUID, orderNumber: "N-\(postedUUIDs.count)",
                                status: "SINCRONIZADA", receivedAt: nil)
    }
}

@MainActor
final class SyncEngineTests: XCTestCase {

    private func makeItem(_ code: String, available: Double, active: Bool = true) -> Item {
        Item(itemCode: code, name: "Item \(code)", category: nil, barcode: nil,
             comments: nil, price: nil, stock: nil, available: available,
             imageURL: nil, active: active)
    }

    func test_pullCatalog_persisteItemsYGuardaMarcaDeAgua() async throws {
        let db = try AppDatabase.makeInMemory()
        let serverTime = Date(timeIntervalSince1970: 1_000)
        let api = StubSyncAPI(
            catalog: CatalogPage(items: [makeItem("A", available: 5),
                                         makeItem("B", available: 0)],
                                 serverTime: serverTime),
            clients: ClientsPage(clients: [], serverTime: serverTime)
        )
        let engine = SyncEngine(database: db, api: api)

        try await engine.pullCatalog()

        try await db.dbQueue.read { db in
            XCTAssertEqual(try Item.fetchCount(db), 2)
            XCTAssertEqual(try Item.fetchOne(db, key: "A")?.available, 5)
            let mark = try SyncState.fetchOne(db, key: "catalog")?.lastSyncedAt
            XCTAssertEqual(mark, serverTime)
        }
        // Primera bajada: since era nil.
        XCTAssertEqual(api.lastCatalogSince, .some(nil))
    }

    func test_pullCatalog_upsert_actualizaExistentesYReenviaSince() async throws {
        let db = try AppDatabase.makeInMemory()
        let t1 = Date(timeIntervalSince1970: 1_000)
        let api = StubSyncAPI(
            catalog: CatalogPage(items: [makeItem("A", available: 5)], serverTime: t1),
            clients: ClientsPage(clients: [], serverTime: t1)
        )
        let engine = SyncEngine(database: db, api: api)
        try await engine.pullCatalog()

        // Segunda bajada: el mismo item cambia su disponible; nuevo server_time.
        let t2 = Date(timeIntervalSince1970: 2_000)
        api.catalog = CatalogPage(items: [makeItem("A", available: 99)], serverTime: t2)
        try await engine.pullCatalog()

        try await db.dbQueue.read { db in
            XCTAssertEqual(try Item.fetchCount(db), 1, "upsert, no duplica")
            XCTAssertEqual(try Item.fetchOne(db, key: "A")?.available, 99)
            XCTAssertEqual(try SyncState.fetchOne(db, key: "catalog")?.lastSyncedAt, t2)
        }
        // La segunda llamada reenvía la marca de la primera como `since`.
        XCTAssertEqual(api.lastCatalogSince, .some(t1))
    }

    func test_pullClients_persisteClientes() async throws {
        let db = try AppDatabase.makeInMemory()
        let t = Date(timeIntervalSince1970: 500)
        let cliente = Client(clientCode: "C1", name: "Tienda", address: "Calle 1",
                             city: "Ciudad", zipcode: "0000", managerName: "Ana",
                             shippingRoute: "R1")
        let api = StubSyncAPI(
            catalog: CatalogPage(items: [], serverTime: t),
            clients: ClientsPage(clients: [cliente], serverTime: t)
        )
        let engine = SyncEngine(database: db, api: api)

        try await engine.pullClients()

        try await db.dbQueue.read { db in
            XCTAssertEqual(try Client.fetchOne(db, key: "C1")?.name, "Tienda")
            XCTAssertEqual(try SyncState.fetchOne(db, key: "clients")?.lastSyncedAt, t)
        }
    }

    // MARK: - Subida

    /// Crea una orden confirmada lista para subir. Devuelve su UUID.
    private func seedConfirmedOrder(_ db: AppDatabase, uuid: String) throws {
        let repo = OrdersRepository(database: db,
                                    now: { Date(timeIntervalSince1970: 0) },
                                    makeUUID: { uuid })
        try db.dbQueue.write { database in
            try Client(clientCode: "C1", name: "Tienda", address: nil, city: nil,
                       zipcode: nil, managerName: nil, shippingRoute: nil).insert(database)
            try Item(itemCode: "I1", name: "Item", category: nil, barcode: nil, comments: nil,
                     price: 10, stock: nil, available: 5, imageURL: nil, active: true).insert(database)
        }
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", quantity: 2)
        try repo.confirm(orderUUID: order.clientUUID)
    }

    func test_push_subeConfirmadasYMarcaSincronizada() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedConfirmedOrder(db, uuid: "ORD-1")
        let api = StubSyncAPI()
        let engine = SyncEngine(database: db, api: api)

        let failed = try await engine.pushConfirmedOrders()

        XCTAssertEqual(failed, 0)
        XCTAssertEqual(api.postedUUIDs, ["ORD-1"])
        let order = try await db.dbQueue.read { try Order.fetchOne($0, key: "ORD-1") }
        XCTAssertEqual(order?.status, .synced)
        XCTAssertEqual(order?.orderNumber, "N-1")
    }

    func test_push_esIdempotente_noReenviaYaSincronizadas() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedConfirmedOrder(db, uuid: "ORD-1")
        let api = StubSyncAPI()
        let engine = SyncEngine(database: db, api: api)

        _ = try await engine.pushConfirmedOrders()          // 1ª subida
        _ = try await engine.pushConfirmedOrders()          // 2ª: ya está sincronizada

        // El mismo UUID no se reenvía: solo una llamada a postOrder.
        XCTAssertEqual(api.postedUUIDs, ["ORD-1"])
    }

    func test_push_fallo_dejaConfirmadaParaReintento() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedConfirmedOrder(db, uuid: "ORD-1")
        let api = StubSyncAPI()
        api.postError = APIError.server(status: 500)
        let engine = SyncEngine(database: db, api: api)

        let failed = try await engine.pushConfirmedOrders()

        XCTAssertEqual(failed, 1)
        let order = try await db.dbQueue.read { try Order.fetchOne($0, key: "ORD-1") }
        XCTAssertEqual(order?.status, .confirmed, "sigue confirmada para reintentar")

        // Al recuperar red, el reintento la sube (mismo UUID).
        api.postError = nil
        let failed2 = try await engine.pushConfirmedOrders()
        XCTAssertEqual(failed2, 0)
        XCTAssertEqual(api.postedUUIDs, ["ORD-1"])
    }

    // MARK: - 401 / sesión expirada

    func test_sync_subida401_llamaOnUnauthorized() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedConfirmedOrder(db, uuid: "ORD-1")
        let api = StubSyncAPI()
        api.postError = APIError.unauthorized
        var expired = false
        let engine = SyncEngine(database: db, api: api, onUnauthorized: { expired = true })

        await engine.sync()

        XCTAssertTrue(expired, "un 401 en la subida debe disparar re-login")
        let order = try await db.dbQueue.read { try Order.fetchOne($0, key: "ORD-1") }
        XCTAssertEqual(order?.status, .confirmed, "no se marca sincronizada con token inválido")
    }

    func test_syncDown_bajada401_llamaOnUnauthorized() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubSyncAPI()
        api.fetchError = APIError.unauthorized
        var expired = false
        let engine = SyncEngine(database: db, api: api, onUnauthorized: { expired = true })

        await engine.syncDown()

        XCTAssertTrue(expired)
    }
}
