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

    /// El buscador del catálogo ignora tildes (y mayúsculas), igual que el de clientes.
    func test_items_busquedaInsensibleAAcentos() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, [
            item("SKU-1", name: "Pantalón Clásico", category: "Ropa"),
            item("SKU-2", name: "Café Molido", category: "Comestibles"),
        ])
        let repo = CatalogRepository(database: db)

        XCTAssertEqual(try repo.items(matching: "pantalon").map(\.itemCode), ["SKU-1"])
        XCTAssertEqual(try repo.items(matching: "cafe").map(\.itemCode), ["SKU-2"])
        XCTAssertEqual(try repo.items(matching: "CLÁSICO").map(\.itemCode), ["SKU-1"])
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

    @MainActor
    func test_groupByCategory_alfabetico_itemsPorNombre_sinCategoriaAlFinal() {
        let items = [
            item("I1", name: "Zeta", category: "Bebidas"),
            item("I2", name: "Alfa", category: "Bebidas"),
            item("I3", name: "Beta", category: "Abarrotes"),
            item("I4", name: "Gamma", category: nil),     // sin categoría
            item("I5", name: "Delta", category: "  "),     // categoría en blanco → sin categoría
        ]

        let sections = CatalogViewModel.groupByCategory(items)

        // Categorías alfabéticas, "Sin categoría" al final.
        XCTAssertEqual(sections.map(\.category), ["Abarrotes", "Bebidas", "Sin categoría"])
        XCTAssertTrue(sections.last!.isNoCategory)
        // Dentro de Bebidas, por nombre.
        XCTAssertEqual(sections[1].items.map(\.name), ["Alfa", "Zeta"])
        // Nulo y en blanco caen en "Sin categoría".
        XCTAssertEqual(Set(sections.last!.items.map(\.itemCode)), ["I4", "I5"])
    }

    /// Búsqueda + agrupación: una categoría sin resultados no genera sección (no se muestra vacía).
    @MainActor
    func test_groupByCategory_categoriaSinResultados_noGeneraSeccion() {
        let filtrados = [item("I3", name: "Beta", category: "Abarrotes")]
        let sections = CatalogViewModel.groupByCategory(filtrados)
        XCTAssertEqual(sections.map(\.category), ["Abarrotes"])
    }

    @MainActor
    func test_categoryFilter_restringeALaCategoria_yBuscaDentro() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, [
            item("A1", name: "Leche", category: "Lácteos"),
            item("A2", name: "Queso", category: "Lácteos"),
            item("B1", name: "Pan", category: "Panadería"),
            item("C1", name: "Sal", category: nil),
        ])
        let repo = CatalogRepository(database: db)

        let lacteos = CatalogViewModel(repository: repo, categoryFilter: .named("Lácteos"))
        lacteos.reload()
        XCTAssertEqual(Set(lacteos.items.map(\.itemCode)), ["A1", "A2"])
        XCTAssertTrue(lacteos.categorySections.isEmpty, "en nivel 2 no se agrupa")

        // La búsqueda dentro de la categoría filtra solo sus ítems.
        lacteos.searchText = "queso"
        XCTAssertEqual(lacteos.items.map(\.itemCode), ["A2"])

        // "Sin categoría": solo los de category vacía/nula.
        let sinCat = CatalogViewModel(repository: repo, categoryFilter: .uncategorized)
        sinCat.reload()
        XCTAssertEqual(sinCat.items.map(\.itemCode), ["C1"])
    }

    func test_item_porCodigo() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, [item("X-1", name: "Uno")])
        let repo = CatalogRepository(database: db)

        XCTAssertEqual(try repo.item(code: "X-1")?.name, "Uno")
        XCTAssertNil(try repo.item(code: "NO-EXISTE"))
    }
}
