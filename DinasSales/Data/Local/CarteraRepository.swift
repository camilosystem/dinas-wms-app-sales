import Foundation
import GRDB

/// Cola local de cartera: reportes de pago y solicitudes de crédito.
///
/// Regla offline (v0.17.7): los envíos SIN foto se ENCOLAN (`queued`) y los sube el `SyncEngine`
/// como las órdenes. Los envíos CON foto son síncronos (subir foto → crear en la misma sesión) y
/// se GUARDAN ya como `synced` — nunca pasan por la cola. El `payment_uuid`/`request_uuid` se
/// genera AL CREAR el registro local (no al subir), para que la idempotencia funcione aunque el
/// registro espere en la cola antes de tener señal.
struct CarteraRepository {
    let database: AppDatabase
    /// Inyectables para tests deterministas.
    var now: () -> Date = Date.init
    var makeUUID: () -> String = { UUID().uuidString }

    // MARK: - Pagos de cartera

    /// Encola un pago SIN foto (`queued`). Devuelve el registro creado (con su `payment_uuid`).
    @discardableResult
    func enqueuePayment(clientUUID: String, clientCode: String, method: AccountPaymentMethod,
                        amount: Double, paymentDate: Date, comments: String?,
                        proposedApplications: [InvoiceApplication]) throws -> AccountPayment {
        let payment = AccountPayment(
            paymentUUID: makeUUID(), clientUUID: clientUUID, clientCode: clientCode,
            method: method, amount: amount, paymentDate: paymentDate, comments: comments,
            evidenceImageURL: nil, proposedApplications: proposedApplications,
            syncStatus: .queued, createdAt: now(), syncedAt: nil)
        try database.dbQueue.write { try payment.insert($0) }
        return payment
    }

    /// Guarda un pago YA enviado síncrono (con foto) directamente como `synced`. El `payment_uuid`
    /// debe ser el que se generó al crear el registro local (idempotencia estable).
    func saveSyncedPayment(_ payment: AccountPayment) throws {
        var synced = payment
        synced.syncStatus = .synced
        synced.syncedAt = payment.syncedAt ?? now()
        try database.dbQueue.write { try synced.insert($0) }
    }

    /// Pagos en cola pendientes de subir (los `queued`), más antiguos primero.
    func pendingPayments() throws -> [AccountPayment] {
        try database.dbQueue.read { db in
            try AccountPayment
                .filter(Column("sync_status") == QueueSyncStatus.queued.rawValue)
                .order(Column("created_at"))
                .fetchAll(db)
        }
    }

    /// Marca un pago como subido (`synced`), guardando la URL de evidencia si el servidor la asignó.
    func markPaymentSynced(paymentUUID: String, evidenceImageURL: String? = nil) throws {
        try database.dbQueue.write { db in
            guard var payment = try AccountPayment.fetchOne(db, key: paymentUUID) else { return }
            payment.syncStatus = .synced
            payment.syncedAt = now()
            if let evidenceImageURL { payment.evidenceImageURL = evidenceImageURL }
            try payment.update(db)
        }
    }

    // MARK: - Solicitudes de crédito

    /// Encola una solicitud SIN foto (`queued`). `lines` solo para CON_ITEMS (vacío en SIN_ITEMS).
    @discardableResult
    func enqueueCreditRequest(clientUUID: String, clientCode: String, mode: CreditRequestMode,
                              reason: CreditRequestReason, manualAmount: Double?,
                              invoiceDocNum: String?, comments: String?,
                              lines: [CreditRequestLineInput]) throws -> CreditRequest {
        let request = CreditRequest(
            requestUUID: makeUUID(), clientUUID: clientUUID, clientCode: clientCode, mode: mode,
            reason: reason, manualAmount: manualAmount, invoiceDocNum: invoiceDocNum,
            comments: comments, evidenceImageURL: nil, syncStatus: .queued,
            createdAt: now(), syncedAt: nil)
        try database.dbQueue.write { db in
            try request.insert(db)
            for line in lines {
                var record = CreditRequestLine(id: nil, requestUUID: request.requestUUID,
                                               itemCode: line.itemCode, quantity: line.quantity,
                                               reason: line.reason)
                try record.insert(db)
            }
        }
        return request
    }

    /// Solicitudes en cola pendientes de subir, más antiguas primero.
    func pendingCreditRequests() throws -> [CreditRequest] {
        try database.dbQueue.read { db in
            try CreditRequest
                .filter(Column("sync_status") == QueueSyncStatus.queued.rawValue)
                .order(Column("created_at"))
                .fetchAll(db)
        }
    }

    /// Líneas de una solicitud CON_ITEMS.
    func lines(requestUUID: String) throws -> [CreditRequestLine] {
        try database.dbQueue.read { db in
            try CreditRequestLine
                .filter(Column("request_uuid") == requestUUID)
                .order(Column("id"))
                .fetchAll(db)
        }
    }

    /// Marca una solicitud como subida (`synced`).
    func markCreditRequestSynced(requestUUID: String) throws {
        try database.dbQueue.write { db in
            guard var request = try CreditRequest.fetchOne(db, key: requestUUID) else { return }
            request.syncStatus = .synced
            request.syncedAt = now()
            try request.update(db)
        }
    }
}

/// Entrada de una línea al encolar una solicitud CON_ITEMS (sin `id`, que lo asigna GRDB).
struct CreditRequestLineInput: Equatable {
    var itemCode: String
    var quantity: Double
    var reason: CreditRequestReason
}
