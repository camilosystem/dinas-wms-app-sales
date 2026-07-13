import XCTest
import GRDB
@testable import DinasSales

final class ClientsRepositoryTests: XCTestCase {

    private func seed(_ db: AppDatabase, _ clients: [Client]) throws {
        try db.dbQueue.write { database in
            for client in clients { try client.insert(database) }
        }
    }

    private func client(_ code: String, name: String, city: String? = nil,
                        route: String? = nil) -> Client {
        Client(clientCode: code, name: name, address: nil, city: city,
               zipcode: nil, managerName: nil, shippingRoute: route,
               defaultPriceList: 1, authorizedPriceLists: [1])
    }

    func test_clients_sinQuery_ordenadosPorNombre() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, [
            client("C3", name: "Zeta"),
            client("C1", name: "Alfa"),
            client("C2", name: "Manzana"),
        ])
        let repo = ClientsRepository(database: db)

        XCTAssertEqual(try repo.clients(matching: "").map(\.name), ["Alfa", "Manzana", "Zeta"])
    }

    func test_clients_buscaPorCodigoNombreCiudadYRuta() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, [
            client("CL-100", name: "Tienda Norte", city: "Bogotá", route: "R1"),
            client("CL-200", name: "Minimarket Sur", city: "Medellín", route: "R2"),
            client("CL-300", name: "Abarrotes Centro", city: "Bogotá", route: "R3"),
        ])
        let repo = ClientsRepository(database: db)

        XCTAssertEqual(try repo.clients(matching: "CL-200").map(\.clientCode), ["CL-200"])
        XCTAssertEqual(try repo.clients(matching: "sur").map(\.clientCode), ["CL-200"])
        XCTAssertEqual(Set(try repo.clients(matching: "bogotá").map(\.clientCode)),
                       ["CL-100", "CL-300"])
        XCTAssertEqual(try repo.clients(matching: "R2").map(\.clientCode), ["CL-200"])
    }

    func test_client_porCodigo() throws {
        let db = try AppDatabase.makeInMemory()
        try seed(db, [client("X-1", name: "Uno")])
        let repo = ClientsRepository(database: db)

        XCTAssertEqual(try repo.client(code: "X-1")?.name, "Uno")
        XCTAssertNil(try repo.client(code: "NO-EXISTE"))
    }
}
