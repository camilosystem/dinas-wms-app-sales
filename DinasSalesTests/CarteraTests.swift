import XCTest
import GRDB
@testable import DinasSales

/// Cartera (★ v0.4.0): persistencia del crédito, estado de cuenta offline, veredicto de
/// la orden, y que la advertencia NO bloquea la confirmación.
@MainActor
final class CarteraTests: XCTestCase {

    nonisolated private func credit(balance: Double = 100, limit: Double = 1_000,
                        hasOverdue: Bool = false, overdueCount: Int = 0,
                        overdueAmount: Double = 0, maxDaysOverdue: Int = 0) -> ClientCredit {
        ClientCredit(balance: balance, creditLimit: limit, creditAvailable: limit - balance,
                     overdueCount: overdueCount, overdueAmount: overdueAmount,
                     maxDaysOverdue: maxDaysOverdue, hasOverdue: hasOverdue, graceDays: 5)
    }

    nonisolated private func makeClient(_ code: String, credit: ClientCredit) -> Client {
        Client(clientCode: code, name: "Cliente \(code)", address: nil, city: nil, zipcode: nil,
               managerName: nil, shippingRoute: nil, defaultPriceList: 1,
               authorizedPriceLists: [1], active: true, credit: credit)
    }

    // MARK: - Crédito persiste en GRDB (round-trip)

    func test_credit_persisteYSeLeeDeLaBaseLocal() async throws {
        let db = try AppDatabase.makeInMemory()
        let c = makeClient("C1", credit: credit(balance: 250, limit: 1_000,
                                                hasOverdue: true, overdueCount: 2,
                                                overdueAmount: 500, maxDaysOverdue: 30))
        try await db.dbQueue.write { try c.insert($0) }

        let loaded = try ClientsRepository(database: db).client(code: "C1")
        XCTAssertEqual(loaded?.credit.balance, 250)
        XCTAssertEqual(loaded?.credit.creditAvailable, 750)
        XCTAssertTrue(loaded?.credit.hasOverdue ?? false)
        XCTAssertEqual(loaded?.credit.overdueCount, 2)
        XCTAssertEqual(loaded?.credit.status, .enMora, "cliente con mora se refleja")
    }

    // MARK: - Estado de cuenta offline

    func test_statement_seGuardaYSeConsultaOffline() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbQueue.write { try self.makeClient("C1", credit: self.credit()).insert($0) }

        let asOf = Date(timeIntervalSince1970: 1_000)
        let statement = ClientStatement(
            clientCode: "C1", clientName: "Tienda", credit: credit(),
            documents: [
                doc(.invoice, num: "F-1", openAmount: 1_000, daysOverdue: 12),
                doc(.invoice, num: "F-2", openAmount: 500, daysOverdue: -3),
                doc(.creditNote, num: "NC-1", openAmount: -200, daysOverdue: nil),
            ],
            asOf: asOf
        )
        let repo = StatementRepository(database: db)
        try repo.save(statement)

        // "Offline": simplemente leemos de la base, sin red.
        let docs = try repo.documents(clientCode: "C1")
        XCTAssertEqual(docs.count, 3)
        // Orden: la factura vencida (12 d) primero, luego la no vencida, y la NC al final.
        XCTAssertEqual(docs.map(\.docNum), ["F-1", "F-2", "NC-1"])
        XCTAssertTrue(docs[0].isOverdue)
        XCTAssertFalse(docs[1].isOverdue)
        XCTAssertEqual(docs[2].openAmount, -200, "la NC resta (negativo)")
        XCTAssertEqual(try repo.asOf(clientCode: "C1"), asOf)
    }

    func test_statement_reemplazaAlVolverABajar() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbQueue.write { try self.makeClient("C1", credit: self.credit()).insert($0) }
        let repo = StatementRepository(database: db)

        try repo.save(ClientStatement(clientCode: "C1", clientName: nil, credit: nil,
                                      documents: [doc(.invoice, num: "F-1", openAmount: 100, daysOverdue: 1)],
                                      asOf: nil))
        try repo.save(ClientStatement(clientCode: "C1", clientName: nil, credit: nil,
                                      documents: [doc(.invoice, num: "F-2", openAmount: 200, daysOverdue: 1)],
                                      asOf: nil))

        let docs = try repo.documents(clientCode: "C1")
        XCTAssertEqual(docs.map(\.docNum), ["F-2"], "la nueva bajada reemplaza la anterior")
    }

    nonisolated private func doc(_ type: StatementDocType, num: String, openAmount: Double,
                     daysOverdue: Int?) -> StatementDocument {
        StatementDocument(id: nil, clientCode: "", asOf: nil, docType: type, docNum: num,
                          docDate: Date(timeIntervalSince1970: 0),
                          dueDate: daysOverdue == nil ? nil : Date(timeIntervalSince1970: 0),
                          docTotal: abs(openAmount), openAmount: openAmount,
                          daysOverdue: daysOverdue, isFromSage: false, sageDocNumber: nil)
    }

    // MARK: - Veredicto de la orden (RETENIDA con motivo)

    func test_markSynced_guardaVeredictoYMotivoDeRetencion() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbQueue.write { database in
            try self.makeClient("C1", credit: self.credit()).insert(database)
            try Item(itemCode: "I1", name: "Item", category: nil, barcode: nil,
                     priceList1: 10, priceList2: 10, priceList3: 10, stock: nil,
                     available: 5, imageURL: nil, active: true).insert(database)
        }
        let repo = OrdersRepository(database: db, now: { Date(timeIntervalSince1970: 0) },
                                    makeUUID: { "ORD-1" })
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 2)
        try repo.confirm(orderUUID: order.clientUUID)

        try repo.markSynced(orderUUID: "ORD-1", orderNumber: "N-1",
                            creditVerdict: .retenidaCartera, holdReason: .mora)

        let saved = try repo.order(uuid: "ORD-1")
        XCTAssertEqual(saved?.status, .synced)
        XCTAssertEqual(saved?.creditVerdict, .retenidaCartera)
        XCTAssertEqual(saved?.holdReason, .mora)
    }

    func test_markSynced_aprobada_sinMotivo() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbQueue.write { database in
            try self.makeClient("C1", credit: self.credit()).insert(database)
            try Item(itemCode: "I1", name: "Item", category: nil, barcode: nil,
                     priceList1: 10, priceList2: 10, priceList3: 10, stock: nil,
                     available: 5, imageURL: nil, active: true).insert(database)
        }
        let repo = OrdersRepository(database: db, now: { Date(timeIntervalSince1970: 0) },
                                    makeUUID: { "ORD-1" })
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 1)
        try repo.confirm(orderUUID: order.clientUUID)

        try repo.markSynced(orderUUID: "ORD-1", orderNumber: "N-1", creditVerdict: .aprobada)

        let saved = try repo.order(uuid: "ORD-1")
        XCTAssertEqual(saved?.creditVerdict, .aprobada)
        XCTAssertNil(saved?.holdReason)
    }

    // MARK: - La advertencia NO bloquea la confirmación

    func test_confirmar_conAdvertencia_dejaContinuar() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbQueue.write { database in
            try self.makeClient("C1", credit: self.credit()).insert(database)
            try Item(itemCode: "I1", name: "Item", category: nil, barcode: nil,
                     priceList1: 500, priceList2: 500, priceList3: 500, stock: nil,
                     available: 5, imageURL: nil, active: true).insert(database)
        }
        let ordersRepo = OrdersRepository(database: db, now: { Date(timeIntervalSince1970: 0) },
                                          makeUUID: { "ORD-1" })
        let order = try ordersRepo.startOrder(clientCode: "C1")
        try ordersRepo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 3)

        // Cliente al límite: balance 900, cupo 1000. La orden (1500) excede.
        let vm = OrderCartViewModel(
            order: try ordersRepo.order(uuid: "ORD-1")!, clientName: "Tienda",
            authorizedPriceLists: [1], defaultPriceList: 1,
            credit: credit(balance: 900, limit: 1_000),
            orders: ordersRepo, catalog: CatalogRepository(database: db)
        )
        vm.reload()

        XCTAssertNotNil(vm.holdWarning, "se advierte que excede el cupo")
        XCTAssertTrue(vm.holdWarning!.exceedsCredit)
        // La app ADVIERTE pero NO bloquea: confirmar igual funciona.
        XCTAssertTrue(vm.confirm(), "el vendedor puede confirmar pese a la advertencia")
        XCTAssertEqual(try ordersRepo.order(uuid: "ORD-1")?.status, .confirmed)
    }

    func test_confirmar_clienteAlDia_sinAdvertencia() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbQueue.write { database in
            try self.makeClient("C1", credit: self.credit()).insert(database)
            try Item(itemCode: "I1", name: "Item", category: nil, barcode: nil,
                     priceList1: 10, priceList2: 10, priceList3: 10, stock: nil,
                     available: 5, imageURL: nil, active: true).insert(database)
        }
        let ordersRepo = OrdersRepository(database: db, now: { Date(timeIntervalSince1970: 0) },
                                          makeUUID: { "ORD-1" })
        let order = try ordersRepo.startOrder(clientCode: "C1")
        try ordersRepo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 2)

        let vm = OrderCartViewModel(
            order: try ordersRepo.order(uuid: "ORD-1")!, clientName: "Tienda",
            authorizedPriceLists: [1], defaultPriceList: 1,
            credit: credit(balance: 100, limit: 1_000),   // holgado, al día
            orders: ordersRepo, catalog: CatalogRepository(database: db)
        )
        vm.reload()

        XCTAssertNil(vm.holdWarning, "cliente al día y dentro de cupo: sin advertencia")
        XCTAssertTrue(vm.confirm())
    }

    // MARK: - Decodificación del JSON del contrato

    func test_decode_clientConCredit_desdeJSON() throws {
        let json = Data("""
        {"client_code":"C1","name":"Tienda","default_price_list":1,
         "authorized_price_lists":[1,2],
         "credit":{"balance":250.0,"credit_limit":1000.0,"credit_available":750.0,
                   "overdue_count":2,"overdue_amount":500.0,"max_days_overdue":30,
                   "has_overdue":true,"grace_days":5}}
        """.utf8)
        let c = try JSONCoding.decoder.decode(Client.self, from: json)
        XCTAssertEqual(c.credit.balance, 250)
        XCTAssertTrue(c.credit.hasOverdue)
        XCTAssertEqual(c.authorizedPriceLists, [1, 2])
        XCTAssertTrue(c.active, "active ausente en el JSON del servidor → default true")
    }

    func test_decode_statement_conFechasSoloDia() throws {
        // doc_date/due_date vienen como `format: date` (solo día); el decoder debe parsearlas.
        let json = Data("""
        {"client_code":"C1","client_name":"Tienda",
         "documents":[
           {"doc_type":"INVOICE","doc_num":"F-1","doc_date":"2026-07-01","due_date":"2026-07-10",
            "doc_total":100.0,"open_amount":100.0,"days_overdue":4,"is_from_sage":false},
           {"doc_type":"PAYMENT_ON_ACCOUNT","doc_num":"P-1","doc_date":"2026-07-05","due_date":null,
            "doc_total":50.0,"open_amount":-50.0,"days_overdue":null,"is_from_sage":true,
            "sage_doc_number":"S-99"}],
         "as_of":"2026-07-14T10:00:00Z"}
        """.utf8)
        let s = try JSONCoding.decoder.decode(ClientStatement.self, from: json)
        XCTAssertEqual(s.documents.count, 2)
        XCTAssertEqual(s.documents[0].docType, .invoice)
        XCTAssertNotNil(s.documents[0].docDate, "format: date se parsea (fallback dateOnly)")
        XCTAssertNil(s.documents[1].dueDate, "due_date null en pagos")
        XCTAssertEqual(s.documents[1].openAmount, -50)
        XCTAssertNotNil(s.asOf)
    }
}
