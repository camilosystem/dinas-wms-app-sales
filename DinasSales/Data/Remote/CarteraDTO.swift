import Foundation

// DTOs de red del bloque de cartera (contrato v0.17.8). Los modelos LOCALES (AccountPayment,
// CreditRequest…) llevan campos que no van en el POST (sync_status, created_at…); estos DTOs
// arman exactamente el cuerpo que espera el middleware.

// MARK: - Evidencia (foto)

/// `EvidencePhotoUpload` — sube la imagen (base64) y devuelve su URL, ANTES de crear el registro.
/// Requiere conexión (no hay forma de generar `evidence_image_url` localmente).
struct EvidencePhotoUpload: Encodable {
    let imageBase64: String
    let clientCode: String?

    enum CodingKeys: String, CodingKey {
        case imageBase64 = "image_base64"
        case clientCode = "client_code"
    }
}

/// `EvidencePhotoUploaded` — respuesta con la URL de la imagen ya subida.
struct EvidencePhotoUploaded: Decodable {
    let evidenceImageURL: String

    enum CodingKeys: String, CodingKey { case evidenceImageURL = "evidence_image_url" }
}

// MARK: - Pago de cartera

/// `AccountPaymentCreate` — cuerpo de `POST /account-payments`. `payment_date` viaja como
/// `format: date` (YYYY-MM-DD), no date-time.
/// NO incluye `payment_channel`: la app de vendedores nunca lo envía — el server lo fija a
/// VENDEDOR para EFECTIVO/CHEQUE. `transfer_bank_account` solo en TRANSFERENCIA; `check_number`/
/// `bank_code` solo en CHEQUE (el resto quedan null, garantizado por la UI que arma el registro).
struct AccountPaymentCreateDTO: Encodable {
    let paymentUUID: String
    let clientCode: String
    let amount: Double
    let method: AccountPaymentMethod
    let paymentDate: String                 // YYYY-MM-DD
    let comments: String?
    let transferBankAccount: TransferBankAccount?
    let checkNumber: String?
    let bankCode: String?
    let evidenceImageURL: String?
    let proposedApplications: [InvoiceApplication]

    enum CodingKeys: String, CodingKey {
        case paymentUUID = "payment_uuid"
        case clientCode = "client_code"
        case amount, method, comments
        case paymentDate = "payment_date"
        case transferBankAccount = "transfer_bank_account"
        case checkNumber = "check_number"
        case bankCode = "bank_code"
        case evidenceImageURL = "evidence_image_url"
        case proposedApplications = "proposed_applications"
    }

    init(_ payment: AccountPayment) {
        paymentUUID = payment.paymentUUID
        clientCode = payment.clientCode
        amount = payment.amount
        method = payment.method
        paymentDate = JSONCoding.dateOnlyString(payment.paymentDate)
        comments = payment.comments
        transferBankAccount = payment.transferBankAccount
        checkNumber = payment.checkNumber
        bankCode = payment.bankCode
        evidenceImageURL = payment.evidenceImageURL
        proposedApplications = payment.proposedApplications
    }
}

/// `AccountPaymentAccepted` — respuesta del POST (idempotente por `payment_uuid`).
struct AccountPaymentAccepted: Decodable {
    let paymentUUID: String
    let status: String?          // ApprovalStatus (PENDIENTE_APROBACION…)
    let receivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case paymentUUID = "payment_uuid"
        case status
        case receivedAt = "received_at"
    }
}

// MARK: - Solicitud de crédito

/// `CreditRequestLine` — línea de una solicitud CON_ITEMS. Sin `unit_price` (lo resuelve el mid).
struct CreditRequestLineDTO: Encodable {
    let itemCode: String
    let quantity: Double
    let reason: CreditRequestReason

    enum CodingKeys: String, CodingKey {
        case itemCode = "item_code"
        case quantity, reason
    }
}

/// `CreditRequestCreate` — cuerpo de `POST /credit-requests`. La modalidad la determina la
/// presencia de `lines` (CON_ITEMS) o de `manual_amount` (SIN_ITEMS) — nunca ambos.
struct CreditRequestCreateDTO: Encodable {
    let requestUUID: String
    let clientCode: String
    let invoiceDocNum: String?
    let reason: CreditRequestReason
    let lines: [CreditRequestLineDTO]?
    let manualAmount: Double?
    let comments: String?
    let evidenceImageURL: String?

    enum CodingKeys: String, CodingKey {
        case requestUUID = "request_uuid"
        case clientCode = "client_code"
        case invoiceDocNum = "invoice_doc_num"
        case reason, lines, comments
        case manualAmount = "manual_amount"
        case evidenceImageURL = "evidence_image_url"
    }

    init(_ request: CreditRequest, lines: [CreditRequestLine]) {
        requestUUID = request.requestUUID
        clientCode = request.clientCode
        invoiceDocNum = request.invoiceDocNum
        reason = request.reason
        comments = request.comments
        evidenceImageURL = request.evidenceImageURL
        switch request.mode {
        case .conItems:
            self.lines = lines.map {
                CreditRequestLineDTO(itemCode: $0.itemCode, quantity: $0.quantity, reason: $0.reason)
            }
            manualAmount = nil
        case .sinItems:
            self.lines = nil
            manualAmount = request.manualAmount
        }
    }
}

// MARK: - Cancelación (★ v0.21.0)

/// Cuerpo (opcional) de `POST …/cancel`: motivo opcional del vendedor. Si `reason` es nil, el
/// encoder omite la clave → body `{}`, válido porque el requestBody del contrato es opcional.
struct CarteraCancelDTO: Encodable {
    let reason: String?
}

/// Respuesta de `…/cancel` (AccountPaymentDetail / CreditRequestDetail). Solo nos importa el
/// estado resultante (CANCELADO); el resto del detalle no lo usa la app.
struct CarteraCancelResult: Decodable {
    let status: String?
}

/// `CreditRequestAccepted` — respuesta del POST (idempotente por `request_uuid`).
struct CreditRequestAccepted: Decodable {
    let requestUUID: String
    let status: String?
    let receivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case requestUUID = "request_uuid"
        case status
        case receivedAt = "received_at"
    }
}
