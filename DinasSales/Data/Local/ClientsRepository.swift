import Foundation
import GRDB

/// Consultas de clientes sobre la base local (offline).
///
/// La app solo tiene los clientes ASIGNADOS al vendedor (los que devolvió
/// `GET /sync/clients`, filtrados por token). No hay lógica de asignación en el cliente.
struct ClientsRepository {
    let database: AppDatabase

    /// Clientes ordenados por nombre. Si `query` no está vacío, filtra por código,
    /// nombre, ciudad o ruta de reparto (subcadena, sin distinguir mayúsculas).
    /// `activeOnly` excluye los dados de baja en SAP (para tomar órdenes NUEVAS); la
    /// pestaña Clientes los muestra igual (marcados inactivos) porque conservan órdenes.
    func clients(matching query: String, activeOnly: Bool = false) throws -> [Client] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try database.dbQueue.read { db in
            var request = Client.all()

            if activeOnly {
                request = request.filter(Column("active") == true)
            }

            if !trimmed.isEmpty {
                let pattern = "%\(escapeLike(trimmed))%"
                let esc: SQLExpressible = "\\"
                request = request.filter(
                    Column("client_code").like(pattern, escape: esc)
                    || Column("name").like(pattern, escape: esc)
                    || Column("city").like(pattern, escape: esc)
                    || Column("shipping_route").like(pattern, escape: esc)
                )
            }

            return try request.order(Column("name")).fetchAll(db)
        }
    }

    /// Un cliente por su código.
    func client(code: String) throws -> Client? {
        try database.dbQueue.read { db in
            try Client.fetchOne(db, key: code)
        }
    }

    /// Escapa los comodines de LIKE para tratar el texto del usuario como literal.
    private func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
