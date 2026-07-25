import XCTest
@testable import DinasSales

/// DTOs de red del bloque de cartera: el cuerpo del POST se arma con los nombres/formatos del
/// contrato v0.17.8 (snake_case, payment_date solo-fecha, modalidad por presencia de lines).
final class CarteraDTOTests: XCTestCase {

    private func json(_ value: Encodable) throws -> [String: Any] {
        let data = try JSONCoding.encoder.encode(AnyEncodable(value))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - Pago

    func test_accountPaymentCreate_body() throws {
        let payment = AccountPayment(
            paymentUUID: "pay-1", clientCode: "C1", method: .efectivo, amount: 150.75,
            paymentDate: Date(timeIntervalSince1970: 0), comments: "abono",
            evidenceImageURL: "https://mid/e/1.jpg",
            proposedApplications: [InvoiceApplication(invoiceDocNum: "F-1", amount: 100),
                                   InvoiceApplication(invoiceDocNum: "F-2", amount: 50.75)],
            syncStatus: .queued, createdAt: Date(), syncedAt: nil)

        let body = try json(AccountPaymentCreateDTO(payment))

        XCTAssertEqual(body["payment_uuid"] as? String, "pay-1")
        XCTAssertEqual(body["client_code"] as? String, "C1")
        XCTAssertEqual(body["amount"] as? Double, 150.75)
        XCTAssertEqual(body["method"] as? String, "EFECTIVO")
        XCTAssertEqual(body["payment_date"] as? String, "1970-01-01", "date solo-fecha, sin hora")
        XCTAssertEqual(body["evidence_image_url"] as? String, "https://mid/e/1.jpg")
        let apps = body["proposed_applications"] as? [[String: Any]]
        XCTAssertEqual(apps?.count, 2)
        XCTAssertEqual(apps?[0]["invoice_doc_num"] as? String, "F-1")
        XCTAssertEqual(apps?[0]["amount"] as? Double, 100)
        // ★ v0.19.1 — EFECTIVO no lleva datos de banco/cheque, y la app NUNCA envía payment_channel.
        XCTAssertNil(body["transfer_bank_account"])
        XCTAssertNil(body["check_number"])
        XCTAssertNil(body["bank_code"])
        XCTAssertNil(body["payment_channel"], "la app de vendedores nunca envía payment_channel")
    }

    func test_accountPaymentCreate_transferencia_llevaBanco_sinCheque() throws {
        let payment = AccountPayment(
            paymentUUID: "pay-t", clientCode: "C1", method: .transferencia, amount: 200,
            paymentDate: Date(timeIntervalSince1970: 0), comments: nil,
            transferBankAccount: .chase7815, checkNumber: nil, bankCode: nil,
            evidenceImageURL: nil, proposedApplications: [],
            syncStatus: .queued, createdAt: Date(), syncedAt: nil)

        let body = try json(AccountPaymentCreateDTO(payment))

        XCTAssertEqual(body["method"] as? String, "TRANSFERENCIA")
        XCTAssertEqual(body["transfer_bank_account"] as? String, "CHASE_7815")
        XCTAssertNil(body["check_number"], "TRANSFERENCIA no lleva datos de cheque")
        XCTAssertNil(body["bank_code"])
        XCTAssertNil(body["payment_channel"])
    }

    func test_accountPaymentCreate_cheque_llevaNumeroYBanco_sinTransferencia() throws {
        let payment = AccountPayment(
            paymentUUID: "pay-c", clientCode: "C1", method: .cheque, amount: 75,
            paymentDate: Date(timeIntervalSince1970: 0), comments: nil,
            transferBankAccount: nil, checkNumber: "000123", bankCode: "BAC",
            evidenceImageURL: nil, proposedApplications: [],
            syncStatus: .queued, createdAt: Date(), syncedAt: nil)

        let body = try json(AccountPaymentCreateDTO(payment))

        XCTAssertEqual(body["method"] as? String, "CHEQUE")
        XCTAssertEqual(body["check_number"] as? String, "000123")
        XCTAssertEqual(body["bank_code"] as? String, "BAC")
        XCTAssertNil(body["transfer_bank_account"], "CHEQUE no lleva banco de transferencia")
        XCTAssertNil(body["payment_channel"])
    }

    // MARK: - Crédito

    func test_creditRequestCreate_conItems_llevaLineas_sinManualAmount() throws {
        let request = CreditRequest(
            requestUUID: "req-1", clientCode: "C1", mode: .conItems, reason: .damaged,
            manualAmount: 999, invoiceDocNum: "F-9", comments: nil, evidenceImageURL: nil,
            syncStatus: .queued, createdAt: Date(), syncedAt: nil)
        let lines = [
            CreditRequestLine(id: 1, requestUUID: "req-1", itemCode: "I1", quantity: 2, reason: .damaged),
            CreditRequestLine(id: 2, requestUUID: "req-1", itemCode: "I2", quantity: 1, reason: .short),
        ]

        let body = try json(CreditRequestCreateDTO(request, lines: lines))

        XCTAssertEqual(body["request_uuid"] as? String, "req-1")
        XCTAssertEqual(body["reason"] as? String, "DAMAGED")
        XCTAssertEqual(body["invoice_doc_num"] as? String, "F-9")
        XCTAssertNil(body["manual_amount"], "CON_ITEMS no manda manual_amount (aunque el modelo lo tenga)")
        let ls = body["lines"] as? [[String: Any]]
        XCTAssertEqual(ls?.count, 2)
        XCTAssertEqual(ls?[0]["item_code"] as? String, "I1")
        XCTAssertEqual(ls?[0]["quantity"] as? Double, 2)
        XCTAssertEqual(ls?[1]["reason"] as? String, "SHORT")
    }

    func test_creditRequestCreate_sinItems_llevaManualAmount_sinLineas() throws {
        let request = CreditRequest(
            requestUUID: "req-2", clientCode: "C1", mode: .sinItems, reason: .mistake,
            manualAmount: 320.5, invoiceDocNum: nil, comments: "ajuste", evidenceImageURL: nil,
            syncStatus: .queued, createdAt: Date(), syncedAt: nil)

        let body = try json(CreditRequestCreateDTO(request, lines: []))

        XCTAssertEqual(body["manual_amount"] as? Double, 320.5)
        XCTAssertNil(body["lines"], "SIN_ITEMS no manda lines")
        XCTAssertNil(body["invoice_doc_num"])
    }

    // MARK: - Respuestas

    func test_decodeRespuestas() throws {
        let pay = try JSONCoding.decoder.decode(AccountPaymentAccepted.self, from: Data(
            #"{"payment_uuid":"pay-1","status":"PENDIENTE_APROBACION","received_at":"2026-07-23T10:00:00Z"}"#.utf8))
        XCTAssertEqual(pay.paymentUUID, "pay-1")
        XCTAssertEqual(pay.status, "PENDIENTE_APROBACION")

        let cr = try JSONCoding.decoder.decode(CreditRequestAccepted.self, from: Data(
            #"{"request_uuid":"req-1","status":"PENDIENTE_APROBACION","received_at":"2026-07-23T10:00:00Z"}"#.utf8))
        XCTAssertEqual(cr.requestUUID, "req-1")

        let photo = try JSONCoding.decoder.decode(EvidencePhotoUploaded.self, from: Data(
            #"{"evidence_image_url":"https://mid/e/1.jpg"}"#.utf8))
        XCTAssertEqual(photo.evidenceImageURL, "https://mid/e/1.jpg")
    }
}

/// Envuelve un `Encodable` cualquiera para poder serializarlo en los tests.
private struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeFunc = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeFunc(encoder) }
}
