import XCTest
import GRDB
@testable import DinasSales

/// Stub de la bajada: devuelve páginas fijas y registra el `since` recibido.
private final class StubSyncDownAPI: SyncDownAPI {
    var catalog: CatalogPage
    var clients: ClientsPage
    private(set) var lastCatalogSince: Date??
    private(set) var lastClientsSince: Date??

    init(catalog: CatalogPage, clients: ClientsPage) {
        self.catalog = catalog
        self.clients = clients
    }

    func fetchCatalog(since: Date?) async throws -> CatalogPage {
        lastCatalogSince = since
        return catalog
    }

    func fetchClients(since: Date?) async throws -> ClientsPage {
        lastClientsSince = since
        return clients
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
        let api = StubSyncDownAPI(
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
        let api = StubSyncDownAPI(
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
        let api = StubSyncDownAPI(
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
}
