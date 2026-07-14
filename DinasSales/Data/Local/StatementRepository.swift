import Foundation
import GRDB

/// Estado de cuenta del cliente en la base local (★ v0.4.0).
///
/// La app baja el statement por cliente (`GET /clients/{code}/statement`) y lo guarda
/// aquí para que el vendedor lo consulte OFFLINE al visitarlo. El `balance` oficial vive
/// en `Client.credit`; esto es el desglose de documentos (facturas, NC, pagos).
struct StatementRepository {
    let database: AppDatabase

    /// Reemplaza el estado de cuenta local del cliente por el recién bajado.
    /// Rellena los campos locales (`client_code`, `as_of`) en cada documento.
    func save(_ statement: ClientStatement) throws {
        try database.dbQueue.write { db in
            try StatementDocument
                .filter(Column("client_code") == statement.clientCode)
                .deleteAll(db)
            for var doc in statement.documents {
                doc.id = nil                       // autoincrement local
                doc.clientCode = statement.clientCode
                doc.asOf = statement.asOf
                try doc.insert(db)
            }
        }
    }

    /// Documentos del estado de cuenta del cliente. Orden: primero las facturas vencidas
    /// (más atrasada arriba), luego el resto de facturas, y al final NC/pagos.
    func documents(clientCode: String) throws -> [StatementDocument] {
        try database.dbQueue.read { db in
            try StatementDocument
                .filter(Column("client_code") == clientCode)
                .fetchAll(db)
        }
        .sorted(by: Self.displayOrder)
    }

    /// Momento (`as_of`) de la última bajada del statement del cliente, si hay.
    func asOf(clientCode: String) throws -> Date? {
        try database.dbQueue.read { db in
            try StatementDocument
                .filter(Column("client_code") == clientCode)
                .fetchOne(db)?.asOf
        }
    }

    /// ¿Hay estado de cuenta guardado para el cliente?
    func hasStatement(clientCode: String) throws -> Bool {
        try database.dbQueue.read { db in
            try StatementDocument.filter(Column("client_code") == clientCode).fetchCount(db) > 0
        }
    }

    /// Orden de presentación: facturas vencidas (más días de atraso primero), luego las
    /// demás facturas, y al final las NC y pagos (que restan deuda).
    private static func displayOrder(_ a: StatementDocument, _ b: StatementDocument) -> Bool {
        func rank(_ d: StatementDocument) -> Int {
            if d.openAmount < 0 { return 2 }   // NC / pagos al final
            return d.isOverdue ? 0 : 1         // facturas vencidas primero
        }
        let (ra, rb) = (rank(a), rank(b))
        if ra != rb { return ra < rb }
        if ra == 0 { return (a.daysOverdue ?? 0) > (b.daysOverdue ?? 0) }  // más vencida arriba
        return (a.docDate ?? .distantPast) > (b.docDate ?? .distantPast)  // más reciente arriba
    }
}
