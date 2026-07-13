import XCTest
import GRDB
@testable import DinasSales

final class AppDatabaseTests: XCTestCase {

    func test_migracion_creaTodasLasTablas() throws {
        let appDB = try AppDatabase.makeInMemory()
        try appDB.dbQueue.read { db in
            for tabla in ["items", "clients", "orders", "order_lines", "sync_state"] {
                XCTAssertTrue(try db.tableExists(tabla), "Falta la tabla \(tabla)")
            }
        }
    }

    func test_roundTrip_ordenConLinea_conservaClientUUID() throws {
        let appDB = try AppDatabase.makeInMemory()
        let uuid = UUID().uuidString

        try appDB.dbQueue.write { db in
            try Client(clientCode: "C1", name: "Tienda Central", address: nil, city: nil,
                       zipcode: nil, managerName: nil, shippingRoute: nil,
                       defaultPriceList: 1, authorizedPriceLists: [1, 2]).insert(db)
            try Item(itemCode: "A-100", name: "Producto", category: nil, barcode: nil,
                     priceList1: 5.0, priceList2: 6.0, priceList3: 0, stock: 20, available: 10,
                     imageURL: nil, active: true).insert(db)

            try Order(clientUUID: uuid, clientCode: "C1", status: .confirmed, notes: nil,
                      createdAt: Date(timeIntervalSince1970: 0),
                      takenAt: Date(timeIntervalSince1970: 1),
                      syncedAt: nil, orderNumber: nil).insert(db)

            var line = OrderLine(id: nil, orderUUID: uuid, itemCode: "A-100",
                                 quantity: 3, unitPrice: 5.0, lineDiscountPct: 10, priceList: 1)
            try line.insert(db)
            XCTAssertNotNil(line.id, "order_lines.id debe autoincrementarse")
        }

        try appDB.dbQueue.read { db in
            let order = try Order.fetchOne(db, key: uuid)
            XCTAssertEqual(order?.clientUUID, uuid)
            XCTAssertEqual(order?.status, .confirmed)

            let lineas = try OrderLine.filter(Column("order_uuid") == uuid).fetchAll(db)
            XCTAssertEqual(lineas.count, 1)
            XCTAssertEqual(lineas.first?.quantity, 3)
            XCTAssertEqual(lineas.first?.priceList, 1)

            // authorized_price_lists ([Int]) se persiste como JSON y vuelve intacto.
            let cliente = try Client.fetchOne(db, key: "C1")
            XCTAssertEqual(cliente?.authorizedPriceLists, [1, 2])
            XCTAssertEqual(cliente?.defaultPriceList, 1)

            // Item con 3 listas (price_list_3 = 0 es válido).
            let item = try Item.fetchOne(db, key: "A-100")
            XCTAssertEqual(item?.price(forList: 2), 6.0)
            XCTAssertEqual(item?.price(forList: 3), 0)
            XCTAssertFalse(item?.hasPrice(forList: 3) ?? true)
        }
    }
}
