import Foundation
import GRDB

// MARK: - Enums (catálogos cerrados del contrato v0.17.7)

/// Cómo pagó el cliente al vendedor (`AccountPaymentMethod`). Distinto de `PaymentType` del
/// driver (efectivo recogido en ruta). Catálogo cerrado — no agregar opciones.
enum AccountPaymentMethod: String, Codable, CaseIterable, Equatable {
    case efectivo = "EFECTIVO"
    case cheque = "CHEQUE"
    case transferencia = "TRANSFERENCIA"
    case otro = "OTRO"
}

/// Motivo del ajuste (`CreditRequestReason`). Catálogo cerrado. La cuenta G/L la resuelve el
/// middleware al aprobar (no en la app).
enum CreditRequestReason: String, Codable, CaseIterable, Equatable {
    case damaged = "DAMAGED"
    case doesntWantIt = "DOESNT_WANT_IT"
    case mistake = "MISTAKE"
    case short = "SHORT"
}

/// Modalidad de la solicitud. El contrato la infiere por la presencia de `lines`; localmente la
/// guardamos explícita para la UI y para armar el POST correcto.
enum CreditRequestMode: String, Codable, Equatable {
    case conItems = "CON_ITEMS"
    case sinItems = "SIN_ITEMS"
}

/// Estado del registro en la COLA local. Clave del diseño offline (v0.17.7):
/// - `.queued`: envío SIN foto, en cola local pendiente de subir (lo sube el `SyncEngine`).
/// - `.synced`: ya está en el servidor. Sea porque se subió desde la cola, o porque se envió
///   SÍNCRONO con foto (ese flujo nunca pasa por la cola: subir foto → crear, misma sesión).
enum QueueSyncStatus: String, Codable, Equatable {
    case queued
    case synced
}

/// Imputación propuesta a UNA factura (`InvoiceApplication`). Parte de `proposed_applications`.
struct InvoiceApplication: Codable, Equatable {
    var invoiceDocNum: String
    var amount: Double

    enum CodingKeys: String, CodingKey {
        case invoiceDocNum = "invoice_doc_num"
        case amount
    }
}

// MARK: - Pago de cartera (cola local)

/// Un pago de cartera reportado por el vendedor (`account-payments`, ★ v0.17.0). Registro LOCAL:
/// `payment_uuid` se genera AL CREAR (no al subir) para que la idempotencia funcione aunque el
/// registro pase tiempo en la cola. `sync_status` distingue en-cola vs ya-enviado.
///
/// ⚠️ `client_uuid`: el contrato lo exige, pero NO hay fuente local (el `Client`/`GET /sync/clients`
/// no trae un uuid de cliente). Se guarda el campo; su ORIGEN queda pendiente de resolver con el
/// Arquitecto antes de armar el POST (ver reporte). NO se inventa un valor aquí.
struct AccountPayment: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var paymentUUID: String            // PK; idempotencia (generado al crear)
    var clientUUID: String             // ⚠️ requerido por el contrato, sin fuente local aún
    var clientCode: String
    var method: AccountPaymentMethod
    var amount: Double
    var paymentDate: Date              // `format: date` en el contrato
    var comments: String?
    /// Solo si el vendedor adjuntó foto (flujo síncrono). `nil` en los envíos en cola sin foto.
    var evidenceImageURL: String?
    /// Imputación PROPUESTA (opcional). GRDB la persiste como JSON en su columna.
    var proposedApplications: [InvoiceApplication]
    var syncStatus: QueueSyncStatus
    var createdAt: Date
    var syncedAt: Date?

    var id: String { paymentUUID }
    static let databaseTableName = "account_payments"

    enum CodingKeys: String, CodingKey {
        case paymentUUID = "payment_uuid"
        case clientUUID = "client_uuid"
        case clientCode = "client_code"
        case method, amount, comments
        case paymentDate = "payment_date"
        case evidenceImageURL = "evidence_image_url"
        case proposedApplications = "proposed_applications"
        case syncStatus = "sync_status"
        case createdAt = "created_at"
        case syncedAt = "synced_at"
    }
}

// MARK: - Solicitud de crédito (cola local)

/// Una solicitud de crédito (`credit-requests`, ★ v0.17.0). `request_uuid` generado al crear.
/// CON_ITEMS guarda además sus líneas (`CreditRequestLine`); el `unit_price` NO se calcula ni se
/// guarda — lo resuelve el middleware al aprobar (último precio facturado). Mismo `client_uuid`
/// pendiente que `AccountPayment`.
struct CreditRequest: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var requestUUID: String            // PK; idempotencia
    var clientUUID: String             // ⚠️ requerido por el contrato, sin fuente local aún
    var clientCode: String
    var mode: CreditRequestMode
    var reason: CreditRequestReason    // motivo (encabezado); obligatorio en ambas modalidades
    var manualAmount: Double?          // requerido en SIN_ITEMS
    var invoiceDocNum: String?         // opcional (crédito general si se omite)
    var comments: String?
    var evidenceImageURL: String?
    var syncStatus: QueueSyncStatus
    var createdAt: Date
    var syncedAt: Date?

    var id: String { requestUUID }
    static let databaseTableName = "credit_requests"

    enum CodingKeys: String, CodingKey {
        case requestUUID = "request_uuid"
        case clientUUID = "client_uuid"
        case clientCode = "client_code"
        case mode, reason, comments
        case manualAmount = "manual_amount"
        case invoiceDocNum = "invoice_doc_num"
        case evidenceImageURL = "evidence_image_url"
        case syncStatus = "sync_status"
        case createdAt = "created_at"
        case syncedAt = "synced_at"
    }
}

/// Línea de una solicitud CON_ITEMS (`CreditRequestLine`). El vendedor define `item_code`,
/// `quantity` y `reason`; el `unit_price`/monto lo resuelve el middleware server-side.
struct CreditRequestLine: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: Int64?
    var requestUUID: String            // FK → credit_requests.request_uuid
    var itemCode: String
    var quantity: Double
    var reason: CreditRequestReason    // el contrato lo exige por línea

    static let databaseTableName = "credit_request_lines"

    enum CodingKeys: String, CodingKey {
        case id
        case requestUUID = "request_uuid"
        case itemCode = "item_code"
        case quantity, reason
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
