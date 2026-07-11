import Foundation

/// Superficie de autenticación del middleware. Se extrae como protocolo para poder
/// inyectar un stub en tests sin tocar la red.
protocol AuthAPI {
    /// `POST /auth/login` — devuelve el JWT. Lanza `APIError.unauthorized` en 401.
    func login(username: String, password: String) async throws -> String
}

/// Cliente HTTP contra el middleware, según `dinas-wms-contracts/openapi.yaml`.
///
/// Esqueleto: `login` ya está implementado; el resto de endpoints se completan contra
/// el contrato OpenAPI. Si falta un campo/endpoint en el contrato, no se inventa: se
/// eleva al Arquitecto.
struct APIClient: AuthAPI {
    /// URL base del middleware. Se configura por entorno (ver `AppConfig`).
    var baseURL: URL?
    var session: URLSession

    init(baseURL: URL? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Auth

    /// `POST /auth/login` — devuelve el JWT que se guarda en Keychain.
    func login(username: String, password: String) async throws -> String {
        guard let baseURL else { throw APIError.missingBaseURL }

        var request = URLRequest(url: baseURL.appendingPathComponent("auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            LoginRequest(username: username, password: password)
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.server(status: -1)
        }
        switch http.statusCode {
        case 200..<300:
            return try JSONDecoder().decode(LoginResponse.self, from: data).token
        case 401:
            throw APIError.unauthorized
        default:
            throw APIError.server(status: http.statusCode)
        }
    }

    // MARK: - Sync bajada

    /// `GET /sync/catalog?since=` — catálogo incremental.
    func fetchCatalog(since: Date?) async throws -> [Item] {
        throw APIError.notImplemented
    }

    /// `GET /sync/clients?since=` — clientes asignados incrementales.
    func fetchClients(since: Date?) async throws -> [Client] {
        throw APIError.notImplemented
    }

    // MARK: - Sync subida

    /// `POST /orders` — envía una orden confirmada. `client_uuid` es la clave de
    /// idempotencia: el mismo UUID en un reintento no duplica la orden.
    func postOrder(_ order: Order, lines: [OrderLine]) async throws {
        throw APIError.notImplemented
    }
}

enum APIError: Error, Equatable {
    case notImplemented
    case missingBaseURL
    case unauthorized
    case server(status: Int)
}
