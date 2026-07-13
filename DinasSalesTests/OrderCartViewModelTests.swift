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
}
