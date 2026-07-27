import XCTest
import GRDB
@testable import DinasSales

/// Stub de subida para el servicio de reporte de pago.
private final class SubmitStubAPI: CarteraUploadAPI, @unchecked Sendable {
    var photoError: Error?
    var postError: Error?
    private(set) var uploadedPhotos = 0
    private(set) var postedPayments: [String] = []

    func uploadEvidencePhoto(imageBase64: String, clientCode: String?) async throws -> String {
        if let photoError { throw photoError }
        uploadedPhotos += 1
        return "https://mid/e/\(uploadedPhotos).jpg"
    }
    func postAccountPayment(_ payment: AccountPayment) async throws -> AccountPaymentAccepted {
        if let postError { throw postError }
        postedPayments.append(payment.paymentUUID)
        return AccountPaymentAccepted(paymentUUID: payment.paymentUUID, status: "PENDIENTE_APROBACION", receivedAt: nil)
    }
    private(set) var postedRequests: [String] = []
    private(set) var postedLineCounts: [Int] = []
    func postCreditRequest(_ request: CreditRequest, lines: [CreditRequestLine]) async throws -> CreditRequestAccepted {
        if let postError { throw postError }
        postedRequests.append(request.requestUUID)
        postedLineCounts.append(lines.count)
        return CreditRequestAccepted(requestUUID: request.requestUUID, status: "PENDIENTE", receivedAt: nil)
    }

    var cancelError: Error?
    private(set) var canceledPayments: [String] = []
    private(set) var canceledRequests: [String] = []
    func cancelAccountPayment(paymentUUID: String, reason: String?) async throws {
        if let cancelError { throw cancelError }
        canceledPayments.append(paymentUUID)
    }
    func cancelCreditRequest(requestUUID: String, reason: String?) async throws {
        if let cancelError { throw cancelError }
        canceledRequests.append(requestUUID)
    }
}

final class CarteraSubmitTests: XCTestCase {

    private func draft() -> PaymentDraft {
        PaymentDraft(clientCode: "C1", method: .efectivo, amount: 100,
                     paymentDate: Date(timeIntervalSince1970: 0), comments: nil,
                     proposedApplications: [InvoiceApplication(invoiceDocNum: "F-1", amount: 100)])
    }

    private func makeService(_ db: AppDatabase, _ api: SubmitStubAPI) -> CarteraSubmitService {
        var repo = CarteraRepository(database: db); repo.makeUUID = { "pay-1" }
        return CarteraSubmitService(repo: repo, api: api)
    }

    func test_sinFoto_vaAlaCola_noTocaLaRed() async throws {
        let db = try AppDatabase.makeInMemory(); let api = SubmitStubAPI()
        let repo = CarteraRepository(database: db)

        let outcome = try await makeService(db, api).submitPayment(draft(), imageBase64: nil, isOnline: true)

        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(api.uploadedPhotos, 0, "sin foto no llama /evidence-photos")
        XCTAssertEqual(api.postedPayments, [], "sin foto no postea en el momento")
        XCTAssertEqual(try repo.pendingPayments().count, 1, "quedó en cola para el SyncEngine")
    }

    func test_conFoto_sinSenal_seBloquea_noCreaNada() async throws {
        let db = try AppDatabase.makeInMemory(); let api = SubmitStubAPI()
        let repo = CarteraRepository(database: db)

        let outcome = try await makeService(db, api).submitPayment(draft(), imageBase64: "b64", isOnline: false)

        XCTAssertEqual(outcome, .blockedNeedsConnection)
        XCTAssertEqual(api.uploadedPhotos, 0)
        XCTAssertTrue(try repo.pendingPayments().isEmpty, "no se creó ningún registro")
    }

    func test_conFoto_online_subeFoto_posteaYmarcaSynced() async throws {
        let db = try AppDatabase.makeInMemory(); let api = SubmitStubAPI()
        let repo = CarteraRepository(database: db)

        let outcome = try await makeService(db, api).submitPayment(draft(), imageBase64: "b64", isOnline: true)

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(api.uploadedPhotos, 1)
        XCTAssertEqual(api.postedPayments, ["pay-1"])
        let stored = try await db.dbQueue.read { try AccountPayment.fetchOne($0, key: "pay-1") }
        XCTAssertEqual(stored?.syncStatus, .synced)
        XCTAssertEqual(stored?.evidenceImageURL, "https://mid/e/1.jpg")
    }

    func test_conFoto_postFallaTransitorio_quedaEnColaConLaURL() async throws {
        let db = try AppDatabase.makeInMemory(); let api = SubmitStubAPI()
        api.postError = URLError(.timedOut)
        let repo = CarteraRepository(database: db)

        let outcome = try await makeService(db, api).submitPayment(draft(), imageBase64: "b64", isOnline: true)

        XCTAssertEqual(outcome, .pendingUpload)
        XCTAssertEqual(api.uploadedPhotos, 1, "la foto se subió una sola vez")
        let pending = try repo.pendingPayments()
        XCTAssertEqual(pending.first?.evidenceImageURL, "https://mid/e/1.jpg",
                       "queda en cola CON la URL → el SyncEngine reintenta solo el POST")
    }

    func test_conFoto_4xx_quedaFailedConMotivo() async throws {
        let db = try AppDatabase.makeInMemory(); let api = SubmitStubAPI()
        api.postError = APIError.server(status: 422, message: "El monto excede el saldo abierto.")
        let repo = CarteraRepository(database: db)

        let outcome = try await makeService(db, api).submitPayment(draft(), imageBase64: "b64", isOnline: true)

        XCTAssertEqual(outcome, .failed("El monto excede el saldo abierto."))
        XCTAssertEqual(try repo.failedPayments().first?.failureReason, "El monto excede el saldo abierto.")
    }

    // MARK: - Solicitud de crédito

    private func conItemsDraft() -> CreditRequestDraft {
        CreditRequestDraft(clientCode: "C1", mode: .conItems, reason: .damaged,
                           manualAmount: nil, invoiceDocNum: nil, comments: nil,
                           lines: [CreditRequestLineInput(itemCode: "I-1", quantity: 3, reason: .damaged),
                                   CreditRequestLineInput(itemCode: "I-2", quantity: 1, reason: .damaged)])
    }

    private func sinItemsDraft() -> CreditRequestDraft {
        CreditRequestDraft(clientCode: "C1", mode: .sinItems, reason: .mistake,
                           manualAmount: 250, invoiceDocNum: "F-9", comments: nil, lines: [])
    }

    private func makeCreditService(_ db: AppDatabase, _ api: SubmitStubAPI) -> CarteraSubmitService {
        var repo = CarteraRepository(database: db); repo.makeUUID = { "req-1" }
        return CarteraSubmitService(repo: repo, api: api)
    }

    func test_credito_conItems_sinFoto_encolaConLineas() async throws {
        let db = try AppDatabase.makeInMemory(); let api = SubmitStubAPI()
        let repo = CarteraRepository(database: db)

        let outcome = try await makeCreditService(db, api).submitCreditRequest(
            conItemsDraft(), imageBase64: nil, isOnline: true)

        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(api.uploadedPhotos, 0)
        XCTAssertEqual(api.postedRequests, [], "sin foto no postea en el momento")
        let pending = try repo.pendingCreditRequests()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(try repo.lines(requestUUID: "req-1").count, 2, "guardó las líneas CON_ITEMS")
    }

    func test_credito_sinItems_sinFoto_encolaSinLineas() async throws {
        let db = try AppDatabase.makeInMemory(); let api = SubmitStubAPI()
        let repo = CarteraRepository(database: db)

        let outcome = try await makeCreditService(db, api).submitCreditRequest(
            sinItemsDraft(), imageBase64: nil, isOnline: true)

        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(try repo.lines(requestUUID: "req-1").count, 0, "SIN_ITEMS no guarda líneas")
        let stored = try await db.dbQueue.read { try CreditRequest.fetchOne($0, key: "req-1") }
        XCTAssertEqual(stored?.manualAmount, 250)
        XCTAssertEqual(stored?.mode, .sinItems)
    }

    func test_credito_conFoto_sinSenal_seBloquea_noCreaNada() async throws {
        let db = try AppDatabase.makeInMemory(); let api = SubmitStubAPI()
        let repo = CarteraRepository(database: db)

        let outcome = try await makeCreditService(db, api).submitCreditRequest(
            conItemsDraft(), imageBase64: "b64", isOnline: false)

        XCTAssertEqual(outcome, .blockedNeedsConnection)
        XCTAssertEqual(api.uploadedPhotos, 0)
        XCTAssertTrue(try repo.pendingCreditRequests().isEmpty, "no se creó ningún registro")
    }

    func test_credito_conFoto_online_subeFoto_posteaConLineas_marcaSynced() async throws {
        let db = try AppDatabase.makeInMemory(); let api = SubmitStubAPI()

        let outcome = try await makeCreditService(db, api).submitCreditRequest(
            conItemsDraft(), imageBase64: "b64", isOnline: true)

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(api.uploadedPhotos, 1)
        XCTAssertEqual(api.postedRequests, ["req-1"])
        XCTAssertEqual(api.postedLineCounts, [2], "posteó las 2 líneas")
        let stored = try await db.dbQueue.read { try CreditRequest.fetchOne($0, key: "req-1") }
        XCTAssertEqual(stored?.syncStatus, .synced)
        XCTAssertEqual(stored?.evidenceImageURL, "https://mid/e/1.jpg")
    }

    func test_credito_conFoto_postFallaTransitorio_quedaEnColaConLaURL() async throws {
        let db = try AppDatabase.makeInMemory(); let api = SubmitStubAPI()
        api.postError = URLError(.timedOut)
        let repo = CarteraRepository(database: db)

        let outcome = try await makeCreditService(db, api).submitCreditRequest(
            sinItemsDraft(), imageBase64: "b64", isOnline: true)

        XCTAssertEqual(outcome, .pendingUpload)
        XCTAssertEqual(api.uploadedPhotos, 1, "la foto se subió una sola vez")
        XCTAssertEqual(try repo.pendingCreditRequests().first?.evidenceImageURL, "https://mid/e/1.jpg")
    }

    // MARK: - Cancelación (v0.21.0)

    private func reportedPaymentRepo(_ db: AppDatabase, uuid: String, invoice: String?) throws -> CarteraRepository {
        var repo = CarteraRepository(database: db); repo.makeUUID = { uuid }
        let apps = invoice.map { [InvoiceApplication(invoiceDocNum: $0, amount: 50)] } ?? []
        _ = try repo.enqueuePayment(clientCode: "C1", method: .efectivo, amount: 50,
            paymentDate: Date(timeIntervalSince1970: 0), comments: nil, proposedApplications: apps)
        try repo.markPaymentSynced(paymentUUID: uuid)   // reportado (synced)
        return repo
    }

    func test_cancelPayment_online_cancelaEnServer_marcaCanceled_yLiberaFactura() async throws {
        let db = try AppDatabase.makeInMemory(); let api = SubmitStubAPI()
        let repo = try reportedPaymentRepo(db, uuid: "pay-x", invoice: "INV-1")
        XCTAssertEqual(try repo.activeInvoiceNumbers(clientCode: "C1"), ["INV-1"])

        let outcome = try await CarteraSubmitService(repo: repo, api: api)
            .cancelPayment(paymentUUID: "pay-x", reason: nil, isOnline: true)

        XCTAssertEqual(outcome, .canceled)
        XCTAssertEqual(api.canceledPayments, ["pay-x"])
        let stored = try await db.dbQueue.read { try AccountPayment.fetchOne($0, key: "pay-x") }
        XCTAssertEqual(stored?.reportedStatus, .cancelado)
        XCTAssertTrue(try repo.activeInvoiceNumbers(clientCode: "C1").isEmpty,
                      "CANCELADO libera la factura, igual que RECHAZADO/descartado")
    }

    func test_cancelPayment_offline_noLlamaServer_niCambiaEstado() async throws {
        let db = try AppDatabase.makeInMemory(); let api = SubmitStubAPI()
        let repo = try reportedPaymentRepo(db, uuid: "pay-y", invoice: nil)

        let outcome = try await CarteraSubmitService(repo: repo, api: api)
            .cancelPayment(paymentUUID: "pay-y", reason: nil, isOnline: false)

        XCTAssertEqual(outcome, .needsConnection)
        XCTAssertEqual(api.canceledPayments, [])
        let stored = try await db.dbQueue.read { try AccountPayment.fetchOne($0, key: "pay-y") }
        XCTAssertEqual(stored?.syncStatus, .synced, "sigue reportado")
    }

    func test_cancelPayment_409_yaDecidido_noMarcaCanceled() async throws {
        let db = try AppDatabase.makeInMemory(); let api = SubmitStubAPI()
        api.cancelError = APIError.server(status: 409, message: "El pago ya fue decidido.")
        let repo = try reportedPaymentRepo(db, uuid: "pay-z", invoice: nil)

        let outcome = try await CarteraSubmitService(repo: repo, api: api)
            .cancelPayment(paymentUUID: "pay-z", reason: nil, isOnline: true)

        XCTAssertEqual(outcome, .alreadyDecided("El pago ya fue decidido."))
        let stored = try await db.dbQueue.read { try AccountPayment.fetchOne($0, key: "pay-z") }
        XCTAssertEqual(stored?.syncStatus, .synced, "un 409 no marca canceled localmente")
    }

    func test_cancelCreditRequest_online_marcaCanceled() async throws {
        let db = try AppDatabase.makeInMemory(); let api = SubmitStubAPI()
        var repo = CarteraRepository(database: db); repo.makeUUID = { "req-x" }
        _ = try repo.enqueueCreditRequest(clientCode: "C1", mode: .sinItems, reason: .mistake,
            manualAmount: 10, invoiceDocNum: nil, comments: nil, lines: [])
        try repo.markCreditRequestSynced(requestUUID: "req-x")

        let outcome = try await CarteraSubmitService(repo: repo, api: api)
            .cancelCreditRequest(requestUUID: "req-x", reason: "me equivoqué", isOnline: true)

        XCTAssertEqual(outcome, .canceled)
        XCTAssertEqual(api.canceledRequests, ["req-x"])
        let stored = try await db.dbQueue.read { try CreditRequest.fetchOne($0, key: "req-x") }
        XCTAssertEqual(stored?.reportedStatus, .cancelado)
    }

    func test_credito_conFoto_4xx_quedaFailedConMotivo() async throws {
        let db = try AppDatabase.makeInMemory(); let api = SubmitStubAPI()
        api.postError = APIError.server(status: 422, message: "Factura ya saldada.")
        let repo = CarteraRepository(database: db)

        let outcome = try await makeCreditService(db, api).submitCreditRequest(
            sinItemsDraft(), imageBase64: "b64", isOnline: true)

        XCTAssertEqual(outcome, .failed("Factura ya saldada."))
        XCTAssertEqual(try repo.failedCreditRequests().first?.failureReason, "Factura ya saldada.")
    }
}
