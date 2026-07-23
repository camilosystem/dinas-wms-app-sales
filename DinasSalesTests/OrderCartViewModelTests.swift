import XCTest
@testable import DinasSales

@MainActor
final class OrderCartViewModelTests: XCTestCase {

    private func seed(_ db: AppDatabase, authorized: [Int], defaultList: Int) throws {
        try db.dbQueue.write { database in
            try Client(clientCode: "C1", name: "Tienda", address: nil, city: nil, zipcode: nil,
                       managerName: nil, shippingRoute: nil,
                       defaultPriceList: defaultList, authorizedPriceLists: authorized).insert(database)
            try Item(itemCode: "I1", name: "Item 1", category: nil, barcode: nil,
                     priceList1: 10, priceList2: 8, priceList3: 0, stock: nil,
                     available: 100, imageURL: nil, active: true).insert(database)
        }
    }

    private func makeVM(_ db: AppDatabase, order: Order,
                        authorized: [Int], defaultList: Int) -> OrderCartViewModel {
        OrderCartViewModel(order: order, clientName: "Tienda",
                           authorizedPriceLists: authorized, defaultPriceList: defaultList,
                           orders: OrdersRepository(database: db),
                           catalog: CatalogRepository(database: db))
    }

    private func newOrder(_ db: AppDatabase) throws -> Order {
        try OrdersRepository(database: db, makeUUID: { "O1" }).startOrder(clientCode: "C1")
    }

    func test_clienteConDosListas_permiteElegirPorLinea() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, authorized: [1, 2], defaultList: 1)
        let vm = makeVM(db, order: try newOrder(db), authorized: [1, 2], defaultList: 1)

        XCTAssertTrue(vm.canChoosePriceList, "2 listas autorizadas → hay selector")
        XCTAssertEqual(vm.authorizedPriceLists, [1, 2])
    }

    func test_clienteConUnaLista_noHaySelector() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, authorized: [2], defaultList: 2)
        let vm = makeVM(db, order: try newOrder(db), authorized: [2], defaultList: 2)

        XCTAssertFalse(vm.canChoosePriceList, "1 sola lista → sin selector, usa esa")
    }

    func test_addOne_usaLaListaPorDefectoDelCliente() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, authorized: [1, 2], defaultList: 2)   // por defecto la 2 (precio 8)
        let order = try newOrder(db)
        let vm = makeVM(db, order: order, authorized: [1, 2], defaultList: 2)
        let item = try CatalogRepository(database: db).item(code: "I1")!

        vm.addOne(item)

        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.rows.first?.priceList, 2, "agrega con la lista por defecto")
        XCTAssertEqual(vm.rows.first?.unitPrice, 8)
    }

    func test_priceListPolicy_listasVisibles_nuncaLista1() {
        // Catálogo general (sin cliente): SOLO Lista 3.
        XCTAssertEqual(PriceListPolicy.visibleLists(authorized: []), [3])
        // Cliente autorizado en 1 y 3 (sin 2): SOLO Lista 3 (la 1 nunca).
        XCTAssertEqual(PriceListPolicy.visibleLists(authorized: [1, 3]), [3])
        // Cliente con Lista 2 autorizada: Lista 2 + Lista 3 (nunca la 1).
        XCTAssertEqual(PriceListPolicy.visibleLists(authorized: [2, 3]), [2, 3])
        XCTAssertEqual(PriceListPolicy.visibleLists(authorized: [1, 2]), [2, 3])
    }

    func test_priceListPolicy_listaDeAgregado_L2SoloSiAutorizadaYdefault() {
        // L2 autorizada Y es la default → se agrega con L2.
        XCTAssertEqual(PriceListPolicy.addList(authorized: [2, 3], defaultList: 2), 2)
        // L2 autorizada pero la default es otra → L3.
        XCTAssertEqual(PriceListPolicy.addList(authorized: [2, 3], defaultList: 3), 3)
        // Default 1 (o L2 no autorizada) → L3, nunca L1.
        XCTAssertEqual(PriceListPolicy.addList(authorized: [1, 3], defaultList: 1), 3)
        XCTAssertEqual(PriceListPolicy.addList(authorized: [3], defaultList: 2), 3)
    }

    /// El stepper del picker fija la cantidad ABSOLUTA: crea la línea, la actualiza y en 0 la quita.
    func test_setQuantityItem_creaActualizaYen0Quita() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, authorized: [1], defaultList: 1)
        let vm = makeVM(db, order: try newOrder(db), authorized: [1], defaultList: 1)
        let item = try CatalogRepository(database: db).item(code: "I1")!

        vm.setQuantity(item: item, quantity: 1)        // crea
        XCTAssertEqual(vm.rows.first?.quantity, 1)

        vm.setQuantity(item: item, quantity: 3)        // actualiza (absoluto, no suma)
        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.rows.first?.quantity, 3)

        vm.setQuantity(item: item, quantity: 0)        // quita
        XCTAssertTrue(vm.rows.isEmpty, "en 0 se quita la línea del carrito")
    }

    /// La línea del carrito expone el disponible del ítem y marca cuando lo pedido lo excede
    /// (aviso, no bloqueo). `available` de I1 es 100.
    func test_cartRow_marcaCuandoExcedeDisponible() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, authorized: [1], defaultList: 1)
        let vm = makeVM(db, order: try newOrder(db), authorized: [1], defaultList: 1)
        let item = try CatalogRepository(database: db).item(code: "I1")!

        vm.setQuantity(item: item, quantity: 50)       // dentro de lo disponible
        XCTAssertEqual(vm.rows.first?.available, 100)
        XCTAssertFalse(vm.rows.first!.exceedsAvailable, "50 ≤ 100 → sin aviso")

        vm.setQuantity(item: item, quantity: 150)      // por encima
        XCTAssertTrue(vm.rows.first!.exceedsAvailable, "150 > 100 → advierte")
    }
}
