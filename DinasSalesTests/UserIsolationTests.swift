import XCTest
import GRDB
@testable import DinasSales

/// Aislamiento por usuario (★): cada vendedor tiene su propio archivo de base. Dos vendedores en
/// el mismo dispositivo NUNCA ven pedidos/clientes ajenos — estructural, no por limpieza.
final class UserIsolationTests: XCTestCase {

    func test_archivoDeBase_esDistintoPorUsuario_ySaneado() {
        XCTAssertNotEqual(AppDatabase.filename(forUser: "vendedor1"),
                          AppDatabase.filename(forUser: "vendedor2"))
        XCTAssertEqual(AppDatabase.filename(forUser: "Vendedor1"),
                       AppDatabase.filename(forUser: "vendedor1"), "mismo usuario → mismo archivo")
        XCTAssertEqual(AppDatabase.filename(forUser: nil), "dinas-sales-_guest.sqlite")
        XCTAssertFalse(AppDatabase.filename(forUser: "a/b c").contains("/"), "nombre saneado")
    }

    func test_baseReabrible_aislaPorUsuario_yConservaLoDeCadaUno() throws {
        let fm = FileManager.default
        let folder = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)
        let fileA = folder.appendingPathComponent(AppDatabase.filename(forUser: "isotest_a"))
        let fileB = folder.appendingPathComponent(AppDatabase.filename(forUser: "isotest_b"))
        try? fm.removeItem(at: fileA); try? fm.removeItem(at: fileB)
        defer { try? fm.removeItem(at: fileA); try? fm.removeItem(at: fileB) }

        let db = try AppDatabase.makeForUser("isotest_a")
        try db.dbQueue.write { database in
            try Client(clientCode: "C1", name: "Tienda de A", address: nil, city: nil, zipcode: nil,
                       managerName: nil, shippingRoute: nil, defaultPriceList: 1,
                       authorizedPriceLists: [1], active: true, credit: .zero).insert(database)
        }
        XCTAssertEqual(try db.dbQueue.read { try Client.fetchCount($0) }, 1)

        // Reabrir para el usuario B: la base ahora es OTRO archivo, vacío.
        try db.reopen(forUser: "isotest_b")
        XCTAssertEqual(try db.dbQueue.read { try Client.fetchCount($0) }, 0,
                       "el usuario B NO ve el cliente de A (sin fuga)")

        // Volver a A: sus datos siguen en SU archivo.
        try db.reopen(forUser: "isotest_a")
        XCTAssertEqual(try db.dbQueue.read { try Client.fetchCount($0) }, 1,
                       "cada usuario conserva lo suyo en su propio archivo")
    }

    /// Regresión (réplica del bug de bodega, con el flujo de login A→B→A y datos del dominio de
    /// ventas): login A carga cliente + orden → logout → login B ve VACÍO (releído de disco, no de
    /// memoria) → A vuelve y recupera SUS datos, no los de B ni uno vacío.
    func test_loginAB_bNoVeDatosDeA_yARecuperaLosSuyos() throws {
        let fm = FileManager.default
        let folder = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)
        let fileA = folder.appendingPathComponent(AppDatabase.filename(forUser: "reg_a"))
        let fileB = folder.appendingPathComponent(AppDatabase.filename(forUser: "reg_b"))
        try? fm.removeItem(at: fileA); try? fm.removeItem(at: fileB)
        defer { try? fm.removeItem(at: fileA); try? fm.removeItem(at: fileB) }

        func clients(_ db: AppDatabase) throws -> [String] {
            try db.dbQueue.read { try Client.order(Column("client_code")).fetchAll($0).map(\.clientCode) }
        }
        func orders(_ db: AppDatabase) throws -> [String] {
            try db.dbQueue.read { try Order.fetchAll($0).map(\.clientUUID) }
        }
        func seedClient(_ db: AppDatabase, _ code: String) throws {
            try db.dbQueue.write {
                try Client(clientCode: code, name: "Tienda \(code)", address: nil, city: nil,
                           zipcode: nil, managerName: nil, shippingRoute: nil, defaultPriceList: 1,
                           authorizedPriceLists: [1], active: true, credit: .zero).insert($0)
            }
        }
        func seedOrder(_ db: AppDatabase, uuid: String, client: String) throws {
            try db.dbQueue.write {
                try Order(clientUUID: uuid, clientCode: client, status: .synced, notes: nil,
                          createdAt: Date(timeIntervalSince1970: 0), takenAt: nil, syncedAt: nil,
                          orderNumber: "N-\(uuid)", rejectionReason: nil, creditVerdict: nil,
                          holdReason: nil, decisionNote: nil, decidedAt: nil, deliveryStatus: nil,
                          deliveryReason: nil, deliveredAt: nil).insert($0)
            }
        }

        // Login A: carga su cliente y su orden.
        let db = try AppDatabase.makeForUser("reg_a")
        try seedClient(db, "CA"); try seedOrder(db, uuid: "ORD-A", client: "CA")
        XCTAssertEqual(try clients(db), ["CA"]); XCTAssertEqual(try orders(db), ["ORD-A"])

        // Logout → login B: NO ve nada de A (releído de su propio archivo en disco).
        try db.reopen(forUser: "reg_b")
        XCTAssertTrue(try clients(db).isEmpty, "B no ve el cliente de A")
        XCTAssertTrue(try orders(db).isEmpty, "B no ve la orden de A")
        try seedClient(db, "CB")   // B tiene lo suyo
        XCTAssertEqual(try clients(db), ["CB"])

        // A vuelve tras B: recupera SUS datos, no los de B ni uno vacío.
        try db.reopen(forUser: "reg_a")
        XCTAssertEqual(try clients(db), ["CA"], "A recupera su cliente")
        XCTAssertEqual(try orders(db), ["ORD-A"], "A recupera su orden")

        // Y B sigue con lo suyo (no contaminado por A).
        try db.reopen(forUser: "reg_b")
        XCTAssertEqual(try clients(db), ["CB"], "B conserva lo suyo, sin datos de A")
    }
}
