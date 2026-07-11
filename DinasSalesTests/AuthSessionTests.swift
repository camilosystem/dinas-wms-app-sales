import XCTest
@testable import DinasSales

/// Stub de la API de auth: no toca la red.
private struct StubAuthAPI: AuthAPI {
    var result: Result<String, Error>
    func login(username: String, password: String) async throws -> String {
        try result.get()
    }
}

@MainActor
final class AuthSessionTests: XCTestCase {

    func test_restore_sinToken_quedaSignedOut() {
        let session = AuthSession(api: StubAuthAPI(result: .success("t")),
                                  store: InMemoryTokenStore())
        session.restore()
        XCTAssertEqual(session.state, .signedOut)
    }

    func test_restore_conToken_quedaSignedIn() {
        let session = AuthSession(api: StubAuthAPI(result: .success("t")),
                                  store: InMemoryTokenStore(token: "jwt-guardado"))
        session.restore()
        XCTAssertEqual(session.state, .signedIn)
    }

    func test_login_exitoso_guardaTokenYSignedIn() async throws {
        let store = InMemoryTokenStore()
        let session = AuthSession(api: StubAuthAPI(result: .success("jwt-123")), store: store)

        await session.login(username: "vendedor", password: "secreta")

        XCTAssertEqual(session.state, .signedIn)
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(try store.read(), "jwt-123")
    }

    func test_login_credencialesInvalidas_muestraErrorYNoGuarda() async throws {
        let store = InMemoryTokenStore()
        let session = AuthSession(api: StubAuthAPI(result: .failure(APIError.unauthorized)),
                                  store: store)
        session.restore()  // parte de signedOut (store vacío)

        await session.login(username: "vendedor", password: "mala")

        XCTAssertEqual(session.state, .signedOut)  // sigue sin sesión
        XCTAssertEqual(session.errorMessage, "Usuario o contraseña incorrectos.")
        XCTAssertNil(try store.read())
    }

    func test_logout_borraTokenYSignedOut() async {
        let store = InMemoryTokenStore(token: "jwt-previo")
        let session = AuthSession(api: StubAuthAPI(result: .success("x")), store: store)
        session.restore()
        XCTAssertEqual(session.state, .signedIn)

        session.logout()

        XCTAssertEqual(session.state, .signedOut)
        XCTAssertNil(try? store.read())
    }
}
