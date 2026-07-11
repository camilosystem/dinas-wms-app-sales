import SwiftUI

/// Navegación raíz por pestañas: Home, Catálogo, Clientes, Órdenes.
/// La estructura de tabs es estable; cada feature se desarrolla en su propia pantalla.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }

            CatalogView(database: environment.database)
                .tabItem { Label("Catálogo", systemImage: "square.grid.2x2") }

            ClientsView(database: environment.database)
                .tabItem { Label("Clientes", systemImage: "person.2") }

            OrdersView()
                .tabItem { Label("Órdenes", systemImage: "cart") }
        }
    }
}

/// Home: saludo, sincronización y cierre de sesión.
struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)

                Text(saludo)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)

                if let error = environment.sync.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await environment.sync.sync() }
                } label: {
                    HStack {
                        if environment.sync.isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(environment.sync.isSyncing ? "Sincronizando…" : "Sincronizar")
                    }
                    .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .disabled(environment.sync.isSyncing)

                Spacer()
            }
            .padding()
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Cerrar sesión") { environment.auth.logout() }
                }
            }
        }
    }

    private var saludo: String {
        if let name = environment.auth.displayName, !name.isEmpty {
            return "Hola, \(name)"
        }
        return "Dinas — Vendedores"
    }
}
