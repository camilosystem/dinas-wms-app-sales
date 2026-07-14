import SwiftUI

/// Lista de clientes asignados (solo los que devuelve `GET /sync/clients`).
/// Búsqueda local y detalle. Pull-to-refresh sincroniza y recarga.
struct ClientsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel: ClientsViewModel

    init(database: AppDatabase) {
        _viewModel = StateObject(
            wrappedValue: ClientsViewModel(repository: ClientsRepository(database: database))
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.clients.isEmpty {
                    ContentUnavailableViewCompat(
                        title: viewModel.searchText.isEmpty ? "Sin clientes" : "Sin resultados",
                        message: viewModel.searchText.isEmpty
                            ? "Desliza hacia abajo para sincronizar."
                            : "Ningún cliente coincide con la búsqueda.",
                        systemImage: "person.2"
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Clientes")
            .searchable(text: $viewModel.searchText, prompt: "Código, nombre, ciudad o ruta")
            .refreshable { await sync() }
            .task { viewModel.reload() }
        }
    }

    private var list: some View {
        List(viewModel.clients) { client in
            NavigationLink {
                ClientDetailView(client: client)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(client.name).font(.body.weight(.medium))
                        if !client.active { InactiveClientBadge() }
                        // Solo se resalta lo que requiere atención (mora / excede cupo).
                        if client.credit.status != .alDia {
                            CreditStatusBadge(status: client.credit.status)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(client.clientCode)
                        if let city = client.city, !city.isEmpty {
                            Text("· \(city)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sync() async {
        await environment.sync.syncDown()
        viewModel.reload()
    }
}

/// Etiqueta "Dado de baja": cliente inactivo en SAP conservado por tener órdenes locales.
/// No se puede usar para pedidos nuevos, pero sus órdenes siguen visibles.
struct InactiveClientBadge: View {
    var body: some View {
        Text("Dado de baja")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.18))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
    }
}
