import Foundation
import GRDB

// Modelos de dominio persistidos en SQLite (GRDB).
//
// Los nombres de columna (CodingKeys en snake_case) coinciden con el contrato
// `openapi.yaml`: así el MISMO tipo sirve para decodificar el JSON del middleware y
// para persistir en la base local, sin capa de mapeo intermedia.

// MARK: - Item (catálogo)

/// Ítem del catálogo (schema `CatalogItem`).
/// La app NO recalcula stock: muestra `available` tal cual lo calcula el middleware.
struct Item: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var itemCode: String        // PK; identificador del ítem
    var name: String
    var category: String?
    var barcode: String?
    var comments: String?
    var price: Double?          // precio de la lista asignada al vendedor
    var stock: Double?          // stock físico en SAP (informativo)
    var available: Double       // disponible ya calculado por el middleware
    var imageURL: String?       // descarga diferida; no viaja en el delta
    var active: Bool            // si false, la app no lo muestra ni permite ordenarlo

    var id: String { itemCode }

    static let databaseTableName = "items"

    enum CodingKeys: String, CodingKey {
        case itemCode = "item_code"
        case name, category, barcode, comments, price, stock, available
        case imageURL = "image_url"
        case active
    }
}

// MARK: - Client

/// Cliente asignado al vendedor (schema `Client`).
/// Solo se guardan los que devuelve `GET /sync/clients` (filtrados por token).
struct Client: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var clientCode: String      // PK
    var name: String
    var address: String?
    var city: String?
    var zipcode: String?
    var managerName: String?
    var shippingRoute: String?

    var id: String { clientCode }

    static let databaseTableName = "clients"

    enum CodingKeys: String, CodingKey {
        case clientCode = "client_code"
        case name, address, city, zipcode
        case managerName = "manager_name"
        case shippingRoute = "shipping_route"
    }
}

// MARK: - Order (local)

/// Estado local de una orden: borrador → confirmada → sincronizada.
enum OrderStatus: String, Codable {
    case draft          // borrador
    case confirmed      // confirmada (taken_at), pendiente de subir
    case synced         // sincronizada con el middleware
}

/// Orden tomada por el vendedor. Modelo LOCAL; se transforma a `OrderCreate` al subir.
///
/// Nace con un `clientUUID` (UUID v4) generado en el dispositivo; ese UUID es la clave
/// de idempotencia hacia `POST /orders` y NO se regenera en reintentos.
struct Order: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var clientUUID: String      // UUID v4 local; clave de idempotencia (PK)
    var clientCode: String      // cliente asignado
    var status: OrderStatus
    var notes: String?
    var createdAt: Date         // creación del borrador (local)
    var takenAt: Date?          // momento en que se confirmó offline (taken_at del contrato)
    var syncedAt: Date?         // cuándo el middleware la aceptó
    var orderNumber: String?    // número interno devuelto por el middleware

    var id: String { clientUUID }

    static let databaseTableName = "orders"

    enum CodingKeys: String, CodingKey {
        case clientUUID = "client_uuid"
        case clientCode = "client_code"
        case status, notes
        case createdAt = "created_at"
        case takenAt = "taken_at"
        case syncedAt = "synced_at"
        case orderNumber = "order_number"
    }
}

// MARK: - OrderLine (local)

/// Línea de una orden (se transforma al schema `OrderLine` del contrato al subir).
struct OrderLine: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: Int64?              // autoincrement local
    var orderUUID: String      // FK -> orders.client_uuid
    var itemCode: String
    var quantity: Double
    var unitPrice: Double       // precio unitario capturado al tomar la orden
    var lineDiscountPct: Double // descuento de línea en % (0–100)
    var priceList: String?      // lista de precios usada en esta línea

    static let databaseTableName = "order_lines"

    enum CodingKeys: String, CodingKey {
        case id
        case orderUUID = "order_uuid"
        case itemCode = "item_code"
        case quantity
        case unitPrice = "unit_price"
        case lineDiscountPct = "line_discount_pct"
        case priceList = "price_list"
    }

    // Deja que SQLite asigne el rowid autoincremental.
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - SyncState

/// Marca de agua por recurso para la sincronización incremental.
/// Guarda el `server_time` recibido en la última bajada; se reenvía como `since`.
struct SyncState: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var resource: String        // "catalog" | "clients"
    var lastSyncedAt: Date?     // server_time de la última bajada

    var id: String { resource }

    static let databaseTableName = "sync_state"

    enum CodingKeys: String, CodingKey {
        case resource
        case lastSyncedAt = "last_synced_at"
    }
}
