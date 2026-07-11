import SwiftUI

/// Catálogo: grilla (imagen, código, nombre, disponible, comentarios) y búsqueda por
/// código/nombre/palabra sobre la base local (offline). Detalle con imagen grande.
///
/// Esqueleto: pantalla base. La grilla, la búsqueda local y el detalle se implementan
/// en la iteración de Catálogo.
struct CatalogView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableViewCompat(
                title: "Catálogo",
                message: "Grilla y búsqueda local llegan en la siguiente iteración.",
                systemImage: "square.grid.2x2"
            )
            .navigationTitle("Catálogo")
        }
    }
}
