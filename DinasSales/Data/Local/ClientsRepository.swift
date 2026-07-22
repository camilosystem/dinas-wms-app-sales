import Foundation
import GRDB

/// Consultas de clientes sobre la base local (offline).
///
/// La app solo tiene los clientes ASIGNADOS al vendedor (los que devolvió
/// `GET /sync/clients`, filtrados por token). No hay lógica de asignación en el cliente.
struct ClientsRepository {
    let database: AppDatabase

    /// Clientes ordenados por nombre. Si `query` no está vacío, filtra por código,
    /// nombre, ciudad o ruta de reparto (subcadena, insensible a mayúsculas Y acentos).
    /// `activeOnly` excluye los dados de baja en SAP (para tomar órdenes NUEVAS); la
    /// pestaña Clientes los muestra igual (marcados inactivos) porque conservan órdenes.
    ///
    /// El filtro de texto se hace en memoria (no en SQL): la lista es local y de pocos
    /// cientos de filas, así que es instantáneo, y el `LIKE` de SQLite no ignora tildes
    /// —"gonzalez" debe encontrar "González". No hace falta debounce.
    func clients(matching query: String, activeOnly: Bool = false) throws -> [Client] {
        let needle = Self.fold(query)
        let all = try database.dbQueue.read { db -> [Client] in
            var request = Client.all()
            if activeOnly {
                request = request.filter(Column("active") == true)
            }
            return try request.order(Column("name")).fetchAll(db)
        }
        guard !needle.isEmpty else { return all }
        return all.filter { client in
            Self.fold(client.clientCode).contains(needle)
                || Self.fold(client.name).contains(needle)
                || Self.fold(client.city ?? "").contains(needle)
                || Self.fold(client.shippingRoute ?? "").contains(needle)
        }
    }

    /// Normaliza para comparar: sin tildes y sin distinguir mayúsculas.
    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    /// Un cliente por su código.
    func client(code: String) throws -> Client? {
        try database.dbQueue.read { db in
            try Client.fetchOne(db, key: code)
        }
    }
}
