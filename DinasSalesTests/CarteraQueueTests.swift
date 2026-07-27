import XCTest
import GRDB
@testable import DinasSales

/// Cola offline de cartera (v9): pagos y solicitudes de crédito. Solo los envíos SIN foto se
/// encolan (`queued`); con foto es síncrono y se guarda ya `synced`.
final class CarteraQueueTests: XCTestCase {

    private func makeRepo(_ db: AppDatabase, uuid: String = "uuid-1") -> CarteraRepository {
        CarteraRepository(database: db, now: { Date(timeIntervalSince1970: 1000) },
                          makeUUID: { uuid })
    }

    // MARK: - Pagos

    func test_enqueuePayment_generaUUIDalCrear_yQuedaEnCola() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = makeRepo(db, uuid: "pay-1")

        let payment = try repo.enqueuePayment(
            clientCode: "C1", method: .efectivo, amount: 150,
            paymentDate: Date(timeIntervalSince1970: 0), comments: "abono",
            proposedApplications: [InvoiceApplication(invoiceDocNum: "F-1", amount: 150)])

        XCTAssertEqual(payment.paymentUUID, "pay-1", "el uuid se genera AL CREAR")
        XCTAssertEqual(payment.syncStatus, .queued)
        XCTAssertNil(payment.evidenceImageURL, "sin foto en la cola")
        // Aparece en pendientes.
        XCTAssertEqual(try repo.pendingPayments().map(\.paymentUUID), ["pay-1"])
        // Round-trip de la imputación propuesta (JSON).
        XCTAssertEqual(try repo.pendingPayments().first?.proposedApplications,
                       [InvoiceApplication(invoiceDocNum: "F-1", amount: 150)])
    }

    func test_enqueuePayment_persisteBancoYCheque_roundTripGRDB() throws {
        let db = try AppDatabase.makeInMemory()

        // TRANSFERENCIA con banco.
        let t = try makeRepo(db, uuid: "pay-t").enqueuePayment(
            clientCode: "C1", method: .transferencia, amount: 200,
            paymentDate: Date(timeIntervalSince1970: 0), comments: nil,
            proposedApplications: [], transferBankAccount: .chase9280)
        let storedT = try db.dbQueue.read { try AccountPayment.fetchOne($0, key: t.paymentUUID) }
        XCTAssertEqual(storedT?.transferBankAccount, .chase9280)
        XCTAssertNil(storedT?.checkNumber); XCTAssertNil(storedT?.bankCode)

        // CHEQUE con número + banco.
        let c = try makeRepo(db, uuid: "pay-c").enqueuePayment(
            clientCode: "C1", method: .cheque, amount: 75,
            paymentDate: Date(timeIntervalSince1970: 0), comments: nil,
            proposedApplications: [], checkNumber: "000123", bankCode: "BAC")
        let storedC = try db.dbQueue.read { try AccountPayment.fetchOne($0, key: c.paymentUUID) }
        XCTAssertEqual(storedC?.checkNumber, "000123")
        XCTAssertEqual(storedC?.bankCode, "BAC")
        XCTAssertNil(storedC?.transferBankAccount)
    }

    func test_payments_porCliente_devuelveTodosLosEstados_yEstadoVisible() throws {
        let db = try AppDatabase.makeInMemory()
        // Dos pagos de C1 (uno en cola, uno reportado) y uno de otro cliente que NO debe salir.
        let queued = try makeRepo(db, uuid: "p-cola").enqueuePayment(
            clientCode: "C1", method: .efectivo, amount: 10,
            paymentDate: Date(timeIntervalSince1970: 0), comments: nil, proposedApplications: [])
        try makeRepo(db, uuid: "p-otro").enqueuePayment(
            clientCode: "C2", method: .efectivo, amount: 99,
            paymentDate: Date(timeIntervalSince1970: 0), comments: nil, proposedApplications: [])
        try makeRepo(db).markPaymentSynced(paymentUUID: queued.paymentUUID)  // C1 → reportado

        let repo = CarteraRepository(database: db)
        let deC1 = try repo.payments(clientCode: "C1")
        XCTAssertEqual(deC1.map(\.paymentUUID), ["p-cola"], "solo pagos de C1")
        XCTAssertEqual(deC1.first?.reportedStatus, .reportado, "synced → Reportado")

        // Estado visible según sync_status.
        let enCola = try repo.pendingPayments().first { $0.clientCode == "C2" }
        XCTAssertEqual(enCola?.reportedStatus, .porEnviar, "queued → Por enviar")
    }

    func test_activeInvoiceNumbers_bloqueaFacturasDePagosActivos_yLiberaAlDescartar() throws {
        let db = try AppDatabase.makeInMemory()
        // Pago en cola con INV-1.
        let queued = try makeRepo(db, uuid: "p-q").enqueuePayment(
            clientCode: "C1", method: .efectivo, amount: 10,
            paymentDate: Date(timeIntervalSince1970: 0), comments: nil,
            proposedApplications: [InvoiceApplication(invoiceDocNum: "INV-1", amount: 10)])
        // Pago reportado (synced) con INV-2 → también bloquea.
        let synced = try makeRepo(db, uuid: "p-s").enqueuePayment(
            clientCode: "C1", method: .efectivo, amount: 20,
            paymentDate: Date(timeIntervalSince1970: 0), comments: nil,
            proposedApplications: [InvoiceApplication(invoiceDocNum: "INV-2", amount: 20)])
        try makeRepo(db).markPaymentSynced(paymentUUID: synced.paymentUUID)
        // Pago de OTRO cliente con INV-9 → no debe contar para C1.
        try makeRepo(db, uuid: "p-x").enqueuePayment(
            clientCode: "C2", method: .efectivo, amount: 5,
            paymentDate: Date(timeIntervalSince1970: 0), comments: nil,
            proposedApplications: [InvoiceApplication(invoiceDocNum: "INV-9", amount: 5)])

        let repo = CarteraRepository(database: db)
        XCTAssertEqual(try repo.activeInvoiceNumbers(clientCode: "C1"), ["INV-1", "INV-2"],
                       "queued y synced bloquean; otro cliente no")

        // Descartar el pago en cola (como desde el panel de Problemas) libera su factura;
        // el synced (INV-2) sigue bloqueado.
        try repo.discardPayment(paymentUUID: queued.paymentUUID)
        XCTAssertEqual(try repo.activeInvoiceNumbers(clientCode: "C1"), ["INV-2"],
                       "al descartar el queued, INV-1 vuelve a estar disponible")
    }

    func test_pagoFailed_noBloqueaSuFactura() throws {
        let db = try AppDatabase.makeInMemory()
        let p = try makeRepo(db, uuid: "p-f").enqueuePayment(
            clientCode: "C1", method: .efectivo, amount: 10,
            paymentDate: Date(timeIntervalSince1970: 0), comments: nil,
            proposedApplications: [InvoiceApplication(invoiceDocNum: "INV-1", amount: 10)])
        try makeRepo(db).markPaymentFailed(paymentUUID: p.paymentUUID, reason: "rechazado")

        XCTAssertTrue(try CarteraRepository(database: db).activeInvoiceNumbers(clientCode: "C1").isEmpty,
                      "un pago failed no bloquea (se resuelve en el panel de problemas)")
    }

    func test_pagoConFoto_seGuardaSynced_noEntraEnLaCola() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = makeRepo(db)
        let payment = AccountPayment(
            paymentUUID: "pay-foto", clientCode: "C1", method: .cheque,
            amount: 90, paymentDate: Date(timeIntervalSince1970: 0), comments: nil,
            evidenceImageURL: "https://mid/evidence/1.jpg", proposedApplications: [],
            syncStatus: .synced, createdAt: Date(timeIntervalSince1970: 0), syncedAt: nil)

        try repo.saveSyncedPayment(payment)

        XCTAssertTrue(try repo.pendingPayments().isEmpty, "un pago con foto (synced) NO está en cola")
        let stored = try db.dbQueue.read { try AccountPayment.fetchOne($0, key: "pay-foto") }
        XCTAssertEqual(stored?.syncStatus, .synced)
        XCTAssertEqual(stored?.evidenceImageURL, "https://mid/evidence/1.jpg")
    }

    func test_markPaymentSynced_saleDeLaCola() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = makeRepo(db, uuid: "pay-1")
        _ = try repo.enqueuePayment(clientCode: "C1", method: .efectivo,
                                    amount: 10, paymentDate: Date(timeIntervalSince1970: 0),
                                    comments: nil, proposedApplications: [])

        try repo.markPaymentSynced(paymentUUID: "pay-1")

        XCTAssertTrue(try repo.pendingPayments().isEmpty, "ya subido → fuera de la cola")
        let stored = try db.dbQueue.read { try AccountPayment.fetchOne($0, key: "pay-1") }
        XCTAssertEqual(stored?.syncStatus, .synced)
        XCTAssertNotNil(stored?.syncedAt)
    }

    // MARK: - Solicitudes de crédito

    func test_enqueueCreditConItems_guardaLineas_yCascade() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = makeRepo(db, uuid: "req-1")

        let request = try repo.enqueueCreditRequest(
            clientCode: "C1", mode: .conItems, reason: .damaged,
            manualAmount: nil, invoiceDocNum: "F-9", comments: nil,
            lines: [CreditRequestLineInput(itemCode: "I1", quantity: 2, reason: .damaged),
                    CreditRequestLineInput(itemCode: "I2", quantity: 1, reason: .short)])

        XCTAssertEqual(request.mode, .conItems)
        XCTAssertEqual(request.syncStatus, .queued)
        let lines = try repo.lines(requestUUID: "req-1")
        XCTAssertEqual(lines.map(\.itemCode), ["I1", "I2"])
        XCTAssertEqual(lines.map(\.quantity), [2, 1])
        XCTAssertEqual(lines.map(\.reason), [.damaged, .short], "reason por línea (lo exige el contrato)")

        // Borrar la solicitud arrastra las líneas (ON DELETE CASCADE).
        try db.dbQueue.write { db in
            _ = try CreditRequest.deleteOne(db, key: "req-1")
        }
        XCTAssertTrue(try repo.lines(requestUUID: "req-1").isEmpty, "cascade borró las líneas")
    }

    func test_enqueueCreditSinItems_manualAmount_sinLineas() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = makeRepo(db, uuid: "req-2")

        let request = try repo.enqueueCreditRequest(
            clientCode: "C1", mode: .sinItems, reason: .mistake,
            manualAmount: 320.50, invoiceDocNum: nil, comments: "ajuste manual", lines: [])

        XCTAssertEqual(request.mode, .sinItems)
        XCTAssertEqual(request.manualAmount, 320.50)
        XCTAssertNil(request.invoiceDocNum)
        XCTAssertTrue(try repo.lines(requestUUID: "req-2").isEmpty)
        XCTAssertEqual(try repo.pendingCreditRequests().map(\.requestUUID), ["req-2"])
    }

    func test_migracion_v9_creaLasTablas() throws {
        let db = try AppDatabase.makeInMemory()
        try db.dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("account_payments"))
            XCTAssertTrue(try db.tableExists("credit_requests"))
            XCTAssertTrue(try db.tableExists("credit_request_lines"))
        }
    }
}
