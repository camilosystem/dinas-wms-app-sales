import XCTest
import GRDB
@testable import DinasSales

/// `open_invoices` (★ v0.17.5): facturas abiertas del cliente, sincronizadas offline dentro de
/// `Client` para proponer imputaciones al reportar un pago de cartera.
final class OpenInvoicesTests: XCTestCase {

    func test_client_decodifica_openInvoices_desdeSyncClients() throws {
        let json = Data("""
        {
          "client_code": "C1", "name": "Tienda", "default_price_list": 3,
          "authorized_price_lists": [3],
          "credit": {"balance":0,"credit_limit":0,"credit_available":0,"overdue_count":0,
                     "overdue_amount":0,"max_days_overdue":0,"has_overdue":false,"grace_days":0},
          "open_invoices": [
            {"invoice_doc_num":"F-100","amount":250.50,"invoice_date":"2026-07-01","due_date":"2026-07-31"},
            {"invoice_doc_num":"F-101","amount":99.99,"invoice_date":"2026-07-05","due_date":"2026-08-04"}
          ]
        }
        """.utf8)

        let client = try JSONCoding.decoder.decode(Client.self, from: json)

        XCTAssertEqual(client.openInvoices.map(\.invoiceDocNum), ["F-100", "F-101"])
        XCTAssertEqual(client.openInvoices[0].amount, 250.50)
        // Fecha `format: date` (YYYY-MM-DD) parseada a medianoche UTC por el decoder compartido.
        let utc = Calendar(identifier: .gregorian)
        var c = utc; c.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(c.dateComponents([.year, .month, .day], from: client.openInvoices[0].invoiceDate).day, 1)
    }

    func test_client_sin_openInvoices_default_vacio() throws {
        let json = Data("""
        {"client_code":"C1","name":"Tienda","default_price_list":3,"authorized_price_lists":[3],
         "credit":{"balance":0,"credit_limit":0,"credit_available":0,"overdue_count":0,
                   "overdue_amount":0,"max_days_overdue":0,"has_overdue":false,"grace_days":0}}
        """.utf8)

        let client = try JSONCoding.decoder.decode(Client.self, from: json)
        XCTAssertTrue(client.openInvoices.isEmpty, "ausente en el payload → [] (tolerante)")
    }

    func test_openInvoices_roundTrip_GRDB() throws {
        let db = try AppDatabase.makeInMemory()
        let invoices = [
            OpenInvoiceSummary(invoiceDocNum: "F-1", amount: 42,
                               invoiceDate: Date(timeIntervalSince1970: 0),
                               dueDate: Date(timeIntervalSince1970: 86_400)),
            OpenInvoiceSummary(invoiceDocNum: "F-2", amount: 7.5,
                               invoiceDate: Date(timeIntervalSince1970: 172_800),
                               dueDate: Date(timeIntervalSince1970: 259_200)),
        ]
        var client = Client(clientCode: "C1", name: "Tienda", address: nil, city: nil, zipcode: nil,
                            managerName: nil, shippingRoute: nil, defaultPriceList: 3,
                            authorizedPriceLists: [3], active: true, credit: .zero,
                            openInvoices: invoices)

        try db.dbQueue.write { try client.insert($0) }
        let fetched = try db.dbQueue.read { try Client.fetchOne($0, key: "C1") }

        XCTAssertEqual(fetched?.openInvoices, invoices, "open_invoices persiste como JSON y round-trip por GRDB")
    }

    func test_migracion_v8_agrega_columna_open_invoices() throws {
        let db = try AppDatabase.makeInMemory()
        let columns = try db.dbQueue.read { try $0.columns(in: "clients").map(\.name) }
        XCTAssertTrue(columns.contains("open_invoices"), "la migración v8 agregó la columna")
    }
}
