import XCTest
import GRDB
@testable import DinasSales

/// Stub de red para el enganche de la cola de cartera al SyncEngine.
private final class CarteraStubAPI: SyncDownAPI, SyncUpAPI, CarteraUploadAPI, @unchecked Sendable {
    /// Si es no-nil, los POST de cartera lanzan este error (4xx permanente o transitorio).
    var carteraError: Error?
    private(set) var postedPayments: [String] = []
    private(set) var postedRequests: [String] = []

    func fetchCatalog(since: Date?) async throws -> CatalogPage { CatalogPage(items: [], serverTime: Date(timeIntervalSince1970: 0)) }
    func fetchClients(since: Date?) async throws -> ClientsPage { ClientsPage(clients: [], serverTime: Date(timeIntervalSince1970: 0)) }
    func fetchOrderStatuses(since: Date?) async throws -> OrdersStatusPage { OrdersStatusPage(updates: [], serverTime: Date(timeIntervalSince1970: 0)) }
    func postOrder(_ order: Order, lines: [OrderLine]) async throws -> OrderAcceptedDTO {
        OrderAcceptedDTO(clientUUID: order.clientUUID, orderNumber: "N", status: "SINCRONIZADA", holdReason: nil, receivedAt: nil)
    }
    func uploadEvidencePhoto(imageBase64: String, clientCode: String?) async throws -> String { "u" }
    func postAccountPayment(_ payment: AccountPayment) async throws -> AccountPaymentAccepted {
        if let carteraError { throw carteraError }
        postedPayments.append(payment.paymentUUID)
        return AccountPaymentAccepted(paymentUUID: payment.paymentUUID, status: "PENDIENTE_APROBACION", receivedAt: nil)
    }
    func postCreditRequest(_ request: CreditRequest, lines: [CreditRequestLine]) async throws -> CreditRequestAccepted {
        if let carteraError { throw carteraError }
        postedRequests.append(request.requestUUID)
        return CreditRequestAccepted(requestUUID: request.requestUUID, status: "PENDIENTE_APROBACION", receivedAt: nil)
    }
}

@MainActor
final class CarteraSyncTests: XCTestCase {

    private func engine(_ db: AppDatabase, _ api: CarteraStubAPI) -> SyncEngine {
        SyncEngine(database: db, api: api, now: { Date(timeIntervalSince1970: 2000) })
    }

    private func seedQueuedPayment(_ repo: CarteraRepository) throws -> AccountPayment {
        try repo.enqueuePayment(clientCode: "C1", method: .efectivo, amount: 100,
                                paymentDate: Date(timeIntervalSince1970: 0), comments: nil,
                                proposedApplications: [])
    }

    func test_sync_subeLaColaYlaMarcaSynced() async throws {
        let db = try AppDatabase.makeInMemory()
        var repo = CarteraRepository(database: db); repo.makeUUID = { "pay-1" }
        _ = try seedQueuedPayment(repo)
        let api = CarteraStubAPI()

        await engine(db, api).sync()

        XCTAssertEqual(api.postedPayments, ["pay-1"], "se subió el pago en cola")
        XCTAssertTrue(try repo.pendingPayments().isEmpty, "ya no está en cola")
        let stored = try await db.dbQueue.read { try AccountPayment.fetchOne($0, key: "pay-1") }
        XCTAssertEqual(stored?.syncStatus, .synced)
    }

    func test_sync_4xxPermanente_marcaFailedConMotivo() async throws {
        let db = try AppDatabase.makeInMemory()
        var repo = CarteraRepository(database: db); repo.makeUUID = { "pay-1" }
        _ = try seedQueuedPayment(repo)
        let api = CarteraStubAPI()
        api.carteraError = APIError.server(status: 422, message: "El monto excede el saldo abierto.")

        await engine(db, api).sync()

        XCTAssertTrue(try repo.pendingPayments().isEmpty, "salió de la cola (no reintento silencioso)")
        let failed = try repo.failedPayments()
        XCTAssertEqual(failed.map(\.paymentUUID), ["pay-1"])
        XCTAssertEqual(failed.first?.syncStatus, .failed)
        XCTAssertEqual(failed.first?.failureReason, "El monto excede el saldo abierto.",
                       "guarda el motivo del servidor para el panel")
    }

    func test_sync_errorTransitorio_sigueEnCola() async throws {
        let db = try AppDatabase.makeInMemory()
        var repo = CarteraRepository(database: db); repo.makeUUID = { "pay-1" }
        _ = try seedQueuedPayment(repo)
        let api = CarteraStubAPI()
        api.carteraError = URLError(.timedOut)   // transitorio, no permanente

        await engine(db, api).sync()

        XCTAssertEqual(try repo.pendingPayments().map(\.paymentUUID), ["pay-1"],
                       "un error transitorio deja el pago en cola para reintentar")
        XCTAssertTrue(try repo.failedPayments().isEmpty, "no se marca failed por un transitorio")
    }

    // MARK: - Acciones del panel (corregir/reintentar, descartar)

    func test_retry_devuelveAlaCola_discard_loElimina() throws {
        let db = try AppDatabase.makeInMemory()
        var repo = CarteraRepository(database: db); repo.makeUUID = { "pay-1" }
        _ = try seedQueuedPayment(repo)
        try repo.markPaymentFailed(paymentUUID: "pay-1", reason: "rechazado")

        try repo.retryPayment(paymentUUID: "pay-1")
        XCTAssertEqual(try repo.pendingPayments().map(\.paymentUUID), ["pay-1"], "retry → vuelve a la cola")
        XCTAssertTrue(try repo.failedPayments().isEmpty)

        try repo.markPaymentFailed(paymentUUID: "pay-1", reason: "otra vez")
        try repo.discardPayment(paymentUUID: "pay-1")
        XCTAssertTrue(try repo.failedPayments().isEmpty, "discard → eliminado")
        XCTAssertNil(try db.dbQueue.read { try AccountPayment.fetchOne($0, key: "pay-1") })
    }
}
