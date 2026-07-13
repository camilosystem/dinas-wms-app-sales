import Foundation
import GRDB

// Modelos de dominio persistidos en SQLite (GRDB).
//
// Los nombres de columna (CodingKeys en snake_case) coinciden con el contrato
// `openapi.yaml`: así el MISMO tipo sirve para decodificar el JSON del middleware y
// para persistir en la base local, sin capa de mapeo intermedia.

// MARK: - Item (catálogo)

/// Ítem del catálogo (schema `CatalogItem`, v0.3.0).
///
/// Trae los precios de las 3 listas (todos NO nullable; **0 es válido y ORDENABLE** —
/// muestras, publicidad, promociones). `has_price` es derivado (precio != 0) y solo es
/// informativo: NUNCA bloquea agregar al carrito. La app NO recalcula stock.
struct Item: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var itemCode: String        // PK; identificador del ítem
    var name: String
    var category: String?
    var barcode: String?
    var priceList1: Double      // precio en la lista 1 (0 = sin precio configurado, ordenable)
    var priceList2: Double
    var priceList3: Double
    var stock: Double?          // stock físico en SAP (informativo)
    var available: Double       // disponible ya calculado por el middleware
    var imageURL: String?       // descarga diferida; no viaja en el delta
    var active: Bool            // si false, la app no lo muestra

    var id: String { itemCode }

    static let databaseTableName = "items"

    enum CodingKeys: String, CodingKey {
        case itemCode = "item_code"
        case name, category, barcode
        case priceList1 = "price_list_1"
        case priceList2 = "price_list_2"
        case priceList3 = "price_list_3"
        case stock, available
        case imageURL = "image_url"
        case active
        // has_price_1/2/3 llegan en el JSON pero se DERIVAN de los precios (se ignoran).
    }

    /// Precio del ítem en la lista dada (1/2/3).
    func price(forList list: Int) -> Double {
        switch list {
        case 1: return priceList1
        case 2: return priceList2
        default: return priceList3
        }
    }

    /// ¿Hay precio configurado en esa lista? Informativo (precio 0 = sin configurar).
    func hasPrice(forList list: Int) -> Bool {
        price(forList: list) != 0
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
    var defaultPriceList: Int   // lista por defecto (de SAP); siempre está en las autorizadas
    /// Listas que el vendedor PUEDE usar con este cliente (1 o 2). GRDB la persiste como
    /// JSON en su columna. El selector por línea solo ofrece estas.
    var authorizedPriceLists: [Int]

    var id: String { clientCode }

    static let databaseTableName = "clients"

    enum CodingKeys: String, CodingKey {
        case clientCode = "client_code"
        case name, address, city, zipcode
        case managerName = "manager_name"
        case shippingRoute = "shipping_route"
        case defaultPriceList = "default_price_list"
        case authorizedPriceLists = "authorized_price_lists"
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
    var unitPrice: Double       // precio unitario = precio del ítem en la lista elegida
    var lineDiscountPct: Double // descuento de línea en % (0–100)
    var priceList: Int          // lista elegida para ESTA línea (1/2/3); obligatorio en v0.3.0

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
