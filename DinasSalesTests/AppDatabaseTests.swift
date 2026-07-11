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
            try Client(id: "C1", name: "Tienda Central", address: nil, updatedAt: nil).insert(db)
            try Item(id: "I1", code: "A-100", name: "Producto", available: 10,
                     comments: nil, imageURL: nil, updatedAt: nil).insert(db)

            try Order(clientUUID: uuid, clientID: "C1", status: .confirmed,
                      createdAt: Date(timeIntervalSince1970: 0),
                      confirmedAt: Date(timeIntervalSince1970: 1),
                      syncedAt: nil).insert(db)

            var line = OrderLine(id: nil, orderUUID: uuid, itemID: "I1",
                                 quantity: 3, lineDiscount: 0.1)
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
        }
    }
}
