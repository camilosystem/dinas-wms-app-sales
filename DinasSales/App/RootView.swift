import SwiftUI

/// Navegación raíz por pestañas: Home, Catálogo, Clientes, Órdenes.
/// La estructura de tabs es estable; cada feature se desarrolla en su propia pantalla.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var pendingOrders: PendingOrdersObserver

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
                .badge(pendingOrders.count)
        }
    }
}

/// Home: saludo, estado de conexión/sincronización, sincronizar y cerrar sesión.
struct HomeView: View {
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var pendingOrders: PendingOrdersObserver
    @EnvironmentObject private var auth: AuthSession

    @State private var showReauth = false

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

                // Estado persistente: modo offline / sesión expirada.
                if !network.isOnline {
                    statusBanner("Modo offline — trabajando con tus últimos datos",
                                 systemImage: "wifi.slash", color: .orange)
                }
                if auth.needsReauth {
                    reauthCallout
                }

                // Aviso persistente de pendientes: el vendedor es responsable de sincronizar.
                if pendingOrders.count > 0 {
                    pendingCallout
                }

                if let feedback = sync.feedback {
                    Text(feedback.message)
                        .font(.callout)
                        .foregroundStyle(feedback.isError ? .red : .green)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await sync.sync() }
                } label: {
                    HStack {
                        if sync.isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(sync.isSyncing ? "Sincronizando…" : "Sincronizar")
                    }
                    .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sync.isSyncing || !network.isOnline)

                Text(lastSyncText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding()
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Cerrar sesión") { auth.logout() }
                }
            }
            .sheet(isPresented: $showReauth) {
                NavigationStack { LoginView() }
            }
            // Cuando la re-autenticación online resuelve el token, cerramos la hoja.
            .onChange(of: auth.needsReauth) { needs in
                if !needs { showReauth = false }
            }
        }
    }

    /// Aviso de sesión expirada: se puede seguir trabajando offline; para sincronizar
    /// hay que reconectar la sesión.
    private var reauthCallout: some View {
        VStack(spacing: 8) {
            statusBanner("Tu sesión expiró — reconéctate para sincronizar",
                         systemImage: "person.crop.circle.badge.exclamationmark", color: .red)
            Button("Reconectar sesión") { showReauth = true }
                .buttonStyle(.bordered)
                .disabled(!network.isOnline)
        }
    }

    /// Franja de estado reutilizable.
    private func statusBanner(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
            Text(text).font(.callout.weight(.semibold)).multilineTextAlignment(.leading)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Tarjeta naranja, visible, cuando hay órdenes confirmadas sin enviar.
    private var pendingCallout: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(pendingOrders.count == 1
                 ? "Tienes 1 orden sin enviar"
                 : "Tienes \(pendingOrders.count) órdenes sin enviar")
                .font(.callout.weight(.semibold))
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Texto de la última sincronización (siempre visible; el estado offline va aparte).
    private var lastSyncText: String {
        guard let date = sync.lastSyncedAt else { return "Nunca sincronizado" }
        let relative = date.formatted(.relative(presentation: .named))
        return "Última sincronización: \(relative)"
    }

    private var saludo: String {
        if let name = auth.displayName, !name.isEmpty {
            return "Hola, \(name)"
        }
        return "Dinas — Vendedores"
    }
}
