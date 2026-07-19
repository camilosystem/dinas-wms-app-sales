import XCTest
import GRDB
@testable import DinasSales

/// Entrega (★ v0.11.0): el resultado de la entrega baja vía GET /sync/orders y se muestra
/// en el detalle/lista para que el vendedor sepa qué pasó con su pedido. `delivery_reason`
/// viene YA formateado por el middleware — se guarda y muestra tal cual.
@MainActor
final class DeliveryTests: XCTestCase {

    /// Siembra una orden `.synced` (única que recibe actualizaciones del ciclo de vida) y
    /// devuelve su repositorio.
    private func seedSyncedOrder(_ db: AppDatabase, uuid: String = "ORD-1") async throws -> OrdersRepository {
        try await db.dbQueue.write { database in
            try Client(clientCode: "C1", name: "Tienda", address: nil, city: nil, zipcode: nil,
                       managerName: nil, shippingRoute: nil, defaultPriceList: 1,
                       authorizedPriceLists: [1], active: true, credit: .zero).insert(database)
            try Item(itemCode: "I1", name: "Item", category: nil, barcode: nil,
                     priceList1: 10, priceList2: 10, priceList3: 10, stock: nil,
                     available: 5, imageURL: nil, active: true).insert(database)
        }
        let repo = OrdersRepository(database: db, now: { Date(timeIntervalSince1970: 0) },
                                    makeUUID: { uuid })
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 1)
        try repo.confirm(orderUUID: order.clientUUID)
        try repo.markSynced(orderUUID: uuid, orderNumber: "N-1", creditVerdict: .aprobada)
        return repo
    }

    /// Un `OrderStatusUpdate` con solo los campos de entrega (los de cartera van en nil).
    private func deliveryUpdate(_ uuid: String, _ status: String?, reason: String? = nil,
                                at: Date? = nil) -> OrderStatusUpdate {
        OrderStatusUpdate(clientUUID: uuid, orderNumber: nil, status: nil, holdReason: nil,
                          decisionNote: nil, decidedAt: nil, receivedAt: nil,
                          deliveryStatus: status, deliveryReason: reason, deliveredAt: at)
    }

    // MARK: - Estados de entrega

    func test_entregado_seMuestraComoEntregado() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = try await seedSyncedOrder(db)
        try repo.applyStatusUpdate(deliveryUpdate("ORD-1", "ENTREGADO",
                                                  at: Date(timeIntervalSince1970: 100)))
        let saved = try repo.order(uuid: "ORD-1")
        XCTAssertEqual(saved?.deliveryStatus, .entregado)
        XCTAssertTrue(saved?.deliveryStatus?.isResult ?? false, "estado terminal → se muestra")
        XCTAssertNil(saved?.deliveryReason, "entregado completo: sin motivo")
        XCTAssertNotNil(saved?.deliveredAt)
    }

    func test_noEntregado_muestraElMotivo() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = try await seedSyncedOrder(db)
        let motivo = "El cliente canceló el pedido."
        try repo.applyStatusUpdate(deliveryUpdate("ORD-1", "NO_ENTREGADO", reason: motivo))
        let saved = try repo.order(uuid: "ORD-1")
        XCTAssertEqual(saved?.deliveryStatus, .noEntregado)
        XCTAssertEqual(saved?.deliveryReason, motivo, "el motivo se guarda tal cual (ya formateado)")
    }

    func test_entregadoParcial_muestraElDetalleDelRechazo() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = try await seedSyncedOrder(db)
        let detalle = "El cliente rechazó: 2 de Castipan Sport Guava 14u x 10.6oz x 300g (llegó dañado)."
        try repo.applyStatusUpdate(deliveryUpdate("ORD-1", "ENTREGADO_PARCIAL", reason: detalle))
        let saved = try repo.order(uuid: "ORD-1")
        XCTAssertEqual(saved?.deliveryStatus, .entregadoParcial)
        XCTAssertTrue(saved?.deliveryStatus?.isResult ?? false)
        XCTAssertEqual(saved?.deliveryReason, detalle, "el detalle del rechazo se muestra tal cual")
    }

    func test_sinEntregaRegistrada_noMuestraSeccionNiRompe() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = try await seedSyncedOrder(db)
        // NULL: la mayoría de las órdenes (aún no entregadas).
        try repo.applyStatusUpdate(deliveryUpdate("ORD-1", nil))
        XCTAssertNil(try repo.order(uuid: "ORD-1")?.deliveryStatus,
                     "sin entrega registrada → nil, no se muestra sección")
        // PENDIENTE (despachado, en ruta) tampoco es un resultado que mostrar.
        try repo.applyStatusUpdate(deliveryUpdate("ORD-1", "PENDIENTE"))
        let pend = try repo.order(uuid: "ORD-1")
        XCTAssertEqual(pend?.deliveryStatus, .pendiente)
        XCTAssertFalse(pend?.deliveryStatus?.isResult ?? true, "PENDIENTE no muestra sección de entrega")
    }

    // MARK: - Sync: decodifica y persiste los campos nuevos

    func test_sync_decodificaYPersisteLosCamposDeEntrega() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = try await seedSyncedOrder(db)
        // Respuesta de GET /sync/orders con el resultado de entrega.
        let json = Data("""
        {"server_time":"2026-07-18T10:00:00Z",
         "orders":[
           {"client_uuid":"ORD-1","order_number":"N-1","status":"APROBADA",
            "delivery_status":"ENTREGADO_PARCIAL",
            "delivery_reason":"El cliente rechazó: 2 de Castipan (llegó dañado).",
            "delivered_at":"2026-07-18T09:30:00Z"}]}
        """.utf8)
        let page = try JSONCoding.decoder.decode(OrdersSyncResponse.self, from: json)
        for update in page.orders { try repo.applyStatusUpdate(update) }

        let saved = try repo.order(uuid: "ORD-1")
        XCTAssertEqual(saved?.deliveryStatus, .entregadoParcial, "el sync decodifica y persiste delivery_status")
        XCTAssertEqual(saved?.deliveryReason, "El cliente rechazó: 2 de Castipan (llegó dañado).")
        XCTAssertNotNil(saved?.deliveredAt, "delivered_at persistido")
    }

    func test_sync_valorDesconocidoDeDeliveryStatus_noRompeElSync() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = try await seedSyncedOrder(db)
        // Un delivery_status que la app aún no conoce (p. ej. un estado futuro del contrato).
        let json = Data("""
        {"server_time":"2026-07-18T10:00:00Z",
         "orders":[{"client_uuid":"ORD-1","delivery_status":"FUTURO_DESCONOCIDO"}]}
        """.utf8)
        // No lanza al decodificar (delivery_status llega como String en el DTO).
        let page = try JSONCoding.decoder.decode(OrdersSyncResponse.self, from: json)
        for update in page.orders { try repo.applyStatusUpdate(update) }
        XCTAssertNil(try repo.order(uuid: "ORD-1")?.deliveryStatus,
                     "valor desconocido → nil (no revienta el sync ni pinta sección)")
    }
}
