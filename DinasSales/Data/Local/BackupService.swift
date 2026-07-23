import Foundation
import GRDB

// MARK: - Formato del archivo de backup (JSON legible)

/// Archivo de backup. Respalda SOLO el historial de órdenes: el catálogo y los clientes se
/// re-sincronizan del servidor, así que no se incluyen. Autocontenido y estable (no depende
/// del contrato OpenAPI): claves en snake_case, fechas ISO-8601.
struct OrdersBackup: Codable, Equatable {
    static let currentFormat = "dinas-ventas-orders-backup"
    static let currentVersion = 1

    var format: String
    var version: Int
    var exportedAt: Date
    var username: String?
    var orders: [BackupOrder]

    enum CodingKeys: String, CodingKey {
        case format, version, username, orders
        case exportedAt = "exported_at"
    }
}

/// Una orden en el backup (con sus líneas, cliente, total y estado — legible).
struct BackupOrder: Codable, Equatable {
    var clientUUID: String
    var clientCode: String
    var clientName: String?
    var orderNumber: String?
    var status: String
    var notes: String?
    var createdAt: Date
    var takenAt: Date?
    var syncedAt: Date?
    var total: Double
    var rejectionReason: String?
    var creditVerdict: String?
    var holdReason: String?
    var decisionNote: String?
    var decidedAt: Date?
    var deliveryStatus: String?
    var deliveryReason: String?
    var deliveredAt: Date?
    var lines: [BackupLine]

    enum CodingKeys: String, CodingKey {
        case clientUUID = "client_uuid"
        case clientCode = "client_code"
        case clientName = "client_name"
        case orderNumber = "order_number"
        case status, notes, total, lines
        case createdAt = "created_at"
        case takenAt = "taken_at"
        case syncedAt = "synced_at"
        case rejectionReason = "rejection_reason"
        case creditVerdict = "credit_verdict"
        case holdReason = "hold_reason"
        case decisionNote = "decision_note"
        case decidedAt = "decided_at"
        case deliveryStatus = "delivery_status"
        case deliveryReason = "delivery_reason"
        case deliveredAt = "delivered_at"
    }
}

/// Una línea de orden en el backup.
struct BackupLine: Codable, Equatable {
    var itemCode: String
    var itemName: String?
    var quantity: Double
    var unitPrice: Double
    var lineDiscountPct: Double
    var priceList: Int

    enum CodingKeys: String, CodingKey {
        case itemCode = "item_code"
        case itemName = "item_name"
        case quantity
        case unitPrice = "unit_price"
        case lineDiscountPct = "line_discount_pct"
        case priceList = "price_list"
    }
}

/// Resultado de una restauración.
struct RestoreSummary: Equatable {
    var restored: Int   // órdenes insertadas
    var skipped: Int    // órdenes que ya existían localmente (no se duplicaron)
}

enum BackupError: LocalizedError, Equatable {
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "El archivo no es un backup válido de órdenes de Dinas Ventas."
        }
    }
}

// MARK: - Servicio

/// Exporta e importa el historial de órdenes (backup/restauración). Toda la lógica vive aquí,
/// separada de la UI, para poder testearla.
struct BackupService {
    let database: AppDatabase

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Exporta el HISTORIAL: todas las órdenes NO borrador (tomadas/sincronizadas) con sus líneas.
    /// Los borradores en curso no son "historial" y se omiten.
    func exportBackup(username: String?, now: Date) throws -> OrdersBackup {
        let orders = try database.dbQueue.read { db -> [BackupOrder] in
            let rows = try Order
                .filter(Column("status") != OrderStatus.draft.rawValue)
                .order(Column("created_at"))
                .fetchAll(db)
            return try rows.map { order in
                let lines = try OrderLine
                    .filter(Column("order_uuid") == order.clientUUID).fetchAll(db)
                let clientName = try Client.fetchOne(db, key: order.clientCode)?.name
                return BackupOrder(
                    clientUUID: order.clientUUID,
                    clientCode: order.clientCode,
                    clientName: clientName,
                    orderNumber: order.orderNumber,
                    status: order.status.rawValue,
                    notes: order.notes,
                    createdAt: order.createdAt,
                    takenAt: order.takenAt,
                    syncedAt: order.syncedAt,
                    total: OrdersRepository.total(of: lines),
                    rejectionReason: order.rejectionReason,
                    creditVerdict: order.creditVerdict?.rawValue,
                    holdReason: order.holdReason?.rawValue,
                    decisionNote: order.decisionNote,
                    decidedAt: order.decidedAt,
                    deliveryStatus: order.deliveryStatus?.rawValue,
                    deliveryReason: order.deliveryReason,
                    deliveredAt: order.deliveredAt,
                    lines: lines.map { line in
                        BackupLine(itemCode: line.itemCode, itemName: nil,
                                   quantity: line.quantity, unitPrice: line.unitPrice,
                                   lineDiscountPct: line.lineDiscountPct, priceList: line.priceList)
                    }
                )
            }
        }
        // Rellena los nombres de ítem (legibilidad) fuera del map anterior para no complicarlo.
        let withNames = try database.dbQueue.read { db -> [BackupOrder] in
            try orders.map { var o = $0
                o.lines = try o.lines.map { var l = $0
                    l.itemName = try Item.fetchOne(db, key: l.itemCode)?.name
                    return l
                }
                return o
            }
        }
        return OrdersBackup(format: OrdersBackup.currentFormat, version: OrdersBackup.currentVersion,
                            exportedAt: now, username: username, orders: withNames)
    }

    /// Codifica el backup a datos JSON (para el archivo a compartir).
    func exportData(username: String?, now: Date) throws -> Data {
        try Self.makeEncoder().encode(exportBackup(username: username, now: now))
    }

    /// Decodifica y VALIDA el formato de un archivo de backup. Lanza `BackupError.invalidFormat`
    /// si el JSON es inválido o no es un backup de órdenes de Dinas Ventas (manejo con gracia).
    func decode(_ data: Data) throws -> OrdersBackup {
        let backup: OrdersBackup
        do {
            backup = try Self.makeDecoder().decode(OrdersBackup.self, from: data)
        } catch {
            throw BackupError.invalidFormat
        }
        guard backup.format == OrdersBackup.currentFormat else { throw BackupError.invalidFormat }
        return backup
    }

    /// Restaura las órdenes del backup en la base local. NO duplica: si ya existe una orden con
    /// el mismo `client_uuid` o el mismo `order_number`, la salta. Devuelve el resumen.
    @discardableResult
    func restore(_ backup: OrdersBackup) throws -> RestoreSummary {
        try database.dbQueue.write { db in
            var existingUUIDs = Set(try String.fetchAll(db, sql: "SELECT client_uuid FROM orders"))
            var existingNumbers = Set(try String.fetchAll(
                db, sql: "SELECT order_number FROM orders WHERE order_number IS NOT NULL"))

            var restored = 0, skipped = 0
            for backupOrder in backup.orders {
                let dupByUUID = existingUUIDs.contains(backupOrder.clientUUID)
                let dupByNumber = backupOrder.orderNumber.map { existingNumbers.contains($0) } ?? false
                if dupByUUID || dupByNumber { skipped += 1; continue }

                var order = Order(
                    clientUUID: backupOrder.clientUUID,
                    clientCode: backupOrder.clientCode,
                    status: OrderStatus(rawValue: backupOrder.status) ?? .synced,
                    notes: backupOrder.notes,
                    createdAt: backupOrder.createdAt,
                    takenAt: backupOrder.takenAt,
                    syncedAt: backupOrder.syncedAt,
                    orderNumber: backupOrder.orderNumber,
                    rejectionReason: backupOrder.rejectionReason,
                    creditVerdict: backupOrder.creditVerdict.flatMap(CreditVerdict.init(rawValue:)),
                    holdReason: backupOrder.holdReason.flatMap(HoldReason.init(rawValue:)),
                    decisionNote: backupOrder.decisionNote,
                    decidedAt: backupOrder.decidedAt,
                    deliveryStatus: backupOrder.deliveryStatus.flatMap(DeliveryStatus.init(rawValue:)),
                    deliveryReason: backupOrder.deliveryReason,
                    deliveredAt: backupOrder.deliveredAt)
                try order.insert(db)
                for backupLine in backupOrder.lines {
                    var line = OrderLine(id: nil, orderUUID: backupOrder.clientUUID,
                                         itemCode: backupLine.itemCode, quantity: backupLine.quantity,
                                         unitPrice: backupLine.unitPrice,
                                         lineDiscountPct: backupLine.lineDiscountPct,
                                         priceList: backupLine.priceList)
                    try line.insert(db)
                }
                existingUUIDs.insert(backupOrder.clientUUID)
                if let number = backupOrder.orderNumber { existingNumbers.insert(number) }
                restored += 1
            }
            return RestoreSummary(restored: restored, skipped: skipped)
        }
    }
}
