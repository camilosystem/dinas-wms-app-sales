import Foundation

/// Superficie de autenticación (login público, sin token).
protocol AuthAPI {
    /// `POST /auth/login`. Lanza `APIError.unauthorized` en 401.
    func login(username: String, password: String) async throws -> LoginResponse
}

/// Superficie de sincronización de bajada (requiere token).
protocol SyncDownAPI {
    func fetchCatalog(since: Date?) async throws -> CatalogPage
    func fetchClients(since: Date?) async throws -> ClientsPage
}

/// Cliente HTTP contra el middleware, según `dinas-wms-contracts/openapi.yaml`.
///
/// El JWT se inyecta vía `tokenProvider` y se añade como `Authorization: Bearer` en
/// todos los endpoints salvo `login` (público). Si falta un campo/endpoint en el
/// contrato, no se inventa: se eleva al Arquitecto.
struct APIClient: AuthAPI, SyncDownAPI {
    /// URL base del middleware (incluye el path base `/v1`). Ver `AppConfig`.
    var baseURL: URL?
    var session: URLSession
    /// Provee el JWT actual (desde Keychain). `nil` cuando no hay sesión.
    var tokenProvider: () -> String?

    init(baseURL: URL? = nil,
         session: URLSession = .shared,
         tokenProvider: @escaping () -> String? = { nil }) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    // MARK: - Auth

    func login(username: String, password: String) async throws -> LoginResponse {
        let body = try JSONCoding.encoder.encode(
            LoginRequest(username: username, password: password)
        )
        let request = try makeRequest(path: "auth/login", method: "POST",
                                      body: body, authenticated: false)
        return try await send(request, decode: LoginResponse.self)
    }

    // MARK: - Sync bajada

    func fetchCatalog(since: Date?) async throws -> CatalogPage {
        let request = try makeRequest(path: "sync/catalog", method: "GET",
                                      query: sinceQuery(since))
        let resp = try await send(request, decode: CatalogSyncResponse.self)
        return CatalogPage(items: resp.items, serverTime: resp.serverTime)
    }

    func fetchClients(since: Date?) async throws -> ClientsPage {
        let request = try makeRequest(path: "sync/clients", method: "GET",
                                      query: sinceQuery(since))
        let resp = try await send(request, decode: ClientsSyncResponse.self)
        return ClientsPage(clients: resp.clients, serverTime: resp.serverTime)
    }

    // MARK: - Sync subida

    /// `POST /orders`. Idempotente por `client_uuid` (200 = ya existente, 201 = creada).
    func postOrder(_ order: Order, lines: [OrderLine]) async throws -> OrderAcceptedDTO {
        let body = try JSONCoding.encoder.encode(OrderCreateDTO(order: order, lines: lines))
        let request = try makeRequest(path: "orders", method: "POST", body: body)
        return try await send(request, decode: OrderAcceptedDTO.self)
    }

    // MARK: - Infra HTTP

    private func sinceQuery(_ since: Date?) -> [URLQueryItem] {
        guard let since else { return [] }
        return [URLQueryItem(name: "since", value: iso8601.string(from: since))]
    }

    private func makeRequest(path: String,
                             method: String,
                             query: [URLQueryItem] = [],
                             body: Data? = nil,
                             authenticated: Bool = true) throws -> URLRequest {
        guard let baseURL else { throw APIError.missingBaseURL }

        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw APIError.missingBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard let token = tokenProvider() else { throw APIError.unauthorized }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, decode: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.server(status: -1)
        }
        switch http.statusCode {
        case 200..<300:
            return try JSONCoding.decoder.decode(T.self, from: data)
        case 401:
            throw APIError.unauthorized
        default:
            throw APIError.server(status: http.statusCode)
        }
    }

    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

enum APIError: Error, Equatable {
    case notImplemented
    case missingBaseURL
    case unauthorized
    case server(status: Int)
}
