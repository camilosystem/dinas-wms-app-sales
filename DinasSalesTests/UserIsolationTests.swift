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
}
