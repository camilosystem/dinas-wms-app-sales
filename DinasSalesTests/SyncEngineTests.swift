import XCTest
import GRDB
@testable import DinasSales

/// Stub de sincronización: devuelve páginas fijas, registra el `since` recibido y
/// captura las órdenes subidas. Uso secuencial en tests (con `await` entre accesos):
/// `@unchecked Sendable` es seguro aquí.
private final class StubSyncAPI: SyncDownAPI, SyncUpAPI, @unchecked Sendable {
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

/// Servidor simulado que deduplica por `client_uuid` (idempotencia REAL del lado
/// servidor). Puede "perder" la respuesta de una petición que sí procesó.
private final class IdempotentServerStub: SyncDownAPI, SyncUpAPI, @unchecked Sendable {
    /// UUIDs que el servidor persistió (con repetidos si hubiera un bug de dedup).
    private(set) var receivedOrderIDs: [String] = []
    private var orderNumbers: [String: String] = [:]
    /// Si es true, la próxima respuesta se pierde (el servidor SÍ procesó la orden).
    var dropNextResponse = false

    func fetchCatalog(since: Date?) async throws -> CatalogPage {
        CatalogPage(items: [], serverTime: Date(timeIntervalSince1970: 0))
    }
    func fetchClients(since: Date?) async throws -> ClientsPage {
        ClientsPage(clients: [], serverTime: Date(timeIntervalSince1970: 0))
    }

    func postOrder(_ order: Order, lines: [OrderLine]) async throws -> OrderAcceptedDTO {
        // Lado servidor: registrar (y numerar) solo si el UUID es nuevo.
        if orderNumbers[order.clientUUID] == nil {
            receivedOrderIDs.append(order.clientUUID)
            orderNumbers[order.clientUUID] = "N-\(orderNumbers.count + 1)"
        }
        let number = orderNumbers[order.clientUUID]!
        if dropNextResponse {
            dropNextResponse = false
            throw URLError(.networkConnectionLost)   // respuesta perdida tras procesar
        }
        return OrderAcceptedDTO(clientUUID: order.clientUUID, orderNumber: number,
                                status: "SINCRONIZADA", receivedAt: nil)
    }
}

/// Stub con compuerta: `postOrder` se suspende hasta que el test llame `release()`.
/// Permite mantener una sincronización "en vuelo" (con el flag puesto) mientras se
/// dispara una segunda, de forma determinista (sin depender de timings).
private actor GatedUploadAPI: SyncDownAPI, SyncUpAPI {
    private(set) var postCount = 0
    private var entered = false
    private var enteredCont: CheckedContinuation<Void, Never>?
    private var releaseCont: CheckedContinuation<Void, Never>?

    func fetchCatalog(since: Date?) async throws -> CatalogPage {
        CatalogPage(items: [], serverTime: Date(timeIntervalSince1970: 0))
    }
    func fetchClients(since: Date?) async throws -> ClientsPage {
        ClientsPage(clients: [], serverTime: Date(timeIntervalSince1970: 0))
    }

    func postOrder(_ order: Order, lines: [OrderLine]) async throws -> OrderAcceptedDTO {
        postCount += 1
        entered = true
        enteredCont?.resume(); enteredCont = nil
        await withCheckedContinuation { releaseCont = $0 }   // se bloquea hasta release()
        return OrderAcceptedDTO(clientUUID: order.clientUUID, orderNumber: "N-\(postCount)",
                                status: "SINCRONIZADA", receivedAt: nil)
    }

    /// Espera a que `postOrder` haya sido invocado (la 1ª sync está dentro y con flag).
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredCont = $0 }
    }

    func release() { releaseCont?.resume(); releaseCont = nil }
    func posts() -> Int { postCount }
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
    private func seedConfirmedOrder(_ db: AppDatabase, uuid: String, price: Double = 10) throws {
        let repo = OrdersRepository(database: db,
                                    now: { Date(timeIntervalSince1970: 0) },
                                    makeUUID: { uuid })
        try db.dbQueue.write { database in
            try Client(clientCode: "C1", name: "Tienda", address: nil, city: nil,
                       zipcode: nil, managerName: nil, shippingRoute: nil).insert(database)
            try Item(itemCode: "I1", name: "Item", category: nil, barcode: nil, comments: nil,
                     price: price, stock: nil, available: 5, imageURL: nil, active: true).insert(database)
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

    func test_push_ordenTotalCero_seEnviaYMarcaSincronizada() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedConfirmedOrder(db, uuid: "ORD-0", price: 0)   // línea a unit_price = 0
        let api = StubSyncAPI()
        let engine = SyncEngine(database: db, api: api)

        let failed = try await engine.pushConfirmedOrders()

        XCTAssertEqual(failed, 0)
        XCTAssertEqual(api.postedUUIDs, ["ORD-0"], "la orden a total cero se envía igual")
        let order = try await db.dbQueue.read { try Order.fetchOne($0, key: "ORD-0") }
        XCTAssertEqual(order?.status, .synced)
    }

    // MARK: - Idempotencia end-to-end (servidor simulado)

    /// Escenario A: el servidor procesa la orden, pero la respuesta se pierde. El
    /// reintento usa el MISMO client_uuid y el servidor NO crea un duplicado.
    func test_push_respuestaPerdida_reintentoNoDuplicaEnServidor() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedConfirmedOrder(db, uuid: "ORD-1")
        let server = IdempotentServerStub()
        server.dropNextResponse = true                 // la 1ª respuesta se pierde en la red
        let engine = SyncEngine(database: db, api: server)

        // 1er intento: el servidor la registra, pero el cliente no recibe respuesta.
        let failed1 = try await engine.pushConfirmedOrders()
        XCTAssertEqual(failed1, 1)
        let after1 = try await db.dbQueue.read { try Order.fetchOne($0, key: "ORD-1") }
        XCTAssertEqual(after1?.status, .confirmed, "sigue pendiente → reintentará")

        // 2º intento (reintento con el mismo UUID): el servidor responde sin duplicar.
        let failed2 = try await engine.pushConfirmedOrders()
        XCTAssertEqual(failed2, 0)
        XCTAssertEqual(server.receivedOrderIDs, ["ORD-1"],
                       "el servidor registró la orden UNA sola vez")
        let after2 = try await db.dbQueue.read { try Order.fetchOne($0, key: "ORD-1") }
        XCTAssertEqual(after2?.status, .synced)
        XCTAssertEqual(after2?.orderNumber, "N-1")
    }

    /// Escenario B: la app confirma la orden (persistida con su UUID) y se cierra antes
    /// de recibir respuesta. Al reabrir, una instancia NUEVA del motor reintenta con el
    /// mismo UUID persistido; no genera uno nuevo.
    func test_push_trasCrash_reusaMismoUUIDPersistido() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedConfirmedOrder(db, uuid: "ORD-1")      // confirmada y persistida (pre-crash)

        // "Reapertura": motor y servidor nuevos, misma base local.
        let server = IdempotentServerStub()
        let engine = SyncEngine(database: db, api: server)

        let failed = try await engine.pushConfirmedOrders()

        XCTAssertEqual(failed, 0)
        XCTAssertEqual(server.receivedOrderIDs, ["ORD-1"],
                       "reusa el UUID persistido, no genera uno nuevo")
        let order = try await db.dbQueue.read { try Order.fetchOne($0, key: "ORD-1") }
        XCTAssertEqual(order?.status, .synced)
    }

    // MARK: - Guard anti-concurrencia

    /// Dos `sync()` concurrentes: solo uno ejecuta la subida; el segundo retorna sin
    /// hacer peticiones mientras el primero sigue en vuelo.
    func test_sync_concurrente_soloUnoEjecuta() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedConfirmedOrder(db, uuid: "ORD-1")
        let api = GatedUploadAPI()
        let engine = SyncEngine(database: db, api: api)

        // A: primera sync. Se suspende dentro de postOrder con isSyncing = true.
        let first = Task { await engine.sync() }
        await api.waitUntilEntered()
        XCTAssertTrue(engine.isSyncing, "la primera sync está en curso")

        // B: segunda sync mientras A sigue en vuelo → el guard la descarta.
        await engine.sync()

        // Solo A hizo la petición (B no llamó a postOrder).
        let postsMientrasEnVuelo = await api.posts()
        XCTAssertEqual(postsMientrasEnVuelo, 1, "el segundo sync no hizo peticiones")

        // Libera A y espera a que termine.
        await api.release()
        await first.value

        let postsTotales = await api.posts()
        XCTAssertEqual(postsTotales, 1, "en total, una sola subida")
        let order = try await db.dbQueue.read { try Order.fetchOne($0, key: "ORD-1") }
        XCTAssertEqual(order?.status, .synced)
        XCTAssertFalse(engine.isSyncing, "el flag se limpió al terminar")
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

    // MARK: - Última sincronización

    private func freshDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func test_syncExitosa_registraLastSyncedAt() async throws {
        let db = try AppDatabase.makeInMemory()
        let fixed = Date(timeIntervalSince1970: 5_000)
        let engine = SyncEngine(database: db, api: StubSyncAPI(),
                                now: { fixed },
                                defaults: freshDefaults("test.lastsync.ok"))
        XCTAssertNil(engine.lastSyncedAt)

        await engine.syncDown()

        XCTAssertEqual(engine.lastSyncedAt, fixed)
    }

    func test_syncFallida_noRegistraLastSyncedAt() async throws {
        let db = try AppDatabase.makeInMemory()
        let api = StubSyncAPI()
        api.fetchError = APIError.server(status: 500)
        let engine = SyncEngine(database: db, api: api,
                                now: { Date(timeIntervalSince1970: 1) },
                                defaults: freshDefaults("test.lastsync.fail"))

        await engine.syncDown()

        XCTAssertNil(engine.lastSyncedAt, "una bajada fallida no actualiza el timestamp")
    }

    func test_lastSyncedAt_seCargaDeDefaultsAlIniciar() throws {
        let db = try AppDatabase.makeInMemory()
        let defaults = freshDefaults("test.lastsync.persist")
        let previo = Date(timeIntervalSince1970: 9_999)
        defaults.set(previo, forKey: "sync.lastSyncedAt")

        let engine = SyncEngine(database: db, api: StubSyncAPI(), defaults: defaults)

        XCTAssertEqual(engine.lastSyncedAt, previo, "sobrevive reinicios de la app")
    }

    // MARK: - Sync siempre manual

    /// Decisión de producto: recuperar la red NO dispara sincronización automática.
    /// El monitor es solo informativo; nadie lo conecta al motor de sync.
    func test_reconexionDeRed_noDisparaSyncAutomatico() async throws {
        let db = try AppDatabase.makeInMemory()
        try seedConfirmedOrder(db, uuid: "ORD-1")     // hay una orden pendiente de subir
        let api = StubSyncAPI()
        let engine = SyncEngine(database: db, api: api)   // el motor existe; nadie lo dispara
        let monitor = NetworkMonitor(autoStart: false)    // dirigimos el estado a mano

        // Simula: se pierde la red y luego se recupera.
        monitor.handle(online: false)
        XCTAssertFalse(monitor.isOnline)
        monitor.handle(online: true)
        XCTAssertTrue(monitor.isOnline)

        // La reconexión es solo informativa: NO debe iniciar ninguna sincronización.
        XCTAssertEqual(api.postedUUIDs, [], "la reconexión no sube órdenes")
        XCTAssertNil(api.lastCatalogSince, "la reconexión no baja catálogo")
        XCTAssertFalse(engine.isSyncing)
        XCTAssertNil(engine.feedback, "no hubo sincronización, no hay feedback")
    }
}
