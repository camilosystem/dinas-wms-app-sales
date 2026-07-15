import XCTest
import GRDB
@testable import DinasSales

/// Sondeo de alcance controlable para dirigir las transiciones en tests.
private final class ProbeBox: @unchecked Sendable {
    var reachable: Bool
    private(set) var calls = 0
    init(_ reachable: Bool) { self.reachable = reachable }
    func probe() async -> Bool { calls += 1; return reachable }
}

/// Reconexión: la app se recupera sola cuando vuelve el alcance al middleware, y el botón
/// "Reintentar" fuerza la comprobación. Nada pendiente se pierde en la transición.
@MainActor
final class NetworkMonitorTests: XCTestCase {

    private func monitor(_ box: ProbeBox) -> NetworkMonitor {
        NetworkMonitor(autoStart: false, probe: { await box.probe() })
    }

    // MARK: - Recuperación automática

    /// Offline + vuelve la conexión → al re-evaluar (lo que hacen el NWPath y el poll de
    /// respaldo), vuelve a online SIN reiniciar la app.
    func test_offlineYVuelveConexion_reevaluacion_vuelveOnlineSola() async {
        let box = ProbeBox(false)
        let m = monitor(box)
        m.handle(online: false)               // cayó la conexión → offline
        XCTAssertFalse(m.isOnline)

        box.reachable = true                  // el middleware/red vuelve
        await m.check()                       // re-evaluación activa (NWPath / poll)

        XCTAssertTrue(m.isOnline, "al recuperar el alcance, vuelve a online sola")
    }

    // MARK: - Botón manual

    func test_botonReintentar_conConexion_vuelveOnline() async {
        let box = ProbeBox(true)
        let m = monitor(box)
        m.handle(online: false)

        await m.retry()                       // botón "Reintentar conexión"

        XCTAssertTrue(m.isOnline)
        XCTAssertGreaterThan(box.calls, 0, "el botón fuerza el sondeo del middleware")
    }

    func test_botonReintentar_sinConexion_sigueOffline() async {
        let box = ProbeBox(false)             // el middleware sigue caído
        let m = monitor(box)
        m.handle(online: false)

        await m.retry()

        XCTAssertFalse(m.isOnline, "si el sondeo falla, sigue offline; el botón queda disponible")
    }

    func test_isChecking_seLimpiaTrasElSondeo() async {
        let m = monitor(ProbeBox(true))
        await m.retry()
        XCTAssertFalse(m.isChecking, "el spinner no queda pegado")
    }

    // MARK: - Nada pendiente se pierde

    /// Las órdenes sin sincronizar siguen intactas tras cualquier transición offline↔online.
    func test_ordenesPendientesIntactas_trasTransiciones() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbQueue.write { database in
            try Client(clientCode: "C1", name: "Tienda", address: nil, city: nil, zipcode: nil,
                       managerName: nil, shippingRoute: nil, defaultPriceList: 1,
                       authorizedPriceLists: [1]).insert(database)
            try Item(itemCode: "I1", name: "Item", category: nil, barcode: nil,
                     priceList1: 10, priceList2: 10, priceList3: 10, stock: nil,
                     available: 5, imageURL: nil, active: true).insert(database)
        }
        let repo = OrdersRepository(database: db, now: { Date(timeIntervalSince1970: 0) },
                                    makeUUID: { "ORD-1" })
        let order = try repo.startOrder(clientCode: "C1")
        try repo.setQuantity(orderUUID: order.clientUUID, itemCode: "I1", priceList: 1, quantity: 2)
        try repo.confirm(orderUUID: order.clientUUID)

        // Transiciones: online → offline → (reintento) → online.
        let box = ProbeBox(false)
        let m = monitor(box)
        m.handle(online: true)
        m.handle(online: false)
        box.reachable = true
        await m.retry()
        XCTAssertTrue(m.isOnline)

        // La orden confirmada sin enviar sigue ahí.
        XCTAssertEqual(try repo.confirmedOrders().map(\.clientUUID), ["ORD-1"],
                       "nada pendiente se pierde en la transición")
    }
}
