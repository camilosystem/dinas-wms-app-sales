import Foundation
import GRDB

// Modelos de dominio persistidos en SQLite (GRDB).
// Nombres de columnas en snake_case para coincidir con el esquema SQL.

// MARK: - Item (catálogo)

/// Ítem del catálogo. La app NO recalcula stock: muestra `available` tal cual llega
/// del middleware.
struct Item: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: String              // código/identificador del ítem (viene del contrato)
    var code: String
    var name: String
    var available: Int          // disponible informado por el middleware; no se recalcula
    var comments: String?
    var imageURL: String?       // se descarga aparte, con caché (imágenes diferidas)
    var updatedAt: Date?        // para sync incremental (`since`)

    static let databaseTableName = "items"

    enum Columns {
        static let id = Column("id")
        static let code = Column("code")
        static let name = Column("name")
        static let available = Column("available")
        static let comments = Column("comments")
        static let imageURL = Column("image_url")
        static let updatedAt = Column("updated_at")
    }

    enum CodingKeys: String, CodingKey {
        case id, code, name, available, comments
        case imageURL = "image_url"
        case updatedAt = "updated_at"
    }
}

// MARK: - Client

/// Cliente asignado al vendedor. Solo se guardan los que devuelve `GET /sync/clients`.
struct Client: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: String              // identificador de cliente del middleware
    var name: String
    var address: String?
    var updatedAt: Date?

    static let databaseTableName = "clients"

    enum CodingKeys: String, CodingKey {
        case id, name, address
        case updatedAt = "updated_at"
    }
}

// MARK: - Order

/// Estado local de una orden: borrador → confirmada → sincronizada.
enum OrderStatus: String, Codable {
    case draft          // borrador
    case confirmed      // confirmada, pendiente de subir
    case synced         // sincronizada con el middleware
}

/// Orden tomada por el vendedor. Nace con un `clientUUID` (UUID v4) generado en el
/// dispositivo; ese UUID es la clave de idempotencia hacia `POST /orders` y NO se
/// regenera en reintentos.
struct Order: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var clientUUID: String      // UUID v4 local; clave de idempotencia (PK)
    var clientID: String        // cliente asignado
    var status: OrderStatus
    var createdAt: Date
    var confirmedAt: Date?
    var syncedAt: Date?

    var id: String { clientUUID }

    static let databaseTableName = "orders"

    enum CodingKeys: String, CodingKey {
        case clientUUID = "client_uuid"
        case clientID = "client_id"
        case status
        case createdAt = "created_at"
        case confirmedAt = "confirmed_at"
        case syncedAt = "synced_at"
    }
}

// MARK: - OrderLine

/// Línea de una orden: ítem, cantidad y descuento de línea.
/// (El descuento global está fuera del MVP.)
struct OrderLine: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: Int64?              // autoincrement local
    var orderUUID: String      // FK -> orders.client_uuid
    var itemID: String
    var quantity: Int
    var lineDiscount: Double    // descuento de línea (por ejemplo 0.0–1.0 o monto; se fija con el contrato)

    static let databaseTableName = "order_lines"

    enum CodingKeys: String, CodingKey {
        case id
        case orderUUID = "order_uuid"
        case itemID = "item_id"
        case quantity
        case lineDiscount = "line_discount"
    }

    // Deja que SQLite asigne el rowid autoincremental.
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - SyncState

/// Marca de agua por recurso para la sincronización incremental (`since`).
struct SyncState: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var resource: String        // "catalog" | "clients"
    var lastSyncedAt: Date?     // valor a enviar como `since` en la próxima bajada

    var id: String { resource }

    static let databaseTableName = "sync_state"

    enum CodingKeys: String, CodingKey {
        case resource
        case lastSyncedAt = "last_synced_at"
    }
}
