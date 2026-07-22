import Foundation
import GRDB

/// Consultas de catálogo sobre la base local (offline).
///
/// Toda la búsqueda del vendedor pasa por aquí; no llega a la red. Solo devuelve ítems
/// `active` (regla del contrato: los inactivos no se muestran ni se pueden ordenar).
struct CatalogRepository {
    let database: AppDatabase

    /// Ítems activos ordenados por nombre. Si `query` no está vacío, filtra por código,
    /// nombre, categoría o código de barras (subcadena, insensible a mayúsculas Y acentos —
    /// mismo criterio que el buscador de clientes, por consistencia).
    ///
    /// El filtro de texto se hace en memoria (no en SQL): el catálogo es local y el `LIKE`
    /// de SQLite no ignora tildes. Recorrer unos miles de ítems por tecla es instantáneo.
    func items(matching query: String) throws -> [Item] {
        let needle = Self.fold(query)
        let all = try database.dbQueue.read { db in
            try Item.filter(Column("active") == true).order(Column("name")).fetchAll(db)
        }
        guard !needle.isEmpty else { return all }
        return all.filter { item in
            Self.fold(item.itemCode).contains(needle)
                || Self.fold(item.name).contains(needle)
                || Self.fold(item.category ?? "").contains(needle)
                || Self.fold(item.barcode ?? "").contains(needle)
        }
    }

    /// Un ítem por su código (para el detalle).
    func item(code: String) throws -> Item? {
        try database.dbQueue.read { db in
            try Item.fetchOne(db, key: code)
        }
    }

    /// Normaliza para comparar: sin tildes y sin distinguir mayúsculas.
    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}
