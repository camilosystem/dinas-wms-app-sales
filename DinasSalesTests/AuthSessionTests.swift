import XCTest
@testable import DinasSales

/// Stub de la API de auth: no toca la red. Puede fallar con cualquier error (incluido
/// uno de red) para simular un servidor inalcanzable.
private struct StubAuthAPI: AuthAPI, @unchecked Sendable {
    var result: Result<LoginResponse, any Error>

    init(result: Result<LoginResponse, any Error>) { self.result = result }

    init(token: String, displayName: String? = nil) {
        self.result = .success(LoginResponse(token: token, role: "VENDEDOR",
                                             salespersonCode: nil, displayName: displayName))
    }

    func login(username: String, password: String) async throws -> LoginResponse {
        try result.get()
    }
}

@MainActor
final class AuthSessionTests: XCTestCase {

    /// Hasher rápido para tests (pocas iteraciones); ejercita el mismo PBKDF2 real.
    private let hasher = PBKDF2Hasher(iterations: 1_000)

    private func sampleSession(username: String = "vendedor1", password: String = "secreta",
                               loggedOut: Bool = false) -> StoredSession {
        StoredSession(token: "jwt-previo", username: username, displayName: "Vendedor Uno",
                      salespersonCode: "V1", lastOnlineLoginAt: Date(timeIntervalSince1970: 0),
                      passwordHash: try! hasher.hash(password), loggedOut: loggedOut)
    }

    private func makeAuth(api: AuthAPI, store: SessionStore) -> AuthSession {
        AuthSession(api: api, store: store, hasher: hasher,
                    now: { Date(timeIntervalSince1970: 100) })
    }

    // MARK: - Restore

    func test_restore_sinSesion_quedaSignedOut() {
        let auth = makeAuth(api: StubAuthAPI(token: "t"), store: InMemorySessionStore())
        auth.restore()
        XCTAssertEqual(auth.state, .signedOut)
    }

    func test_restore_conSesionActiva_entra_sinPedirContraseña() {
        let auth = makeAuth(api: StubAuthAPI(token: "t"),
                            store: InMemorySessionStore(session: sampleSession()))
        auth.restore()
        XCTAssertEqual(auth.state, .signedIn)
        XCTAssertEqual(auth.displayName, "Vendedor Uno")
    }

    func test_restore_trasLogout_arrancaEnLogin() {
        let auth = makeAuth(api: StubAuthAPI(token: "t"),
                            store: InMemorySessionStore(session: sampleSession(loggedOut: true)))
        auth.restore()
        XCTAssertEqual(auth.state, .signedOut, "tras logout arranca en el login")
    }

    // MARK: - Login online

    func test_login_online_exitoso_guardaSesionConHash() async throws {
        let store = InMemorySessionStore()
        let auth = makeAuth(api: StubAuthAPI(token: "jwt-123", displayName: "Ana"), store: store)

        await auth.login(username: "vendedor1", password: "secreta", isOnline: true)

        XCTAssertEqual(auth.state, .signedIn)
        XCTAssertNil(auth.loginFailure)
        let saved = try store.read()
        XCTAssertEqual(saved?.token, "jwt-123")
        XCTAssertEqual(saved?.username, "vendedor1")
        XCTAssertTrue(hasher.verify("secreta", saved!.passwordHash), "guarda hash verificable")
        XCTAssertFalse(hasher.verify("otra", saved!.passwordHash))
    }

    func test_login_online_credencialesIncorrectas_mensajeExplicito() async throws {
        let store = InMemorySessionStore()
        let auth = makeAuth(api: StubAuthAPI(result: .failure(APIError.unauthorized)), store: store)
        auth.restore()

        await auth.login(username: "vendedor1", password: "mala", isOnline: true)

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertEqual(auth.loginFailure, .badCredentials)
        XCTAssertEqual(auth.errorMessage, "Usuario o contraseña incorrectos.")
        XCTAssertNil(try store.read())
    }

    func test_login_online_errorDeServidor_distinguido() async throws {
        let auth = makeAuth(api: StubAuthAPI(result: .failure(APIError.server(status: 500))),
                            store: InMemorySessionStore())
        auth.restore()
        await auth.login(username: "vendedor1", password: "x", isOnline: true)
        XCTAssertEqual(auth.loginFailure, .serverError)
        XCTAssertEqual(auth.state, .signedOut)
    }

    // MARK: - Login offline (verificando contraseña)

    func test_login_offline_sinCredencial_noEntra() async throws {
        let auth = makeAuth(api: StubAuthAPI(token: "t"), store: InMemorySessionStore())
        auth.restore()

        await auth.login(username: "vendedor1", password: "x", isOnline: false)

        XCTAssertEqual(auth.state, .signedOut, "primer login offline: no hay nada que mostrar")
        XCTAssertEqual(auth.loginFailure, .offlineNoSession)
    }

    func test_login_offline_passwordCorrecta_entra() async throws {
        let auth = makeAuth(api: StubAuthAPI(token: "t"),
                            store: InMemorySessionStore(session: sampleSession(password: "secreta",
                                                                              loggedOut: true)))
        auth.restore()

        await auth.login(username: "vendedor1", password: "secreta", isOnline: false)

        XCTAssertEqual(auth.state, .signedIn)
        XCTAssertNil(auth.loginFailure)
    }

    func test_login_offline_passwordIncorrecta_noEntra() async throws {
        let auth = makeAuth(api: StubAuthAPI(token: "t"),
                            store: InMemorySessionStore(session: sampleSession(password: "secreta",
                                                                              loggedOut: true)))
        auth.restore()

        await auth.login(username: "vendedor1", password: "MALA", isOnline: false)

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertEqual(auth.loginFailure, .badCredentials)
    }

    // MARK: - Logout / sesión expirada

    func test_logout_conservaCredencial_paraReloginOffline() {
        let store = InMemorySessionStore(session: sampleSession())
        let auth = makeAuth(api: StubAuthAPI(token: "x"), store: store)
        auth.restore()
        XCTAssertEqual(auth.state, .signedIn)

        auth.logout()

        XCTAssertEqual(auth.state, .signedOut)
        let cred = try? store.read()
        XCTAssertNotNil(cred, "la credencial se conserva")
        XCTAssertEqual(cred?.loggedOut, true)
    }

    func test_sessionExpired_mantieneAccesoOffline() {
        let store = InMemorySessionStore(session: sampleSession())
        let auth = makeAuth(api: StubAuthAPI(token: "x"), store: store)
        auth.restore()

        auth.sessionExpired()

        XCTAssertEqual(auth.state, .signedIn)
        XCTAssertTrue(auth.needsReauth)
        XCTAssertNotNil(try store.read())
    }

    // MARK: - Flujo C end-to-end: re-login offline tras logout

    func test_reloginOffline_trasLogout_conContraseña() async throws {
        let store = InMemorySessionStore()
        let auth = makeAuth(api: StubAuthAPI(token: "jwt-1", displayName: "Ana"), store: store)

        // 1. Login online (guarda token + hash).
        await auth.login(username: "vendedor1", password: "Dinas2026!", isOnline: true)
        XCTAssertEqual(auth.state, .signedIn)

        // 2. Logout (conserva la credencial).
        auth.logout()
        XCTAssertEqual(auth.state, .signedOut)

        // 3. Sin red, re-login con la contraseña correcta → entra.
        await auth.login(username: "vendedor1", password: "Dinas2026!", isOnline: false)
        XCTAssertEqual(auth.state, .signedIn)
        XCTAssertNil(auth.loginFailure)

        // 4. Logout otra vez; offline con contraseña incorrecta → no entra.
        auth.logout()
        await auth.login(username: "vendedor1", password: "incorrecta", isOnline: false)
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertEqual(auth.loginFailure, .badCredentials)
    }

    // MARK: - Trabajar offline tras un login offline

    func test_tomarYConfirmarPedido_trasLoginOffline() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbQueue.write { database in
            try Client(clientCode: "C1", name: "Tienda", address: nil, city: nil,
                       zipcode: nil, managerName: nil, shippingRoute: nil,
                       defaultPriceList: 1, authorizedPriceLists: [1]).insert(database)
            try Item(itemCode: "I1", name: "Item", category: nil, barcode: nil,
                     priceList1: 10, priceList2: 10, priceList3: 10, stock: nil,
                     available: 5, imageURL: nil, active: true).insert(database)
        }
        let auth = makeAuth(api: StubAuthAPI(token: "t"),
                            store: InMemorySessionStore(session: sampleSession(password: "secreta",
                                                                              loggedOut: true)))
        auth.restore()

        // Login offline con la contraseña correcta → entra.
        await auth.login(username: "vendedor1", password: "secreta", isOnline: false)
        XCTAssertEqual(auth.state, .signedIn)

        // Trabaja offline: toma y confirma un pedido.
        let repo = OrdersRepository(database: db,
                                    now: { Date(timeIntervalSince1970: 0) },
                                    makeUUID: { "ORD-1" })
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 2)
        try repo.confirm(orderUUID: order.clientUUID)

        XCTAssertEqual(try repo.confirmedOrders().map(\.clientUUID), ["ORD-1"])
    }

    // MARK: - Caducidad de la sesión offline (7 días)

    /// "Ahora" fijo y una sesión cuyo último login online fue hace `daysAgo` días.
    private let fixedNow = Date(timeIntervalSince1970: 10_000_000)
    private func sessionDaysAgo(_ daysAgo: Double, password: String = "secreta",
                               loggedOut: Bool = true) -> StoredSession {
        StoredSession(token: "jwt-previo", username: "vendedor1", displayName: "Vendedor Uno",
                      salespersonCode: "V1",
                      lastOnlineLoginAt: fixedNow.addingTimeInterval(-daysAgo * 24 * 3600),
                      passwordHash: try! hasher.hash(password), loggedOut: loggedOut)
    }
    private func authAtFixedNow(store: SessionStore, api: AuthAPI = StubAuthAPI(token: "t")) -> AuthSession {
        AuthSession(api: api, store: store, hasher: hasher, now: { self.fixedNow })
    }

    func test_loginOffline_6dias_funciona() async {
        let auth = authAtFixedNow(store: InMemorySessionStore(session: sessionDaysAgo(6)))
        auth.restore()
        await auth.login(username: "vendedor1", password: "secreta", isOnline: false)
        XCTAssertEqual(auth.state, .signedIn, "6 días < 7: el login offline funciona")
    }

    func test_loginOffline_8dias_rechazadoConMensaje() async {
        let auth = authAtFixedNow(store: InMemorySessionStore(session: sessionDaysAgo(8)))
        auth.restore()
        await auth.login(username: "vendedor1", password: "secreta", isOnline: false)
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertEqual(auth.loginFailure, .offlineExpired)
        XCTAssertEqual(auth.errorMessage, "Tu sesión offline expiró. Conéctate para continuar.")
    }

    func test_restore_sesionActivaCaducada_exigeLoginOnline() {
        let auth = authAtFixedNow(store: InMemorySessionStore(session: sessionDaysAgo(8, loggedOut: false)))
        auth.restore()
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertEqual(auth.loginFailure, .offlineExpired)
    }

    func test_loginOnline_renuevaContador() async throws {
        // Sesión vieja (8 días) → un login online la renueva a "ahora".
        let store = InMemorySessionStore(session: sessionDaysAgo(8))
        let auth = authAtFixedNow(store: store, api: StubAuthAPI(token: "nuevo"))

        await auth.login(username: "vendedor1", password: "secreta", isOnline: true)

        XCTAssertEqual(auth.state, .signedIn)
        XCTAssertEqual(try store.read()?.lastOnlineLoginAt, fixedNow,
                       "el login online reinicia el contador de 7 días")
    }

    // MARK: - Servidor inalcanzable con red activa (middleware caído) → fallback offline

    func test_login_servidorInalcanzable_caeAOfflineConPasswordCorrecta() async throws {
        // Hay red (isOnline: true), pero el POST falla por timeout (middleware caído).
        let auth = makeAuth(api: StubAuthAPI(result: .failure(URLError(.timedOut))),
                            store: InMemorySessionStore(session: sampleSession(password: "secreta",
                                                                              loggedOut: true)))
        auth.restore()

        await auth.login(username: "vendedor1", password: "secreta", isOnline: true)

        XCTAssertEqual(auth.state, .signedIn, "cae a verificación offline con el hash")
        XCTAssertNil(auth.loginFailure)
    }

    func test_login_servidorInalcanzable_passwordMala_noEntra() async throws {
        let auth = makeAuth(api: StubAuthAPI(result: .failure(URLError(.timedOut))),
                            store: InMemorySessionStore(session: sampleSession(password: "secreta",
                                                                              loggedOut: true)))
        auth.restore()

        await auth.login(username: "vendedor1", password: "MALA", isOnline: true)

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertEqual(auth.loginFailure, .badCredentials)
    }
}
