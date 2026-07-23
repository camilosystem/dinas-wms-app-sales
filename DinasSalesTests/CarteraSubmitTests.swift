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
    func postCreditRequest(_ request: CreditRequest, lines: [CreditRequestLine]) async throws -> CreditRequestAccepted {
        CreditRequestAccepted(requestUUID: request.requestUUID, status: "", receivedAt: nil)
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
}
