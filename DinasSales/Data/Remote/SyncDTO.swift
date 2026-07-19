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

/// Respuesta de `GET /sync/orders` (★ v0.4.1). Liviana: solo lo que puede cambiar DESPUÉS
/// de enviar la orden (estado, retención, decisión del admin).
struct OrdersSyncResponse: Decodable {
    let serverTime: Date
    let orders: [OrderStatusUpdate]

    enum CodingKeys: String, CodingKey {
        case serverTime = "server_time"
        case orders
    }
}

/// Una actualización de estado de orden (schema `OrderStatusUpdate`). Se casa con la orden
/// local por `client_uuid`.
struct OrderStatusUpdate: Decodable {
    let clientUUID: String
    let orderNumber: String?
    let status: String?
    let holdReason: String?
    let decisionNote: String?
    let decidedAt: Date?
    let receivedAt: Date?
    // ★ v0.11.0 — resultado de la ENTREGA (para que el vendedor sepa qué pasó). Todos
    // nullable: la mayoría de las órdenes aún no se han entregado. `deliveryReason` viene
    // YA formateado por el middleware — se muestra tal cual (no se parsea ni traduce).
    let deliveryStatus: String?
    let deliveryReason: String?
    let deliveredAt: Date?

    enum CodingKeys: String, CodingKey {
        case clientUUID = "client_uuid"
        case orderNumber = "order_number"
        case status
        case holdReason = "hold_reason"
        case decisionNote = "decision_note"
        case decidedAt = "decided_at"
        case receivedAt = "received_at"
        case deliveryStatus = "delivery_status"
        case deliveryReason = "delivery_reason"
        case deliveredAt = "delivered_at"
    }
}

/// Página de estados de órdenes lista para aplicar (actualizaciones + marca de agua).
struct OrdersStatusPage {
    let updates: [OrderStatusUpdate]
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
        let priceList: Int          // 1/2/3 — obligatorio en v0.3.0
        let lineDiscountPct: Double

        enum CodingKeys: String, CodingKey {
            case itemCode = "item_code"
            case quantity
            case unitPrice = "unit_price"
            case priceList = "price_list"
            case lineDiscountPct = "line_discount_pct"
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
                 priceList: $0.priceList, lineDiscountPct: $0.lineDiscountPct)
        }
    }
}

/// Respuesta de `POST /orders` (schema `OrderAccepted`), para 200 y 201.
/// ★ v0.4.0: `status` = APROBADA | RETENIDA_CARTERA; `hold_reason` explica la retención.
struct OrderAcceptedDTO: Decodable {
    let clientUUID: String
    let orderNumber: String?
    let status: String?
    let holdReason: String?
    let receivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case clientUUID = "client_uuid"
        case orderNumber = "order_number"
        case status
        case holdReason = "hold_reason"
        case receivedAt = "received_at"
    }
}
