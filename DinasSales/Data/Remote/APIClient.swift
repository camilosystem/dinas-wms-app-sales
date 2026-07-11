import Foundation

/// Cliente HTTP contra el middleware, según `dinas-wms-contracts/openapi.yaml`.
///
/// Esqueleto: define la superficie mínima del MVP. La implementación real de cada
/// endpoint se completa contra el contrato OpenAPI. Si falta un campo/endpoint en el
/// contrato, no se inventa: se eleva al Arquitecto.
struct APIClient {
    /// URL base del middleware. Se configura por entorno (build settings / plist).
    var baseURL: URL?
    var session: URLSession

    init(baseURL: URL? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Auth

    /// `POST /auth/login` — devuelve el JWT que se guarda en Keychain.
    func login(username: String, password: String) async throws -> String {
        throw APIError.notImplemented
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

enum APIError: Error {
    case notImplemented
    case missingBaseURL
    case unauthorized
    case server(status: Int)
}
