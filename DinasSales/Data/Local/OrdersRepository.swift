import Foundation
import GRDB

/// Resumen de una orden para listar (orden + nombre de cliente + totales).
struct OrderSummary: Identifiable, Equatable {
    let order: Order
    let clientName: String
    let itemCount: Int
    let total: Double

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
    func markSynced(orderUUID: String, orderNumber: String?) throws {
        try database.dbQueue.write { db in
            guard var order = try Order.fetchOne(db, key: orderUUID) else {
                throw OrdersError.orderNotFound
            }
            order.status = .synced
            order.syncedAt = now()
            order.orderNumber = orderNumber
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

    // MARK: - Líneas del carrito

    /// Fija la cantidad de un ítem en la orden. Si no existe la línea, la crea tomando
    /// el `unit_price` del catálogo (price de la lista asignada). `quantity <= 0` la elimina.
    func setQuantity(orderUUID: String, itemCode: String, quantity: Double) throws {
        try database.dbQueue.write { db in
            let existing = try OrderLine
                .filter(Column("order_uuid") == orderUUID)
                .filter(Column("item_code") == itemCode)
                .fetchOne(db)

            if quantity <= 0 {
                try existing?.delete(db)
                return
            }

            if var line = existing {
                line.quantity = quantity
                try line.update(db)
            } else {
                let item = try Item.fetchOne(db, key: itemCode)
                var line = OrderLine(
                    id: nil,
                    orderUUID: orderUUID,
                    itemCode: itemCode,
                    quantity: quantity,
                    unitPrice: item?.price ?? 0,
                    lineDiscountPct: 0,
                    priceList: nil
                )
                try line.insert(db)
            }
        }
    }

    /// Fija el descuento de línea (%) de un ítem ya presente en la orden.
    func setDiscount(orderUUID: String, itemCode: String, percent: Double) throws {
        let clamped = min(max(percent, 0), 100)
        try database.dbQueue.write { db in
            guard var line = try OrderLine
                .filter(Column("order_uuid") == orderUUID)
                .filter(Column("item_code") == itemCode)
                .fetchOne(db) else { return }
            line.lineDiscountPct = clamped
            try line.update(db)
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
                    total: Self.total(of: lines)
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
}
