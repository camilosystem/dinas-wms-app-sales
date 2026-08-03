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
            // Cliente con 2 listas autorizadas (1 y 2): L1 = precio base, L2 = otro.
            try Client(clientCode: "C1", name: "Tienda Uno", address: nil, city: nil,
                       zipcode: nil, managerName: nil, shippingRoute: nil,
                       defaultPriceList: 1, authorizedPriceLists: [1, 2]).insert(database)
            try Item(itemCode: "I1", name: "Item 1", category: nil, barcode: nil,
                     priceList1: 10, priceList2: 8, priceList3: 0, stock: nil,
                     available: 100, imageURL: nil, active: true).insert(database)
            try Item(itemCode: "I2", name: "Item 2", category: nil, barcode: nil,
                     priceList1: 5, priceList2: 4, priceList3: 0, stock: nil,
                     available: 100, imageURL: nil, active: true).insert(database)
        }
    }

    /// Id de la (primera) línea de un ítem en una orden.
    private func lineId(_ repo: OrdersRepository, _ uuid: String, _ item: String,
                        priceList: Int = 1) throws -> Int64 {
        try repo.lines(orderUUID: uuid).first { $0.itemCode == item && $0.priceList == priceList }!.id!
    }

    // MARK: - Promociones (★ v0.28.0)

    func test_addPromotionBlock_insertaLineasConGrupoCompartido_yPrecioDeCatalogo() throws {
        let db = try AppDatabase.makeInMemory(); try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")

        try repo.addPromotionBlock(
            orderUUID: order.clientUUID, promotionGroupId: "promo-1", title: "2x1 Item",
            priceList: 1,
            lines: [PromotionLineInput(itemCode: "I1", quantity: 2, discountPct: 0),    // condición
                    PromotionLineInput(itemCode: "I2", quantity: 1, discountPct: 100)]) // beneficio gratis

        let lines = try repo.lines(orderUUID: order.clientUUID)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.promotionGroupId == "promo-1" }, "comparten el group id")
        XCTAssertTrue(lines.allSatisfy { $0.promotionTitle == "2x1 Item" }, "guardan el título local")
        let benefit = lines.first { $0.itemCode == "I2" }
        XCTAssertEqual(benefit?.lineDiscountPct, 100, "beneficio con su descuento")
        XCTAssertEqual(benefit?.unitPrice, 5, "unit_price del catálogo (I2 lista 1 = 5)")
        XCTAssertTrue(lines.allSatisfy { $0.isPromotion })
    }

    func test_removePromotionBlock_borraTodoElBloque_peroNoLasNormales() throws {
        let db = try AppDatabase.makeInMemory(); try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")
        // Línea normal + bloque de promoción sobre el MISMO ítem I1.
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 3)
        try repo.addPromotionBlock(orderUUID: order.clientUUID, promotionGroupId: "promo-1",
                                   title: "P", priceList: 1,
                                   lines: [PromotionLineInput(itemCode: "I1", quantity: 2, discountPct: 0)])
        XCTAssertEqual(try repo.lines(orderUUID: order.clientUUID).count, 2)

        try repo.removePromotionBlock(orderUUID: order.clientUUID, promotionGroupId: "promo-1")
        let left = try repo.lines(orderUUID: order.clientUUID)
        XCTAssertEqual(left.count, 1, "solo queda la normal")
        XCTAssertFalse(left[0].isPromotion)
        XCTAssertEqual(left[0].quantity, 3)
    }

    func test_setQuantity_noTocaLaLineaDePromocionDelMismoItem() throws {
        let db = try AppDatabase.makeInMemory(); try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")
        try repo.addPromotionBlock(orderUUID: order.clientUUID, promotionGroupId: "promo-1",
                                   title: "P", priceList: 1,
                                   lines: [PromotionLineInput(itemCode: "I1", quantity: 2, discountPct: 0)])
        // El picker fija I1 lista 1 a 5: debe crear/editar una línea NORMAL aparte, no la de promo.
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 5)

        let lines = try repo.lines(orderUUID: order.clientUUID).sorted { $0.quantity < $1.quantity }
        XCTAssertEqual(lines.count, 2, "coexisten la de promo y la normal")
        XCTAssertEqual(lines.first { $0.isPromotion }?.quantity, 2, "la de promo quedó intacta")
        XCTAssertEqual(lines.first { !$0.isPromotion }?.quantity, 5, "la normal es la editable")
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

        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 3)
        var lines = try repo.lines(orderUUID: order.clientUUID)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].unitPrice, 10)   // tomado del catálogo
        XCTAssertEqual(lines[0].quantity, 3)

        // Actualiza cantidad (no duplica).
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 7)
        lines = try repo.lines(orderUUID: order.clientUUID)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].quantity, 7)

        // Cantidad 0 elimina la línea.
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 0)
        XCTAssertTrue(try repo.lines(orderUUID: order.clientUUID).isEmpty)
    }

    func test_setDiscount_clampeaYAfectaTotal() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 2) // 2×10

        let id = try lineId(repo, order.clientUUID, "I1")
        try repo.setDiscount(lineId: id, percent: 150)
        let line = try repo.lines(orderUUID: order.clientUUID)[0]
        XCTAssertEqual(line.lineDiscountPct, 100)  // clamp a 100
        XCTAssertEqual(OrdersRepository.lineTotal(line), 0)

        try repo.setDiscount(lineId: id, percent: 10)
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

        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 1)
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
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 2) // 20
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I2", priceList: 1, quantity: 4) // 20

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
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 1)

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
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 2)
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I2", priceList: 1, quantity: 1)

        try repo.deleteDraft(orderUUID: order.clientUUID)

        XCTAssertNil(try repo.order(uuid: order.clientUUID), "la orden se eliminó")
        try db.dbQueue.read { db in
            let lineCount = try OrderLine
                .filter(Column("order_uuid") == order.clientUUID).fetchCount(db)
            XCTAssertEqual(lineCount, 0, "las líneas se eliminaron en cascada")
        }
        XCTAssertTrue(try repo.summaries().isEmpty)
    }

    // MARK: - Listas de precio (v0.3.0): $0 ordenable, price_list por línea

    /// Ítem con price_list_3 = 0 (has_price_3 = false) se puede agregar y ordenar.
    func test_itemPriceList3EnCero_seAgregaYOrdena() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)                                  // I1: L1=10, L2=8, L3=0
        let repo = makeRepo(db)
        let item = try CatalogRepository(database: db).item(code: "I1")!
        XCTAssertFalse(item.hasPrice(forList: 3), "price_list_3 = 0 → has_price_3 = false (informativo)")
        let order = try repo.startOrder(clientCode: "C1")

        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 3, quantity: 2)

        let line = try repo.lines(orderUUID: order.clientUUID)[0]
        XCTAssertEqual(line.unitPrice, 0, "unit_price de la lista 3 = 0, válido")
        XCTAssertEqual(line.priceList, 3)
        // has_price_3 = false NO impide confirmar/ordenar.
        XCTAssertNoThrow(try repo.confirm(orderUUID: order.clientUUID))
    }

    /// La línea toma el unit_price y el price_list de la lista elegida (y viaja así en el DTO).
    func test_lineaTomaUnitPriceYPriceListDeLaListaElegida() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")

        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 2, quantity: 1)
        let line = try repo.lines(orderUUID: order.clientUUID)[0]
        XCTAssertEqual(line.priceList, 2)
        XCTAssertEqual(line.unitPrice, 8, "precio de la lista 2")

        // El DTO de subida lleva el price_list y unit_price correctos.
        let dto = OrderCreateDTO(order: try repo.order(uuid: order.clientUUID)!, lines: [line])
        XCTAssertEqual(dto.lines.first?.priceList, 2)
        XCTAssertEqual(dto.lines.first?.unitPrice, 8)
    }

    /// El DTO incluye promotion_group_id en las líneas de promo y lo OMITE en las normales.
    func test_dto_promotionGroupId_soloEnLineasDePromocion() throws {
        let db = try AppDatabase.makeInMemory(); try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 1)
        try repo.addPromotionBlock(orderUUID: order.clientUUID, promotionGroupId: "G-9", title: "P",
                                   priceList: 1,
                                   lines: [PromotionLineInput(itemCode: "I2", quantity: 1, discountPct: 100)])
        let lines = try repo.lines(orderUUID: order.clientUUID)
        let dto = OrderCreateDTO(order: try repo.order(uuid: order.clientUUID)!, lines: lines)

        let data = try JSONEncoder().encode(dto)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let jsonLines = obj["lines"] as! [[String: Any]]
        let normal = jsonLines.first { ($0["item_code"] as? String) == "I1" }!
        let promo = jsonLines.first { ($0["item_code"] as? String) == "I2" }!
        XCTAssertNil(normal["promotion_group_id"], "línea normal: sin la clave")
        XCTAssertEqual(promo["promotion_group_id"] as? String, "G-9")
        XCTAssertEqual(promo["line_discount_pct"] as? Double, 100)
    }

    /// Cambiar la lista de una línea recomputa su unit_price.
    func test_cambiarListaDeLinea_recomputaUnitPrice() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 1)
        let id = try lineId(repo, order.clientUUID, "I1", priceList: 1)

        try repo.setPriceList(lineId: id, priceList: 2)

        let line = try repo.lines(orderUUID: order.clientUUID)[0]
        XCTAssertEqual(line.priceList, 2)
        XCTAssertEqual(line.unitPrice, 8)
    }

    /// Dos líneas del mismo ítem con listas distintas coexisten.
    func test_dosLineasMismoItemListasDistintas_coexisten() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")

        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 2)
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 2, quantity: 3)

        let lines = try repo.lines(orderUUID: order.clientUUID)
        XCTAssertEqual(lines.count, 2, "mismo ítem en 2 listas → 2 líneas distintas")
        XCTAssertEqual(Set(lines.map(\.priceList)), [1, 2])
        XCTAssertEqual(lines.first { $0.priceList == 1 }?.unitPrice, 10)
        XCTAssertEqual(lines.first { $0.priceList == 2 }?.unitPrice, 8)
    }

    func test_descuentoCien_esValido_totalCero() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        let repo = makeRepo(db)
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 2) // 2×10

        try repo.setDiscount(lineId: try lineId(repo, order.clientUUID, "I1"), percent: 100)

        let line = try repo.lines(orderUUID: order.clientUUID)[0]
        XCTAssertEqual(line.lineDiscountPct, 100)
        XCTAssertEqual(OrdersRepository.lineTotal(line), 0)
        XCTAssertNoThrow(try repo.confirm(orderUUID: order.clientUUID))
    }

    // MARK: - Pedidos vencidos (>7 días sin enviar) — nunca se borran solos

    private let ahora = Date(timeIntervalSince1970: 10_000_000)

    /// Crea y confirma una orden con `takenAt` = ahora − `daysAgo` días.
    @discardableResult
    private func confirmedOrder(_ db: AppDatabase, uuid: String, daysAgo: Double) throws -> String {
        let taken = ahora.addingTimeInterval(-daysAgo * 24 * 3600)
        let creator = OrdersRepository(database: db, now: { taken }, makeUUID: { uuid })
        let order = try creator.startOrder(clientCode: "C1")
        try creator.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 1)
        try creator.confirm(orderUUID: order.clientUUID)
        return order.clientUUID
    }

    func test_confirmadaMasDe7dias_seMarcaVencida_yPersiste() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        try confirmedOrder(db, uuid: "ORD-1", daysAgo: 8)   // vencida
        try confirmedOrder(db, uuid: "ORD-2", daysAgo: 3)   // reciente
        let repo = OrdersRepository(database: db, now: { self.ahora })

        let summaries = try repo.summaries()
        let byId = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        XCTAssertEqual(byId["ORD-1"]?.isOverdue, true, "8 días → vencida")
        XCTAssertEqual(byId["ORD-2"]?.isOverdue, false, "3 días → no vencida")
        // Y ambas SIGUEN existiendo: marcar vencida no borra nada.
        XCTAssertEqual(try repo.confirmedOrders().count, 2)
    }

    func test_vencida_sePuedeDescartar_soloConAccionExplicita() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        try confirmedOrder(db, uuid: "ORD-1", daysAgo: 10)
        let repo = OrdersRepository(database: db, now: { self.ahora })

        // Leer/marcar vencida NO borra.
        _ = try repo.summaries()
        _ = try repo.confirmedOrders()
        XCTAssertEqual(try repo.confirmedOrders().count, 1, "leer no borra")

        // Solo el descarte EXPLÍCITO la elimina.
        try repo.discardOrder(orderUUID: "ORD-1")
        XCTAssertNil(try repo.order(uuid: "ORD-1"))
        XCTAssertTrue(try repo.confirmedOrders().isEmpty)
    }

    func test_discardOrder_noBorraSincronizadas() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        try confirmedOrder(db, uuid: "ORD-1", daysAgo: 10)
        let repo = OrdersRepository(database: db, now: { self.ahora })
        try repo.markSynced(orderUUID: "ORD-1", orderNumber: "N-1")

        XCTAssertThrowsError(try repo.discardOrder(orderUUID: "ORD-1")) { error in
            XCTAssertEqual(error as? OrdersError, .cannotDiscardSynced)
        }
        XCTAssertNotNil(try repo.order(uuid: "ORD-1"), "una sincronizada es un registro; no se borra")
    }

    // MARK: - Órdenes rechazadas (error permanente) — requieren atención

    func test_rechazada_seMuestraConMotivo_yNoCuentaComoConfirmada() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        try confirmedOrder(db, uuid: "ORD-1", daysAgo: 0)
        let repo = OrdersRepository(database: db, now: { self.ahora })

        try repo.markRejected(orderUUID: "ORD-1", reason: "Cliente inválido")

        let rechazadas = try repo.rejectedOrders()
        XCTAssertEqual(rechazadas.map(\.clientUUID), ["ORD-1"])
        XCTAssertEqual(rechazadas.first?.rejectionReason, "Cliente inválido")
        // No cuenta en el badge de pendientes (no es confirmada).
        XCTAssertTrue(try repo.confirmedOrders().isEmpty)
    }

    func test_rechazada_sePuedeDescartar_soloExplicitamente() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        try confirmedOrder(db, uuid: "ORD-1", daysAgo: 0)
        let repo = OrdersRepository(database: db, now: { self.ahora })
        try repo.markRejected(orderUUID: "ORD-1", reason: "Motivo")

        // Leer las rechazadas NO borra nada.
        _ = try repo.rejectedOrders()
        XCTAssertNotNil(try repo.order(uuid: "ORD-1"))

        // Solo el descarte explícito la elimina.
        try repo.discardOrder(orderUUID: "ORD-1")
        XCTAssertNil(try repo.order(uuid: "ORD-1"))
    }

    func test_reopenRejected_vuelveABorradorParaCorregir() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db)
        try confirmedOrder(db, uuid: "ORD-1", daysAgo: 0)
        let repo = OrdersRepository(database: db, now: { self.ahora })
        try repo.markRejected(orderUUID: "ORD-1", reason: "Motivo")

        try repo.reopenRejected(orderUUID: "ORD-1")

        let order = try repo.order(uuid: "ORD-1")
        XCTAssertEqual(order?.status, .draft)
        XCTAssertNil(order?.rejectionReason)
    }

    // MARK: - Filtro por día (taken_at)

    private func summary(uuid: String, taken: Date?) -> OrderSummary {
        OrderSummary(
            order: Order(clientUUID: uuid, clientCode: "C1",
                         status: taken == nil ? .draft : .synced, notes: nil,
                         createdAt: Date(timeIntervalSince1970: 0), takenAt: taken, syncedAt: nil,
                         orderNumber: nil, rejectionReason: nil, creditVerdict: nil,
                         holdReason: nil, decisionNote: nil, decidedAt: nil,
                         deliveryStatus: nil, deliveryReason: nil, deliveredAt: nil),
            clientName: "Tienda", itemCount: 0, total: 0, isOverdue: false)
    }

    func test_summaries_filtraPorDiaDeTakenAt_yBorradoresSoloHoy() {
        let cal = Calendar(identifier: .gregorian)
        let today = Date(timeIntervalSince1970: 1_700_000_000)          // un día cualquiera
        let yesterday = today.addingTimeInterval(-24 * 3600)
        let twoDaysAgo = today.addingTimeInterval(-48 * 3600)

        let all = [
            summary(uuid: "hoy", taken: today),
            summary(uuid: "ayer", taken: yesterday),
            summary(uuid: "borrador", taken: nil),
        ]

        // HOY: la tomada hoy + el borrador (trabajo en curso). NO la de ayer.
        let hoy = OrdersRepository.summaries(all, takenOn: today, today: today, calendar: cal)
        XCTAssertEqual(Set(hoy.map(\.id)), ["hoy", "borrador"])

        // AYER: solo la tomada ayer. El borrador NO aparece en el histórico.
        let deAyer = OrdersRepository.summaries(all, takenOn: yesterday, today: today, calendar: cal)
        XCTAssertEqual(deAyer.map(\.id), ["ayer"])

        // Un día sin órdenes: vacío.
        let sinNada = OrdersRepository.summaries(all, takenOn: twoDaysAgo, today: today, calendar: cal)
        XCTAssertTrue(sinNada.isEmpty)
    }
}
