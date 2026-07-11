import Foundation
import GRDB

/// Consultas de catálogo sobre la base local (offline).
///
/// Toda la búsqueda del vendedor pasa por aquí; no llega a la red. Solo devuelve ítems
/// `active` (regla del contrato: los inactivos no se muestran ni se pueden ordenar).
struct CatalogRepository {
    let database: AppDatabase

    /// Ítems activos ordenados por nombre. Si `query` no está vacío, filtra por
    /// código, nombre, categoría, código de barras o comentarios (subcadena, sin
    /// distinguir mayúsculas).
    func items(matching query: String) throws -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try database.dbQueue.read { db in
            var request = Item.filter(Column("active") == true)

            if !trimmed.isEmpty {
                let pattern = "%\(escapeLike(trimmed))%"
                let esc: SQLExpressible = "\\"
                request = request.filter(
                    Column("item_code").like(pattern, escape: esc)
                    || Column("name").like(pattern, escape: esc)
                    || Column("category").like(pattern, escape: esc)
                    || Column("barcode").like(pattern, escape: esc)
                    || Column("comments").like(pattern, escape: esc)
                )
            }

            return try request.order(Column("name")).fetchAll(db)
        }
    }

    /// Un ítem por su código (para el detalle).
    func item(code: String) throws -> Item? {
        try database.dbQueue.read { db in
            try Item.fetchOne(db, key: code)
        }
    }

    /// Escapa los comodines de LIKE para que el texto del usuario se trate como literal.
    /// Debe acompañarse de `ESCAPE '\'`, que GRDB añade al usar `like(_:escape:)`.
    private func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
