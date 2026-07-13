import XCTest
import GRDB
@testable import DinasSales

final class CatalogRepositoryTests: XCTestCase {

    private func seed(_ db: AppDatabase, _ items: [Item]) throws {
        try db.dbQueue.write { database in
            for item in items { try item.insert(database) }
        }
    }

    private func item(_ code: String, name: String, category: String? = nil,
                      barcode: String? = nil, active: Bool = true) -> Item {
        Item(itemCode: code, name: name, category: category, barcode: barcode,
             priceList1: 10, priceList2: 10, priceList3: 10, stock: nil, available: 1,
             imageURL: nil, active: active)
    }

    func test_items_sinQuery_devuelveSoloActivosOrdenadosPorNombre() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, [
            item("C", name: "Zapato", active: true),
            item("A", name: "Abrigo", active: true),
            item("B", name: "Oculto", active: false),
        ])
        let repo = CatalogRepository(database: db)

        let result = try repo.items(matching: "")

        XCTAssertEqual(result.map(\.itemCode), ["A", "C"])  // sin el inactivo, por nombre
    }

    func test_items_buscaPorCodigoNombreYPalabra() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, [
            item("SKU-100", name: "Camisa azul", category: "Ropa", barcode: "AZ-200"),
            item("SKU-200", name: "Pantalón azul", category: "Ropa"),
            item("SKU-300", name: "Gorra"),
        ])
        let repo = CatalogRepository(database: db)

        XCTAssertEqual(try repo.items(matching: "SKU-100").map(\.itemCode), ["SKU-100"])
        // "azul" aparece en el nombre de dos ítems.
        XCTAssertEqual(Set(try repo.items(matching: "azul").map(\.itemCode)),
                       ["SKU-100", "SKU-200"])
        XCTAssertEqual(try repo.items(matching: "Ropa").map(\.itemCode), ["SKU-100", "SKU-200"])
        // Búsqueda por código de barras.
        XCTAssertEqual(try repo.items(matching: "AZ-200").map(\.itemCode), ["SKU-100"])
    }

    func test_items_escapaComodinesDeLike() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, [
            item("A", name: "Descuento 50%"),
            item("B", name: "Producto normal"),
        ])
        let repo = CatalogRepository(database: db)

        // "%" debe tratarse literal: solo casa el que realmente lo contiene.
        XCTAssertEqual(try repo.items(matching: "50%").map(\.itemCode), ["A"])
        // Un "%" suelto no debe convertirse en comodín que casa todo.
        XCTAssertEqual(try repo.items(matching: "%").map(\.itemCode), ["A"])
    }

    func test_item_porCodigo() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, [item("X-1", name: "Uno")])
        let repo = CatalogRepository(database: db)

        XCTAssertEqual(try repo.item(code: "X-1")?.name, "Uno")
        XCTAssertNil(try repo.item(code: "NO-EXISTE"))
    }
}
