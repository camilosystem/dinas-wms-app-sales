import Foundation
import os

// Los clientes de red se invocan con `await` desde el @MainActor y corren en el ejecutor
// genérico: deben ser `Sendable` para cruzar ese límite sin riesgo de carrera.

/// Superficie de autenticación (login público, sin token).
protocol AuthAPI: Sendable {
    /// `POST /auth/login`. Lanza `APIError.unauthorized` en 401.
    func login(username: String, password: String) async throws -> LoginResponse
}

/// Superficie de sincronización de bajada (requiere token).
protocol SyncDownAPI: Sendable {
    func fetchCatalog(since: Date?) async throws -> CatalogPage
    func fetchClients(since: Date?) async throws -> ClientsPage
    /// `GET /sync/orders` (★ v0.4.1). Estado actual de las órdenes del vendedor (delta).
    func fetchOrderStatuses(since: Date?) async throws -> OrdersStatusPage
}

/// Superficie de sincronización de subida (requiere token).
protocol SyncUpAPI: Sendable {
    /// `POST /orders`. Idempotente por `client_uuid`.
    func postOrder(_ order: Order, lines: [OrderLine]) async throws -> OrderAcceptedDTO
}

/// Superficie de cartera (★ v0.4.0, requiere token).
protocol CreditAPI: Sendable {
    /// `GET /clients/{code}/statement`. Estado de cuenta para consulta offline.
    func fetchStatement(clientCode: String) async throws -> ClientStatement
}

/// Libro de promociones del vendedor (★ v0.28.0). Requiere conexión (no se cachea).
protocol PromotionsAPI: Sendable {
    /// `GET /promotions?q=`. Solo activas, vigentes y asignadas al vendedor (filtra el server).
    func fetchPromotions(query: String?) async throws -> [PromotionSummary]
    /// `GET /promotions/{id}`. 403 si no está asignada al vendedor.
    func fetchPromotion(id: String) async throws -> PromotionDetail
}

/// Subida del bloque de cartera (★ v0.17.0, requiere token).
protocol CarteraUploadAPI: Sendable {
    /// `POST /evidence-photos`. Sube la foto (base64) y devuelve su URL. REQUIERE conexión;
    /// sin ella no hay `evidence_image_url` y el envío con foto no puede completarse.
    func uploadEvidencePhoto(imageBase64: String, clientCode: String?) async throws -> String
    /// `POST /account-payments`. Idempotente por `payment_uuid`.
    func postAccountPayment(_ payment: AccountPayment) async throws -> AccountPaymentAccepted
    /// `POST /credit-requests`. Idempotente por `request_uuid`. `lines` solo en CON_ITEMS.
    func postCreditRequest(_ request: CreditRequest, lines: [CreditRequestLine]) async throws -> CreditRequestAccepted
    /// `POST /account-payments/{uuid}/cancel` (★ v0.21.0, rol VENDEDOR). Cancela un pago propio
    /// PENDIENTE_APROBACION → CANCELADO. Motivo opcional. 409 si ya fue decidido; 403 si no es dueño.
    func cancelAccountPayment(paymentUUID: String, reason: String?) async throws
    /// `POST /credit-requests/{uuid}/cancel` (★ v0.21.0, rol VENDEDOR). Mismo patrón.
    func cancelCreditRequest(requestUUID: String, reason: String?) async throws
}

/// Cliente HTTP contra el middleware, según `dinas-wms-contracts/openapi.yaml`.
///
/// El JWT se inyecta vía `tokenProvider` y se añade como `Authorization: Bearer` en
/// todos los endpoints salvo `login` (público). Si falta un campo/endpoint en el
/// contrato, no se inventa: se eleva al Arquitecto.
struct APIClient: AuthAPI, SyncDownAPI, SyncUpAPI, CreditAPI, CarteraUploadAPI, PromotionsAPI {
    /// URL base del middleware (incluye el path base `/v1`). Ver `AppConfig`.
    var baseURL: URL?
    var session: URLSession
    /// Provee el JWT actual (desde Keychain). `nil` cuando no hay sesión.
    var tokenProvider: @Sendable () -> String?

    init(baseURL: URL? = nil,
         session: URLSession = .shared,
         tokenProvider: @escaping @Sendable () -> String? = { nil }) {
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

    /// `GET /sync/orders`. Estado actual de las órdenes del vendedor (delta por `since`).
    func fetchOrderStatuses(since: Date?) async throws -> OrdersStatusPage {
        let request = try makeRequest(path: "sync/orders", method: "GET",
                                      query: sinceQuery(since))
        let resp = try await send(request, decode: OrdersSyncResponse.self)
        return OrdersStatusPage(updates: resp.orders, serverTime: resp.serverTime)
    }

    // MARK: - Sync subida

    /// `POST /orders`. Idempotente por `client_uuid` (200 = ya existente, 201 = creada).
    func postOrder(_ order: Order, lines: [OrderLine]) async throws -> OrderAcceptedDTO {
        let body = try JSONCoding.encoder.encode(OrderCreateDTO(order: order, lines: lines))
        let request = try makeRequest(path: "orders", method: "POST", body: body)
        return try await send(request, decode: OrderAcceptedDTO.self)
    }

    // MARK: - Alcanzabilidad

    /// Sondeo ligero: ¿responde el middleware? Cualquier respuesta HTTP (incluido 401/404)
    /// cuenta como ALCANZABLE; solo un error de TRANSPORTE (conexión rehusada, timeout, sin
    /// ruta) significa inalcanzable. No requiere token ni tiene efectos secundarios.
    func checkReachability() async -> Bool {
        guard let baseURL else { return false }
        var request = URLRequest(url: baseURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            _ = try await session.data(for: request)
            return true          // hubo respuesta HTTP → el middleware está arriba
        } catch {
            return false         // error de transporte → inalcanzable
        }
    }

    // MARK: - Promociones (★ v0.28.0)

    func fetchPromotions(query: String?) async throws -> [PromotionSummary] {
        var q: [URLQueryItem] = []
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            q.append(URLQueryItem(name: "q", value: query))
        }
        let request = try makeRequest(path: "promotions", method: "GET", query: q)
        return try await send(request, decode: PromotionsResponse.self).promotions
    }

    func fetchPromotion(id: String) async throws -> PromotionDetail {
        let request = try makeRequest(path: "promotions/\(id)", method: "GET")
        return try await send(request, decode: PromotionDetail.self)
    }

    // MARK: - Cartera (★ v0.4.0)

    /// `GET /clients/{code}/statement`. Estado de cuenta del cliente.
    func fetchStatement(clientCode: String) async throws -> ClientStatement {
        let request = try makeRequest(path: "clients/\(clientCode)/statement", method: "GET")
        return try await send(request, decode: ClientStatement.self)
    }

    // MARK: - Cartera: subida (★ v0.17.0)

    /// `POST /evidence-photos`. Devuelve la `evidence_image_url` para usar al crear el registro.
    func uploadEvidencePhoto(imageBase64: String, clientCode: String?) async throws -> String {
        let body = try JSONCoding.encoder.encode(
            EvidencePhotoUpload(imageBase64: imageBase64, clientCode: clientCode))
        let request = try makeRequest(path: "evidence-photos", method: "POST", body: body)
        return try await send(request, decode: EvidencePhotoUploaded.self).evidenceImageURL
    }

    /// `POST /account-payments`. Idempotente por `payment_uuid`.
    func postAccountPayment(_ payment: AccountPayment) async throws -> AccountPaymentAccepted {
        let body = try JSONCoding.encoder.encode(AccountPaymentCreateDTO(payment))
        let request = try makeRequest(path: "account-payments", method: "POST", body: body)
        return try await send(request, decode: AccountPaymentAccepted.self)
    }

    func cancelAccountPayment(paymentUUID: String, reason: String?) async throws {
        let body = try JSONCoding.encoder.encode(CarteraCancelDTO(reason: reason))
        let request = try makeRequest(path: "account-payments/\(paymentUUID)/cancel",
                                      method: "POST", body: body)
        _ = try await send(request, decode: CarteraCancelResult.self)
    }

    func cancelCreditRequest(requestUUID: String, reason: String?) async throws {
        let body = try JSONCoding.encoder.encode(CarteraCancelDTO(reason: reason))
        let request = try makeRequest(path: "credit-requests/\(requestUUID)/cancel",
                                      method: "POST", body: body)
        _ = try await send(request, decode: CarteraCancelResult.self)
    }

    /// `POST /credit-requests`. Idempotente por `request_uuid`.
    func postCreditRequest(_ request: CreditRequest,
                           lines: [CreditRequestLine]) async throws -> CreditRequestAccepted {
        let body = try JSONCoding.encoder.encode(CreditRequestCreateDTO(request, lines: lines))
        let httpRequest = try makeRequest(path: "credit-requests", method: "POST", body: body)
        return try await send(httpRequest, decode: CreditRequestAccepted.self)
    }

    // MARK: - Infra HTTP

    private func sinceQuery(_ since: Date?) -> [URLQueryItem] {
        guard let since else { return [] }
        return [URLQueryItem(name: "since", value: JSONCoding.iso8601String(since))]
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
        // Timeout corto: si el middleware no responde, fallar rápido (p. ej. para caer al
        // login offline) en vez de colgarse ~60s con el valor por defecto.
        request.timeoutInterval = 15
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
            throw APIError.server(status: -1, message: nil)
        }
        // Método + path + estado. Sin body ni cabeceras (evita loguear el token).
        AppLog.api.debug("\(request.httpMethod ?? "?", privacy: .public) \(request.url?.path ?? "?", privacy: .public) → \(http.statusCode, privacy: .public)")
        switch http.statusCode {
        case 200..<300:
            return try JSONCoding.decoder.decode(T.self, from: data)
        case 401:
            throw APIError.unauthorized
        default:
            // Rescata el mensaje del cuerpo de error del contrato ({ code, message }).
            let message = (try? JSONCoding.decoder.decode(ErrorBody.self, from: data))?.message
            throw APIError.server(status: http.statusCode, message: message)
        }
    }
}

/// Cuerpo de error del contrato (`Error { code, message }`).
private struct ErrorBody: Decodable {
    let code: String?
    let message: String?
}

enum APIError: Error, Equatable {
    case notImplemented
    case missingBaseURL
    case unauthorized
    case server(status: Int, message: String?)

    /// Error PERMANENTE: reintentar no ayuda (validación/no encontrado). 4xx salvo 401.
    var isPermanent: Bool {
        if case let .server(status, _) = self { return (400..<500).contains(status) }
        return false
    }

    /// Mensaje legible del servidor, si lo hay.
    var serverMessage: String? {
        if case let .server(_, message) = self { return message }
        return nil
    }

    /// Código HTTP del error de servidor (0 si no aplica).
    var serverStatus: Int {
        if case let .server(status, _) = self { return status }
        return 0
    }
}
