import Foundation

/// Borrador de un reporte de pago que llega desde la UI.
struct PaymentDraft: Equatable {
    var clientCode: String
    var method: AccountPaymentMethod
    var amount: Double
    var paymentDate: Date
    var comments: String?
    var proposedApplications: [InvoiceApplication]
}

/// Borrador de una solicitud de crédito que llega desde la UI.
/// `mode` decide qué campos viajan: CON_ITEMS usa `lines` (sin `manualAmount`); SIN_ITEMS usa
/// `manualAmount` (sin `lines`). `reason` es obligatorio en AMBAS modalidades; `invoiceDocNum`
/// es opcional en ambas.
struct CreditRequestDraft: Equatable {
    var clientCode: String
    var mode: CreditRequestMode
    var reason: CreditRequestReason
    var manualAmount: Double?
    var invoiceDocNum: String?
    var comments: String?
    var lines: [CreditRequestLineInput]
}

/// Resultado de intentar reportar un pago (para el mensaje al vendedor).
enum CarteraSubmitOutcome: Equatable {
    case queued                    // sin foto → en cola; lo sube el SyncEngine
    case sent                      // con foto → foto subida + POST aceptado en el momento
    case pendingUpload             // con foto: foto subida, pero el POST falló transitorio → en cola (reintenta con la URL, sin resubir foto)
    case failed(String)            // el servidor lo rechazó (4xx) → queda en el panel de problemas
    case blockedNeedsConnection    // con foto y sin señal → se bloquea; el vendedor decide
}

/// Orquesta el envío de un reporte de pago según la regla offline (v0.17.7):
/// - SIN foto → a la cola (`enqueue`), lo sube el `SyncEngine` como las órdenes.
/// - CON foto → requiere conexión: sube la foto (`POST /evidence-photos`) → crea el pago con esa
///   URL y lo postea en el momento. Si el POST falla transitorio, queda en cola CON la URL (el
///   `SyncEngine` reintenta el POST, nunca resube la foto). Un 4xx lo deja `failed` con el motivo.
/// - CON foto y SIN señal → NO se envía a una cola que no resolvería bien la foto: se BLOQUEA.
struct CarteraSubmitService {
    let repo: CarteraRepository
    let api: CarteraUploadAPI

    /// `imageBase64` no-nil = el vendedor adjuntó foto. `isOnline` decide si con foto se puede.
    func submitPayment(_ draft: PaymentDraft, imageBase64: String?,
                       isOnline: Bool) async throws -> CarteraSubmitOutcome {
        // Sin foto: derecho a la cola (no depende de /evidence-photos).
        guard let imageBase64 else {
            _ = try repo.enqueuePayment(
                clientCode: draft.clientCode, method: draft.method, amount: draft.amount,
                paymentDate: draft.paymentDate, comments: draft.comments,
                proposedApplications: draft.proposedApplications)
            return .queued
        }

        // Con foto: requiere conexión EN EL MOMENTO (no hay forma de generar la URL local).
        guard isOnline else { return .blockedNeedsConnection }

        // 1. Subir la foto → URL (si esto falla, no se creó nada; el vendedor reintenta).
        let url = try await api.uploadEvidencePhoto(imageBase64: imageBase64,
                                                    clientCode: draft.clientCode)
        // 2. Crear el registro local (uuid al crear) con la URL ya obtenida.
        let payment = try repo.enqueuePayment(
            clientCode: draft.clientCode, method: draft.method, amount: draft.amount,
            paymentDate: draft.paymentDate, comments: draft.comments,
            proposedApplications: draft.proposedApplications, evidenceImageURL: url)
        // 3. Postear el pago con la URL. La foto NO se resube pase lo que pase.
        do {
            _ = try await api.postAccountPayment(payment)
            try repo.markPaymentSynced(paymentUUID: payment.paymentUUID)
            return .sent
        } catch let error as APIError where error.isPermanent {
            let reason = error.serverMessage ?? "El servidor rechazó el pago (\(error.serverStatus))."
            try repo.markPaymentFailed(paymentUUID: payment.paymentUUID, reason: reason)
            return .failed(reason)
        } catch {
            // Transitorio: queda en cola CON la URL → el SyncEngine reintenta solo el POST.
            return .pendingUpload
        }
    }

    /// Misma regla offline que `submitPayment`, para solicitudes de crédito. Se reutiliza la rama
    /// de decisión (sin foto → cola; con foto y sin señal → bloqueo; con foto y online → subir
    /// foto + crear + postear en el momento). Las `lines` (CON_ITEMS) se encolan con la solicitud.
    func submitCreditRequest(_ draft: CreditRequestDraft, imageBase64: String?,
                             isOnline: Bool) async throws -> CarteraSubmitOutcome {
        // Sin foto: derecho a la cola (no depende de /evidence-photos).
        guard let imageBase64 else {
            _ = try repo.enqueueCreditRequest(
                clientCode: draft.clientCode, mode: draft.mode, reason: draft.reason,
                manualAmount: draft.manualAmount, invoiceDocNum: draft.invoiceDocNum,
                comments: draft.comments, lines: draft.lines)
            return .queued
        }

        // Con foto: requiere conexión EN EL MOMENTO (no hay forma de generar la URL local).
        guard isOnline else { return .blockedNeedsConnection }

        // 1. Subir la foto → URL (si esto falla, no se creó nada; el vendedor reintenta).
        let url = try await api.uploadEvidencePhoto(imageBase64: imageBase64,
                                                    clientCode: draft.clientCode)
        // 2. Crear el registro local (uuid al crear) con la URL ya obtenida, más sus líneas.
        let request = try repo.enqueueCreditRequest(
            clientCode: draft.clientCode, mode: draft.mode, reason: draft.reason,
            manualAmount: draft.manualAmount, invoiceDocNum: draft.invoiceDocNum,
            comments: draft.comments, lines: draft.lines, evidenceImageURL: url)
        let lines = try repo.lines(requestUUID: request.requestUUID)
        // 3. Postear la solicitud con la URL. La foto NO se resube pase lo que pase.
        do {
            _ = try await api.postCreditRequest(request, lines: lines)
            try repo.markCreditRequestSynced(requestUUID: request.requestUUID)
            return .sent
        } catch let error as APIError where error.isPermanent {
            let reason = error.serverMessage ?? "El servidor rechazó la solicitud (\(error.serverStatus))."
            try repo.markCreditRequestFailed(requestUUID: request.requestUUID, reason: reason)
            return .failed(reason)
        } catch {
            // Transitorio: queda en cola CON la URL → el SyncEngine reintenta solo el POST.
            return .pendingUpload
        }
    }
}
