import XCTest
import GRDB
@testable import DinasSales

final class BackupServiceTests: XCTestCase {

    /// Inserta un cliente, un ítem, una orden y sus líneas. `status` por defecto no-borrador.
    private func seedOrder(_ db: AppDatabase, uuid: String, code: String, clientName: String,
                           number: String?, status: OrderStatus = .synced,
                           lines: [(String, Double, Double, Int)]) throws {
        try db.dbQueue.write { database in
            if try Client.fetchOne(database, key: code) == nil {
                try Client(clientCode: code, name: clientName, address: nil, city: nil, zipcode: nil,
                           managerName: nil, shippingRoute: nil, defaultPriceList: 3,
                           authorizedPriceLists: [3]).insert(database)
            }
            try Order(clientUUID: uuid, clientCode: code, status: status, notes: nil,
                      createdAt: Date(timeIntervalSince1970: 0), takenAt: Date(timeIntervalSince1970: 1),
                      syncedAt: nil, orderNumber: number).insert(database)
            for (item, qty, price, list) in lines {
                if try Item.fetchOne(database, key: item) == nil {
                    try Item(itemCode: item, name: "Nombre \(item)", category: nil, barcode: nil,
                             priceList1: 0, priceList2: 0, priceList3: price, stock: nil,
                             available: 10, imageURL: nil, active: true).insert(database)
                }
                var line = OrderLine(id: nil, orderUUID: uuid, itemCode: item, quantity: qty,
                                     unitPrice: price, lineDiscountPct: 0, priceList: list)
                try line.insert(database)
            }
        }
    }

    // MARK: - Export

    func test_export_generaBackupEsperado_yOmiteBorradores() throws {
        let db = try AppDatabase.makeInMemory()
        try seedOrder(db, uuid: "O1", code: "C1", clientName: "Tienda Uno", number: "N-1",
                      status: .synced, lines: [("I1", 2, 10, 3), ("I2", 1, 5, 3)])
        // Un borrador NO debe respaldarse (no es historial).
        try seedOrder(db, uuid: "D1", code: "C1", clientName: "Tienda Uno", number: nil,
                      status: .draft, lines: [("I1", 9, 10, 3)])

        let service = BackupService(database: db)
        let backup = try service.exportBackup(username: "vendedor1",
                                              now: Date(timeIntervalSince1970: 1000))

        XCTAssertEqual(backup.format, "dinas-ventas-orders-backup")
        XCTAssertEqual(backup.version, 1)
        XCTAssertEqual(backup.username, "vendedor1")
        XCTAssertEqual(backup.orders.count, 1, "solo la sincronizada; el borrador se omite")

        let order = backup.orders[0]
        XCTAssertEqual(order.clientUUID, "O1")
        XCTAssertEqual(order.clientCode, "C1")
        XCTAssertEqual(order.clientName, "Tienda Uno")
        XCTAssertEqual(order.orderNumber, "N-1")
        XCTAssertEqual(order.status, "synced")
        XCTAssertEqual(order.total, 2 * 10 + 1 * 5, "total = suma de líneas")
        XCTAssertEqual(order.lines.count, 2)
        XCTAssertEqual(order.lines[0].itemName, "Nombre I1", "el backup incluye el nombre del ítem (legible)")

        // El JSON hace round-trip exacto (misma estructura al codificar y decodificar).
        let data = try BackupService.makeEncoder().encode(backup)
        let decoded = try service.decode(data)
        XCTAssertEqual(decoded, backup)
        // Y usa snake_case en las claves.
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"client_uuid\""))
        XCTAssertTrue(json.contains("\"order_number\""))
    }

    // MARK: - Restore no duplica

    func test_restore_noDuplicaExistentes_porUUIDoNumero() throws {
        let db = try AppDatabase.makeInMemory()
        // Ya existe localmente la orden O1 (N-1).
        try seedOrder(db, uuid: "O1", code: "C1", clientName: "Tienda Uno", number: "N-1",
                      status: .synced, lines: [("I1", 1, 10, 3)])
        let service = BackupService(database: db)

        // Backup con: O1 (misma, dup por uuid), OX (dup por order_number N-1), y O2 (nueva).
        let backup = OrdersBackup(
            format: "dinas-ventas-orders-backup", version: 1,
            exportedAt: Date(timeIntervalSince1970: 0), username: "vendedor1",
            orders: [
                backupOrder(uuid: "O1", code: "C1", number: "N-1"),
                backupOrder(uuid: "OX", code: "C1", number: "N-1"),   // choca por número
                backupOrder(uuid: "O2", code: "C1", number: "N-2"),   // nueva
            ])

        let summary = try service.restore(backup)

        XCTAssertEqual(summary.restored, 1, "solo O2 se inserta")
        XCTAssertEqual(summary.skipped, 2, "O1 (uuid) y OX (número) ya existían")

        let count = try db.dbQueue.read { try Order.fetchCount($0) }
        XCTAssertEqual(count, 2, "O1 original + O2; nada duplicado")
        let o1Count = try db.dbQueue.read {
            try Order.filter(Column("client_uuid") == "O1").fetchCount($0)
        }
        XCTAssertEqual(o1Count, 1, "O1 no se duplicó")
    }

    // MARK: - Archivo corrupto / inválido

    func test_decode_archivoCorrupto_fallaConGracia() throws {
        let service = BackupService(database: try AppDatabase.makeInMemory())

        // JSON basura.
        XCTAssertThrowsError(try service.decode(Data("no soy json {".utf8))) { error in
            XCTAssertEqual(error as? BackupError, .invalidFormat)
        }
        // JSON válido pero NO es un backup de órdenes (formato equivocado).
        let otro = Data(#"{"format":"otra-cosa","version":1,"exported_at":"2026-01-01T00:00:00Z","orders":[]}"#.utf8)
        XCTAssertThrowsError(try service.decode(otro)) { error in
            XCTAssertEqual(error as? BackupError, .invalidFormat)
        }
    }

    private func backupOrder(uuid: String, code: String, number: String?) -> BackupOrder {
        BackupOrder(clientUUID: uuid, clientCode: code, clientName: "Tienda", orderNumber: number,
                    status: "synced", notes: nil, createdAt: Date(timeIntervalSince1970: 0),
                    takenAt: nil, syncedAt: nil, total: 10, rejectionReason: nil, creditVerdict: nil,
                    holdReason: nil, decisionNote: nil, decidedAt: nil, deliveryStatus: nil,
                    deliveryReason: nil, deliveredAt: nil,
                    lines: [BackupLine(itemCode: "I1", itemName: "Nombre I1", quantity: 1,
                                       unitPrice: 10, lineDiscountPct: 0, priceList: 3)])
    }
}
