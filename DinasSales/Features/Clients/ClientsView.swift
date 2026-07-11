import SwiftUI

/// Lista de clientes asignados (solo los que devuelve `GET /sync/clients`).
///
/// Esqueleto: pantalla base. La lista y la selección se implementan en la iteración
/// de Clientes/Toma de orden.
struct ClientsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableViewCompat(
                title: "Clientes",
                message: "Solo se mostrarán los clientes asignados tras sincronizar.",
                systemImage: "person.2"
            )
            .navigationTitle("Clientes")
        }
    }
}
