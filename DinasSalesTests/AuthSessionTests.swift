import XCTest
@testable import DinasSales

/// Stub de la API de auth: no toca la red.
private struct StubAuthAPI: AuthAPI {
    var result: Result<LoginResponse, APIError>

    init(result: Result<LoginResponse, APIError>) { self.result = result }

    /// Atajo: éxito con token (y opcionalmente displayName).
    init(token: String, displayName: String? = nil) {
        self.result = .success(LoginResponse(token: token, salespersonCode: nil,
                                             displayName: displayName))
    }

    func login(username: String, password: String) async throws -> LoginResponse {
        try result.get()
    }
}

private func sampleSession(username: String = "vendedor1") -> StoredSession {
    StoredSession(token: "jwt-previo", username: username, displayName: "Vendedor Uno",
                  salespersonCode: "V1", lastOnlineLoginAt: Date(timeIntervalSince1970: 0))
}

@MainActor
final class AuthSessionTests: XCTestCase {

    // MARK: - Restore

    func test_restore_sinSesion_quedaSignedOut() {
        let auth = AuthSession(api: StubAuthAPI(token: "t"), store: InMemorySessionStore())
        auth.restore()
        XCTAssertEqual(auth.state, .signedOut)
    }

    func test_restore_conSesion_entra_offlineCapable() {
        let auth = AuthSession(api: StubAuthAPI(token: "t"),
                               store: InMemorySessionStore(session: sampleSession()))
        auth.restore()
        XCTAssertEqual(auth.state, .signedIn)
        XCTAssertEqual(auth.displayName, "Vendedor Uno")
    }

    // MARK: - Login online

    func test_login_online_exitoso_guardaSesion() async throws {
        let store = InMemorySessionStore()
        let auth = AuthSession(api: StubAuthAPI(token: "jwt-123", displayName: "Ana"),
                               store: store, now: { Date(timeIntervalSince1970: 100) })

        await auth.login(username: "vendedor1", password: "secreta", isOnline: true)

        XCTAssertEqual(auth.state, .signedIn)
        XCTAssertNil(auth.loginFailure)
        let saved = try store.read()
        XCTAssertEqual(saved?.token, "jwt-123")
        XCTAssertEqual(saved?.username, "vendedor1")
        XCTAssertEqual(saved?.lastOnlineLoginAt, Date(timeIntervalSince1970: 100))
    }

    func test_login_online_credencialesIncorrectas_mensajeExplicito() async throws {
        let store = InMemorySessionStore()
        let auth = AuthSession(api: StubAuthAPI(result: .failure(.unauthorized)), store: store)
        auth.restore()

        await auth.login(username: "vendedor1", password: "mala", isOnline: true)

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertEqual(auth.loginFailure, .badCredentials)
        XCTAssertEqual(auth.errorMessage, "Usuario o contraseña incorrectos.")
        XCTAssertNil(try store.read())
    }

    func test_login_online_errorDeServidor_distinguido() async throws {
        let auth = AuthSession(api: StubAuthAPI(result: .failure(.server(status: 500))),
                               store: InMemorySessionStore())
        auth.restore()
        await auth.login(username: "vendedor1", password: "x", isOnline: true)
        XCTAssertEqual(auth.loginFailure, .serverError)
        XCTAssertEqual(auth.state, .signedOut)
    }

    // MARK: - Login offline

    func test_login_offline_sinSesionPrevia_noEntra() async throws {
        let auth = AuthSession(api: StubAuthAPI(token: "t"), store: InMemorySessionStore())
        auth.restore()

        await auth.login(username: "vendedor1", password: "x", isOnline: false)

        XCTAssertEqual(auth.state, .signedOut, "primer login offline: no hay nada que mostrar")
        XCTAssertEqual(auth.loginFailure, .offlineNoSession)
        XCTAssertEqual(auth.errorMessage,
                       "Sin conexión. La primera vez necesitas conexión para iniciar sesión.")
    }

    func test_login_offline_conSesionPrevia_entra() async throws {
        let auth = AuthSession(api: StubAuthAPI(token: "t"),
                               store: InMemorySessionStore(session: sampleSession()))

        await auth.login(username: "vendedor1", password: "x", isOnline: false)

        XCTAssertEqual(auth.state, .signedIn)
        XCTAssertNil(auth.loginFailure)
        XCTAssertEqual(auth.displayName, "Vendedor Uno")
    }

    // MARK: - Sesión expirada (401) y logout

    func test_sessionExpired_mantieneAccesoOffline() {
        let store = InMemorySessionStore(session: sampleSession())
        let auth = AuthSession(api: StubAuthAPI(token: "x"), store: store)
        auth.restore()
        XCTAssertEqual(auth.state, .signedIn)

        auth.sessionExpired()

        // NO borra la sesión: sigue signedIn (usable offline), pero marca reauth.
        XCTAssertEqual(auth.state, .signedIn)
        XCTAssertTrue(auth.needsReauth)
        XCTAssertNotNil(try store.read(), "la sesión NO se borra en un 401")
    }

    func test_logout_borraSesion() {
        let store = InMemorySessionStore(session: sampleSession())
        let auth = AuthSession(api: StubAuthAPI(token: "x"), store: store)
        auth.restore()
        XCTAssertEqual(auth.state, .signedIn)

        auth.logout()

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(try? store.read())
    }

    // MARK: - Trabajar offline tras un login offline

    func test_tomarYConfirmarPedido_trasLoginOffline() async throws {
        // Sesión previa + datos locales (como si ya se hubiera sincronizado antes).
        let db = try AppDatabase.makeInMemory()
        try await db.dbQueue.write { database in
            try Client(clientCode: "C1", name: "Tienda", address: nil, city: nil,
                       zipcode: nil, managerName: nil, shippingRoute: nil).insert(database)
            try Item(itemCode: "I1", name: "Item", category: nil, barcode: nil, comments: nil,
                     price: 10, stock: nil, available: 5, imageURL: nil, active: true).insert(database)
        }
        let auth = AuthSession(api: StubAuthAPI(token: "t"),
                               store: InMemorySessionStore(session: sampleSession()))

        // Login offline con sesión previa → entra.
        await auth.login(username: "vendedor1", password: "x", isOnline: false)
        XCTAssertEqual(auth.state, .signedIn)

        // Trabaja offline: toma y confirma un pedido.
        let repo = OrdersRepository(database: db,
                                    now: { Date(timeIntervalSince1970: 0) },
                                    makeUUID: { "ORD-1" })
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", quantity: 2)
        try repo.confirm(orderUUID: order.clientUUID)

        // Queda confirmada, pendiente de sincronizar.
        XCTAssertEqual(try repo.confirmedOrders().map(\.clientUUID), ["ORD-1"])
    }
}
