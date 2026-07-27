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

    /// Encola un pago (`queued`). `evidenceImageURL` es nil en envíos sin foto; en los envíos
    /// CON foto ya trae la URL (de `POST /evidence-photos`) para que el POST de creación la use
    /// y, si falla, el `SyncEngine` lo reintente SIN volver a subir la foto. Devuelve el registro
    /// con su `payment_uuid` (generado AL CREAR).
    @discardableResult
    func enqueuePayment(clientCode: String, method: AccountPaymentMethod,
                        amount: Double, paymentDate: Date, comments: String?,
                        proposedApplications: [InvoiceApplication],
                        transferBankAccount: TransferBankAccount? = nil,
                        checkNumber: String? = nil, bankCode: String? = nil,
                        evidenceImageURL: String? = nil) throws -> AccountPayment {
        let payment = AccountPayment(
            paymentUUID: makeUUID(), clientCode: clientCode,
            method: method, amount: amount, paymentDate: paymentDate, comments: comments,
            transferBankAccount: transferBankAccount, checkNumber: checkNumber, bankCode: bankCode,
            evidenceImageURL: evidenceImageURL, proposedApplications: proposedApplications,
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
            payment.failureReason = nil
            if let evidenceImageURL { payment.evidenceImageURL = evidenceImageURL }
            try payment.update(db)
        }
    }

    /// Marca un pago como RECHAZADO permanentemente (4xx), con el motivo del servidor.
    func markPaymentFailed(paymentUUID: String, reason: String) throws {
        try database.dbQueue.write { db in
            guard var payment = try AccountPayment.fetchOne(db, key: paymentUUID) else { return }
            payment.syncStatus = .failed
            payment.failureReason = reason
            try payment.update(db)
        }
    }

    /// Marca un pago como CANCELADO (★ v0.21.0) tras cancelarlo en el server. Deja de ser activo:
    /// ya no bloquea facturas ni se reintenta.
    func markPaymentCanceled(paymentUUID: String) throws {
        try database.dbQueue.write { db in
            guard var payment = try AccountPayment.fetchOne(db, key: paymentUUID) else { return }
            payment.syncStatus = .canceled
            payment.failureReason = nil
            try payment.update(db)
        }
    }

    /// Reintenta un pago fallido: lo devuelve a la cola (`queued`) para el próximo sync.
    func retryPayment(paymentUUID: String) throws {
        try database.dbQueue.write { db in
            guard var payment = try AccountPayment.fetchOne(db, key: paymentUUID) else { return }
            payment.syncStatus = .queued
            payment.failureReason = nil
            try payment.update(db)
        }
    }

    /// Descarta un pago (p. ej. uno fallido que el vendedor decide no reintentar).
    func discardPayment(paymentUUID: String) throws {
        try database.dbQueue.write { db in _ = try AccountPayment.deleteOne(db, key: paymentUUID) }
    }

    /// Todos los pagos reportados de un cliente (cualquier estado), más recientes primero. Para
    /// mostrar en el detalle del cliente qué se ha reportado y su estado (por enviar/reportado/
    /// con problema), y evitar que el vendedor reporte dos veces lo mismo por confusión.
    func payments(clientCode: String) throws -> [AccountPayment] {
        try database.dbQueue.read { db in
            try AccountPayment
                .filter(Column("client_code") == clientCode)
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    /// Números de factura ya referenciados en pagos ACTIVOS del cliente — activo = en cola
    /// (`queued`) o ya reportado sin decisión conocida (`synced`). Se usan para bloquear esas
    /// facturas en el selector de un pago nuevo (evita reportarlas dos veces). Un pago `failed`
    /// NO bloquea (se resolverá en el panel de problemas); si se descarta un activo, su factura
    /// se libera al recomputar.
    func activeInvoiceNumbers(clientCode: String) throws -> Set<String> {
        let active = [QueueSyncStatus.queued.rawValue, QueueSyncStatus.synced.rawValue]
        let payments = try database.dbQueue.read { db in
            try AccountPayment
                .filter(Column("client_code") == clientCode)
                .filter(active.contains(Column("sync_status")))
                .fetchAll(db)
        }
        return Set(payments.flatMap { $0.proposedApplications.map(\.invoiceDocNum) })
    }

    /// Pagos con problema de sincronización (rechazados), para el panel de problemas.
    func failedPayments() throws -> [AccountPayment] {
        try database.dbQueue.read { db in
            try AccountPayment
                .filter(Column("sync_status") == QueueSyncStatus.failed.rawValue)
                .order(Column("created_at")).fetchAll(db)
        }
    }

    // MARK: - Solicitudes de crédito

    /// Encola una solicitud SIN foto (`queued`). `lines` solo para CON_ITEMS (vacío en SIN_ITEMS).
    @discardableResult
    func enqueueCreditRequest(clientCode: String, mode: CreditRequestMode,
                              reason: CreditRequestReason, manualAmount: Double?,
                              invoiceDocNum: String?, comments: String?,
                              lines: [CreditRequestLineInput],
                              evidenceImageURL: String? = nil) throws -> CreditRequest {
        let request = CreditRequest(
            requestUUID: makeUUID(), clientCode: clientCode, mode: mode,
            reason: reason, manualAmount: manualAmount, invoiceDocNum: invoiceDocNum,
            comments: comments, evidenceImageURL: evidenceImageURL, syncStatus: .queued,
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
            request.failureReason = nil
            try request.update(db)
        }
    }

    /// Marca una solicitud como RECHAZADA permanentemente (4xx), con el motivo del servidor.
    func markCreditRequestFailed(requestUUID: String, reason: String) throws {
        try database.dbQueue.write { db in
            guard var request = try CreditRequest.fetchOne(db, key: requestUUID) else { return }
            request.syncStatus = .failed
            request.failureReason = reason
            try request.update(db)
        }
    }

    /// Todas las solicitudes de crédito de un cliente (cualquier estado), más recientes primero,
    /// para mostrarlas con su estado en el detalle del cliente.
    func creditRequests(clientCode: String) throws -> [CreditRequest] {
        try database.dbQueue.read { db in
            try CreditRequest
                .filter(Column("client_code") == clientCode)
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    /// Marca una solicitud como CANCELADA (★ v0.21.0) tras cancelarla en el server.
    func markCreditRequestCanceled(requestUUID: String) throws {
        try database.dbQueue.write { db in
            guard var request = try CreditRequest.fetchOne(db, key: requestUUID) else { return }
            request.syncStatus = .canceled
            request.failureReason = nil
            try request.update(db)
        }
    }

    /// Reintenta una solicitud fallida: la devuelve a la cola (`queued`).
    func retryCreditRequest(requestUUID: String) throws {
        try database.dbQueue.write { db in
            guard var request = try CreditRequest.fetchOne(db, key: requestUUID) else { return }
            request.syncStatus = .queued
            request.failureReason = nil
            try request.update(db)
        }
    }

    /// Descarta una solicitud (arrastra sus líneas por ON DELETE CASCADE).
    func discardCreditRequest(requestUUID: String) throws {
        try database.dbQueue.write { db in _ = try CreditRequest.deleteOne(db, key: requestUUID) }
    }

    /// Solicitudes con problema de sincronización (rechazadas), para el panel de problemas.
    func failedCreditRequests() throws -> [CreditRequest] {
        try database.dbQueue.read { db in
            try CreditRequest
                .filter(Column("sync_status") == QueueSyncStatus.failed.rawValue)
                .order(Column("created_at")).fetchAll(db)
        }
    }
}

/// Entrada de una línea al encolar una solicitud CON_ITEMS (sin `id`, que lo asigna GRDB).
struct CreditRequestLineInput: Equatable {
    var itemCode: String
    var quantity: Double
    var reason: CreditRequestReason
}
