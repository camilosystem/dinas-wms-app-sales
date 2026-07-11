import Foundation

// DTOs de red según `openapi.yaml`. Los ítems y clientes se decodifican directamente
// en los modelos locales (mismas CodingKeys); aquí van solo las envolturas del delta
// y los DTOs de subida de órdenes.

// MARK: - Bajada

/// Respuesta de `GET /sync/catalog`.
struct CatalogSyncResponse: Decodable {
    let serverTime: Date
    let items: [Item]

    enum CodingKeys: String, CodingKey {
        case serverTime = "server_time"
        case items
    }
}

/// Respuesta de `GET /sync/clients`.
struct ClientsSyncResponse: Decodable {
    let serverTime: Date
    let clients: [Client]

    enum CodingKeys: String, CodingKey {
        case serverTime = "server_time"
        case clients
    }
}

/// Página de catálogo ya lista para persistir (ítems + marca de agua).
struct CatalogPage {
    let items: [Item]
    let serverTime: Date
}

/// Página de clientes ya lista para persistir.
struct ClientsPage {
    let clients: [Client]
    let serverTime: Date
}

// MARK: - Subida (POST /orders)

/// Cuerpo de `POST /orders` (schema `OrderCreate`).
struct OrderCreateDTO: Encodable {
    let clientUUID: String
    let clientCode: String
    let takenAt: Date?
    let notes: String?
    let lines: [Line]

    struct Line: Encodable {
        let itemCode: String
        let quantity: Double
        let unitPrice: Double
        let lineDiscountPct: Double
        let priceList: String?

        enum CodingKeys: String, CodingKey {
            case itemCode = "item_code"
            case quantity
            case unitPrice = "unit_price"
            case lineDiscountPct = "line_discount_pct"
            case priceList = "price_list"
        }
    }

    enum CodingKeys: String, CodingKey {
        case clientUUID = "client_uuid"
        case clientCode = "client_code"
        case takenAt = "taken_at"
        case notes, lines
    }

    /// Construye el DTO de subida desde el modelo local.
    init(order: Order, lines: [OrderLine]) {
        self.clientUUID = order.clientUUID
        self.clientCode = order.clientCode
        self.takenAt = order.takenAt
        self.notes = order.notes
        self.lines = lines.map {
            Line(itemCode: $0.itemCode, quantity: $0.quantity, unitPrice: $0.unitPrice,
                 lineDiscountPct: $0.lineDiscountPct, priceList: $0.priceList)
        }
    }
}

/// Respuesta de `POST /orders` (schema `OrderAccepted`), para 200 y 201.
struct OrderAcceptedDTO: Decodable {
    let clientUUID: String
    let orderNumber: String?
    let status: String?
    let receivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case clientUUID = "client_uuid"
        case orderNumber = "order_number"
        case status
        case receivedAt = "received_at"
    }
}
