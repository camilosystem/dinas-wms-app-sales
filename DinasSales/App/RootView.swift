import SwiftUI

/// Navegación raíz por pestañas: Home, Catálogo, Clientes, Órdenes.
/// La estructura de tabs es estable; cada feature se desarrolla en su propia pantalla.
struct RootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }

            CatalogView()
                .tabItem { Label("Catálogo", systemImage: "square.grid.2x2") }

            ClientsView()
                .tabItem { Label("Clientes", systemImage: "person.2") }

            OrdersView()
                .tabItem { Label("Órdenes", systemImage: "cart") }
        }
    }
}

/// Home mínimo. El dashboard completo está fuera del MVP.
struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationStack {
            ContentUnavailableViewCompat(
                title: "Dinas — Vendedores",
                message: "Sincroniza para trabajar sin conexión."
            )
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Cerrar sesión") { environment.auth.logout() }
                }
            }
        }
    }
}
