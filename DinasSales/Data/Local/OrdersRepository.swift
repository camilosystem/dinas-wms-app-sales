import Foundation
import GRDB

/// Resumen de una orden para listar (orden + nombre de cliente + totales).
struct OrderSummary: Identifiable, Equatable {
    let order: Order
    let clientName: String
    let itemCount: Int
    let total: Double
    /// Confirmada pero sin enviar por más de 7 días. Es una marca CALCULADA (no altera
    /// datos): el pedido se conserva; el vendedor decide si lo descarta o lo envía.
    let isOverdue: Bool

    var id: String { order.clientUUID }
}

/// Escritura y lectura de órdenes en la base local.
///
/// Flujo: cliente primero → borrador (draft) → confirmada (confirmed) → sincronizada (synced).
/// Una sola orden ACTIVA (draft) por cliente a la vez. El `client_uuid` se genera una
/// única vez al crear el borrador y es la clave de idempotencia (regla dura #3).
struct OrdersRepository {
    let database: AppDatabase
    /// Inyectables para tests deterministas.
    var now: () -> Date = Date.init
    var makeUUID: () -> String = { UUID().uuidString }

    /// Antigüedad tras la cual una orden confirmada sin enviar se considera "vencida".
    static let overdueAge: TimeInterval = 7 * 24 * 60 * 60

    /// ¿La orden está confirmada y lleva más de 7 días sin enviarse? (marca calculada)
    func isOverdue(_ order: Order) -> Bool {
        guard order.status == .confirmed, let takenAt = order.takenAt else { return false }
        return now().timeIntervalSince(takenAt) > Self.overdueAge
    }

    // MARK: - Ciclo de la orden

    /// Devuelve el borrador activo del cliente, o crea uno nuevo si no existe.
    /// Nunca hay dos borradores para el mismo cliente.
    @discardableResult
    func startOrder(clientCode: String) throws -> Order {
        try database.dbQueue.write { db in
            if let existing = try Order
                .filter(Column("client_code") == clientCode)
                .filter(Column("status") == OrderStatus.draft.rawValue)
                .fetchOne(db) {
                return existing
            }
            let order = Order(
                clientUUID: makeUUID(),
                clientCode: clientCode,
                status: .draft,
                notes: nil,
                createdAt: now(),
                takenAt: nil,
                syncedAt: nil,
                orderNumber: nil
            )
            try order.insert(db)
            return order
        }
    }

    /// Confirma un borrador: draft → confirmed y fija `taken_at`. Requiere ≥1 línea.
    func confirm(orderUUID: String) throws {
        try database.dbQueue.write { db in
            guard var order = try Order.fetchOne(db, key: orderUUID) else {
                throw OrdersError.orderNotFound
            }
            guard order.status == .draft else { throw OrdersError.notADraft }
            let count = try OrderLine.filter(Column("order_uuid") == orderUUID).fetchCount(db)
            guard count > 0 else { throw OrdersError.emptyOrder }

            order.status = .confirmed
            order.takenAt = now()
            try order.update(db)
        }
    }

    /// Marca una orden como sincronizada tras aceptarla el middleware.
    /// Marca la orden como sincronizada y guarda el VEREDICTO DE CARTERA del middleware
    /// (★ v0.4.0): APROBADA o RETENIDA_CARTERA, con su motivo. El estado local sigue
    /// siendo `.synced` (se envió con éxito); el veredicto es una dimensión aparte.
    func markSynced(orderUUID: String, orderNumber: String?,
                    creditVerdict: CreditVerdict? = nil, holdReason: HoldReason? = nil) throws {
        try database.dbQueue.write { db in
            guard var order = try Order.fetchOne(db, key: orderUUID) else {
                throw OrdersError.orderNotFound
            }
            order.status = .synced
            order.syncedAt = now()
            order.orderNumber = orderNumber
            order.creditVerdict = creditVerdict
            order.holdReason = holdReason
            try order.update(db)
        }
    }

    /// Aplica a una orden local YA ENVIADA (`.synced`) el estado ACTUAL bajado de
    /// `GET /sync/orders` (★ v0.4.1): refresca el veredicto de cartera y la decisión del
    /// admin (aprobó/rechazó + motivo). Núcleo ESTÁTICO para usarse dentro de una
    /// transacción de sincronización (sin abrir otra escritura anidada). `true` si actualizó.
    ///
    /// Solo toca órdenes `.synced`: no pisa borradores, confirmadas sin enviar, ni las
    /// rechazadas por error permanente (esas nunca entraron al ciclo del servidor).
    @discardableResult
    static func applyStatusUpdate(_ update: OrderStatusUpdate, in db: Database) throws -> Bool {
        // Match del UUID SIN distinguir mayúsculas: la app genera el `client_uuid` con
        // `UUID().uuidString` (MAYÚSCULAS) y el middleware .NET lo devuelve con
        // `Guid.ToString()` (minúsculas). La PK de SQLite es case-sensitive (BINARY), así
        // que un `fetchOne(key:)` directo no casaría y la decisión del admin se perdía.
        guard var order = try Order
                .filter(Column("client_uuid").collating(.nocase) == update.clientUUID)
                .fetchOne(db),
              order.status == .synced else { return false }
        if let verdict = update.status.flatMap(CreditVerdict.init(rawValue:)) {
            order.creditVerdict = verdict
        }
        // Al aprobar/rechazar, el servidor deja de enviar hold_reason (ya no está retenida).
        order.holdReason = update.holdReason.flatMap(HoldReason.init(rawValue:))
        order.decisionNote = update.decisionNote
        order.decidedAt = update.decidedAt
        // ★ v0.11.0 — resultado de la entrega. `deliveryReason` se guarda tal cual (texto ya
        // formateado por el middleware); nunca se parsea ni se traducen enums.
        order.deliveryStatus = update.deliveryStatus.flatMap(DeliveryStatus.init(rawValue:))
        order.deliveryReason = update.deliveryReason
        order.deliveredAt = update.deliveredAt
        if let number = update.orderNumber { order.orderNumber = number }
        try order.update(db)
        return true
    }

    /// Conveniencia (tests): aplica una actualización en su propia transacción.
    @discardableResult
    func applyStatusUpdate(_ update: OrderStatusUpdate) throws -> Bool {
        try database.dbQueue.write { try Self.applyStatusUpdate(update, in: $0) }
    }

    /// Marca una orden como RECHAZADA por un error permanente (400/404) con su motivo.
    /// Deja de reintentarse; el vendedor decidirá corregirla o descartarla. Nunca toca
    /// una ya sincronizada.
    func markRejected(orderUUID: String, reason: String) throws {
        try database.dbQueue.write { db in
            guard var order = try Order.fetchOne(db, key: orderUUID) else { return }
            guard order.status != .synced else { return }
            order.status = .rejected
            order.rejectionReason = reason
            try order.update(db)
        }
    }

    /// Órdenes rechazadas (requieren atención del vendedor).
    func rejectedOrders() throws -> [Order] {
        try database.dbQueue.read { db in
            try Order.filter(Column("status") == OrderStatus.rejected.rawValue)
                .order(Column("created_at")).fetchAll(db)
        }
    }

    /// Reabre una orden rechazada como BORRADOR para corregirla (limpia el motivo).
    func reopenRejected(orderUUID: String) throws {
        try database.dbQueue.write { db in
            guard var order = try Order.fetchOne(db, key: orderUUID) else { return }
            guard order.status == .rejected else { return }
            order.status = .draft
            order.rejectionReason = nil
            order.takenAt = nil
            try order.update(db)
        }
    }

    /// Borra un borrador (y sus líneas por cascada). Solo borradores.
    func deleteDraft(orderUUID: String) throws {
        try database.dbQueue.write { db in
            guard let order = try Order.fetchOne(db, key: orderUUID) else { return }
            guard order.status == .draft else { throw OrdersError.notADraft }
            try order.delete(db)
        }
    }

    /// Descarta (elimina) una orden NO sincronizada. Es una acción EXPLÍCITA del usuario;
    /// ningún temporizador ni caducidad la invoca. Las sincronizadas son registros y no
    /// se pueden descartar desde aquí.
    func discardOrder(orderUUID: String) throws {
        try database.dbQueue.write { db in
            guard let order = try Order.fetchOne(db, key: orderUUID) else { return }
            guard order.status != .synced else { throw OrdersError.cannotDiscardSynced }
            try order.delete(db)
        }
    }

    // MARK: - Líneas del carrito

    /// Fija la cantidad de un ítem en una LISTA DE PRECIO dada. La línea se identifica por
    /// (orden, ítem, lista): así el mismo ítem en listas distintas coexiste. `unit_price`
    /// toma el precio del ítem en esa lista — **0 es válido y ordenable** (v0.3.0).
    /// `quantity <= 0` elimina la línea.
    func setQuantity(orderUUID: String, itemCode: String, priceList: Int, quantity: Double) throws {
        try database.dbQueue.write { db in
            let existing = try OrderLine
                .filter(Column("order_uuid") == orderUUID)
                .filter(Column("item_code") == itemCode)
                .filter(Column("price_list") == priceList)
                .fetchOne(db)

            if quantity <= 0 {
                try existing?.delete(db)
                return
            }
            guard let item = try Item.fetchOne(db, key: itemCode) else {
                throw OrdersError.itemNotFound
            }
            let unitPrice = item.price(forList: priceList)   // 0 es un precio válido

            if var line = existing {
                line.quantity = quantity
                line.unitPrice = unitPrice
                try line.update(db)
            } else {
                var line = OrderLine(
                    id: nil, orderUUID: orderUUID, itemCode: itemCode, quantity: quantity,
                    unitPrice: unitPrice, lineDiscountPct: 0, priceList: priceList
                )
                try line.insert(db)
            }
        }
    }

    /// Fija el descuento de línea (%) de una línea concreta (por su id).
    func setDiscount(lineId: Int64, percent: Double) throws {
        let clamped = min(max(percent, 0), 100)
        try database.dbQueue.write { db in
            guard var line = try OrderLine.fetchOne(db, key: lineId) else { return }
            line.lineDiscountPct = clamped
            try line.update(db)
        }
    }

    /// Cambia la lista de precio de una línea → recomputa `unit_price` con esa lista.
    func setPriceList(lineId: Int64, priceList: Int) throws {
        try database.dbQueue.write { db in
            guard var line = try OrderLine.fetchOne(db, key: lineId) else { return }
            guard let item = try Item.fetchOne(db, key: line.itemCode) else {
                throw OrdersError.itemNotFound
            }
            line.priceList = priceList
            line.unitPrice = item.price(forList: priceList)
            try line.update(db)
        }
    }

    /// Elimina una línea del carrito (por su id).
    func removeLine(lineId: Int64) throws {
        try database.dbQueue.write { db in
            _ = try OrderLine.deleteOne(db, key: lineId)
        }
    }

    // MARK: - Lecturas

    /// Órdenes confirmadas pendientes de subir, más antiguas primero.
    func confirmedOrders() throws -> [Order] {
        try database.dbQueue.read { db in
            try Order
                .filter(Column("status") == OrderStatus.confirmed.rawValue)
                .order(Column("created_at"))
                .fetchAll(db)
        }
    }

    /// Una orden por su `client_uuid`.
    func order(uuid: String) throws -> Order? {
        try database.dbQueue.read { db in
            try Order.fetchOne(db, key: uuid)
        }
    }

    /// Líneas de una orden, con el nombre del ítem para mostrar.
    func lines(orderUUID: String) throws -> [OrderLine] {
        try database.dbQueue.read { db in
            try OrderLine
                .filter(Column("order_uuid") == orderUUID)
                .order(Column("id"))
                .fetchAll(db)
        }
    }

    /// Resúmenes de todas las órdenes, más recientes primero.
    func summaries() throws -> [OrderSummary] {
        try database.dbQueue.read { db in
            let orders = try Order.order(Column("created_at").desc).fetchAll(db)
            return try orders.map { order in
                let lines = try OrderLine
                    .filter(Column("order_uuid") == order.clientUUID).fetchAll(db)
                let clientName = try Client.fetchOne(db, key: order.clientCode)?.name
                    ?? order.clientCode
                return OrderSummary(
                    order: order,
                    clientName: clientName,
                    itemCount: lines.count,
                    total: Self.total(of: lines),
                    isOverdue: isOverdue(order)
                )
            }
        }
    }

    // MARK: - Totales

    /// Total de una línea: cantidad × precio × (1 − descuento%).
    static func lineTotal(_ line: OrderLine) -> Double {
        line.quantity * line.unitPrice * (1 - line.lineDiscountPct / 100)
    }

    /// Total de la orden (suma de líneas).
    static func total(of lines: [OrderLine]) -> Double {
        lines.reduce(0) { $0 + lineTotal($1) }
    }
}

enum OrdersError: Error, Equatable {
    case orderNotFound
    case notADraft
    case emptyOrder
    case itemNotFound
    case cannotDiscardSynced // no se descarta una orden ya sincronizada (es un registro)
}
