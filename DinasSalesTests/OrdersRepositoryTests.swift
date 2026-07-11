import XCTest
import GRDB
@testable import DinasSales

final class OrdersRepositoryTests: XCTestCase {

    /// Generador de UUIDs deterministas.
    private final class UUIDSeq {
        private var n = 0
        func next() -> String { n += 1; return "uuid-\(n)" }
    }

    private let fixedNow = Date(timeIntervalSince1970: 10_000)

    private func makeRepo(_ db: AppDatabase, seq: UUIDSeq = UUIDSeq()) -> OrdersRepository {
        OrdersRepository(database: db, now: { self.fixedNow }, makeUUID: seq.next)
    }

    private func seed(_ db: AppDatabase) throws {
        try db.dbQueue.write { database in
            try Client(clientCode: "C1", name: "Tienda Uno", address: nil, city: nil,
                       zipcode: nil, managerName: nil, shippingRoute: nil).insert(database)
            try Item(itemCode: "I1", name: "Item 1", category: nil, barcode: nil,
                     comments: nil, price: 10, stock: nil, available: 100,
                     imageURL: nil, active: true).insert(database)
            try Item(itemCode: "I2", name: "Item 2", category: nil, barcode: nil,
                     comments: nil, price: 5, stock: nil, available: 100,
                     imageURL: nil, active: true).insert(database)
        }
    }

    func test_startOrder_creaBorradorYNoDuplicaPorCliente() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        let repo = makeRepo(db)

        let a = try repo.startOrder(clientCode: "C1")
        XCTAssertEqual(a.status, .draft)
        XCTAssertEqual(a.clientUUID, "uuid-1")
        XCTAssertEqual(a.createdAt, fixedNow)

        // Segunda vez para el mismo cliente: mismo borrador, no crea otro.
        let b = try repo.startOrder(clientCode: "C1")
        XCTAssertEqual(b.clientUUID, "uuid-1")
        try db.dbQueue.read { XCTAssertEqual(try Order.fetchCount($0), 1) }
    }

    func test_setQuantity_creaLineaConPrecioDelCatalogo_yElimina() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")

        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", quantity: 3)
        var lines = try repo.lines(orderUUID: order.clientUUID)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].unitPrice, 10)   // tomado del catálogo
        XCTAssertEqual(lines[0].quantity, 3)

        // Actualiza cantidad (no duplica).
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", quantity: 7)
        lines = try repo.lines(orderUUID: order.clientUUID)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].quantity, 7)

        // Cantidad 0 elimina la línea.
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", quantity: 0)
        XCTAssertTrue(try repo.lines(orderUUID: order.clientUUID).isEmpty)
    }

    func test_setDiscount_clampeaYAfectaTotal() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", quantity: 2) // 2×10

        try repo.setDiscount(orderUUID: order.clientUUID, itemCode: "I1", percent: 150)
        let line = try repo.lines(orderUUID: order.clientUUID)[0]
        XCTAssertEqual(line.lineDiscountPct, 100)  // clamp a 100
        XCTAssertEqual(OrdersRepository.lineTotal(line), 0)

        try repo.setDiscount(orderUUID: order.clientUUID, itemCode: "I1", percent: 10)
        let line2 = try repo.lines(orderUUID: order.clientUUID)[0]
        XCTAssertEqual(OrdersRepository.lineTotal(line2), 18) // 2×10×0.9
    }

    func test_confirm_requiereLineas_yFijaTakenAt() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")

        // Sin líneas: no se puede confirmar.
        XCTAssertThrowsError(try repo.confirm(orderUUID: order.clientUUID)) { error in
            XCTAssertEqual(error as? OrdersError, .emptyOrder)
        }

        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", quantity: 1)
        try repo.confirm(orderUUID: order.clientUUID)

        let confirmed = try db.dbQueue.read { try Order.fetchOne($0, key: order.clientUUID) }
        XCTAssertEqual(confirmed?.status, .confirmed)
        XCTAssertEqual(confirmed?.takenAt, fixedNow)

        // Confirmar de nuevo (ya no es draft) falla.
        XCTAssertThrowsError(try repo.confirm(orderUUID: order.clientUUID)) { error in
            XCTAssertEqual(error as? OrdersError, .notADraft)
        }
    }

    func test_summaries_incluyeNombreClienteYTotal() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", quantity: 2) // 20
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I2", quantity: 4) // 20

        let summaries = try repo.summaries()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].clientName, "Tienda Uno")
        XCTAssertEqual(summaries[0].itemCount, 2)
        XCTAssertEqual(summaries[0].total, 40)
    }

    func test_deleteDraft_soloBorradores() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", quantity: 1)

        try repo.confirm(orderUUID: order.clientUUID)
        XCTAssertThrowsError(try repo.deleteDraft(orderUUID: order.clientUUID)) { error in
            XCTAssertEqual(error as? OrdersError, .notADraft)
        }
    }

    func test_deleteDraft_eliminaBorradorYSusLineasEnCascada() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", quantity: 2)
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I2", quantity: 1)

        try repo.deleteDraft(orderUUID: order.clientUUID)

        XCTAssertNil(try repo.order(uuid: order.clientUUID), "la orden se eliminó")
        try db.dbQueue.read { db in
            let lineCount = try OrderLine
                .filter(Column("order_uuid") == order.clientUUID).fetchCount(db)
            XCTAssertEqual(lineCount, 0, "las líneas se eliminaron en cascada")
        }
        XCTAssertTrue(try repo.summaries().isEmpty)
    }

    // MARK: - Regla de precio (cero es decisión; null es ausencia)

    /// Inserta un ítem con `price` explícito (posible cero o nil).
    private func seedItem(_ db: AppDatabase, code: String, price: Double?) throws {
        try db.dbQueue.write { database in
            try Item(itemCode: code, name: "Item \(code)", category: nil, barcode: nil,
                     comments: nil, price: price, stock: nil, available: 100,
                     imageURL: nil, active: true).insert(database)
        }
    }

    func test_setQuantity_precioCero_creaLineaEnCero() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        try seedItem(db, code: "PROMO", price: 0)          // línea regalada: 0 es válido
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")

        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "PROMO", quantity: 3)

        let lines = try repo.lines(orderUUID: order.clientUUID)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].unitPrice, 0)
        XCTAssertEqual(OrdersRepository.lineTotal(lines[0]), 0)
    }

    func test_ordenTotalCero_sePuedeConfirmar() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        try seedItem(db, code: "PROMO", price: 0)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "PROMO", quantity: 2)

        // Total en cero, pero con línea: se confirma sin problema.
        try repo.confirm(orderUUID: order.clientUUID)

        let confirmed = try db.dbQueue.read { try Order.fetchOne($0, key: order.clientUUID) }
        XCTAssertEqual(confirmed?.status, .confirmed)
        XCTAssertEqual(try repo.summaries().first?.total, 0)
    }

    func test_descuentoCien_esValido_totalCero() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", quantity: 2) // 2×10

        try repo.setDiscount(orderUUID: order.clientUUID, itemCode: "I1", percent: 100)

        let line = try repo.lines(orderUUID: order.clientUUID)[0]
        XCTAssertEqual(line.lineDiscountPct, 100)
        XCTAssertEqual(OrdersRepository.lineTotal(line), 0)
        // Y con descuento 100% la orden se puede confirmar.
        XCTAssertNoThrow(try repo.confirm(orderUUID: order.clientUUID))
    }

    func test_setQuantity_precioNull_noSePuedeAgregar() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        try seedItem(db, code: "SINPRECIO", price: nil)   // dato ausente: no ordenable
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")

        XCTAssertThrowsError(
            try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "SINPRECIO", quantity: 1)
        ) { error in
            XCTAssertEqual(error as? OrdersError, .itemNotOrderable)
        }
        XCTAssertTrue(try repo.lines(orderUUID: order.clientUUID).isEmpty, "no se creó línea")
    }
}
