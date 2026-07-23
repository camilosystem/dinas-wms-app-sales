import SwiftUI

/// Lista de clientes asignados (solo los que devuelve `GET /sync/clients`).
/// Búsqueda local y detalle. Pull-to-refresh sincroniza y recarga.
struct ClientsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel: ClientsViewModel
    /// Agrupación de la lista: plana (Por Cliente) o por ciudad (Por Ciudad).
    @State private var grouping: ClientsGrouping = .byClient

    init(database: AppDatabase) {
        _viewModel = StateObject(
            wrappedValue: ClientsViewModel(repository: ClientsRepository(database: database))
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Selector DEBAJO del buscador (el buscador vive en la barra de navegación).
                // Segmented control a todo el ancho, separado con un fondo tenue para no competir.
                Picker("Vista", selection: $grouping) {
                    ForEach(ClientsGrouping.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.08))

                if viewModel.clients.isEmpty {
                    ContentUnavailableViewCompat(
                        title: viewModel.searchText.isEmpty ? "Sin clientes" : "Sin resultados",
                        message: viewModel.searchText.isEmpty
                            ? "Desliza hacia abajo para sincronizar."
                            : "Ningún cliente coincide con la búsqueda.",
                        systemImage: "person.2"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch grouping {
                    case .byClient: flatList
                    case .byCity: cityList
                    }
                }
            }
            .navigationTitle("Clientes")
            .searchable(text: $viewModel.searchText, prompt: "Código, nombre, ciudad o ruta")
            .refreshable { await sync() }
            .task { viewModel.reload() }
        }
    }

    /// Vista "Por Cliente": lista plana (idéntica a la de siempre).
    private var flatList: some View {
        List(viewModel.clients) { client in
            NavigationLink {
                ClientDetailView(client: client)
            } label: {
                ClientRowLabel(client: client)
            }
        }
    }

    /// Vista "Por Ciudad": lista agrupada con la ciudad como encabezado de sección. Al buscar,
    /// solo aparecen las secciones con clientes que coinciden (las vacías no se muestran).
    private var cityList: some View {
        List {
            ForEach(viewModel.citySections) { section in
                Section(section.city) {
                    ForEach(section.clients) { client in
                        NavigationLink {
                            ClientDetailView(client: client)
                        } label: {
                            ClientRowLabel(client: client)
                        }
                    }
                }
            }
        }
        .insetGroupedListStyleCompat()
    }

    private func sync() async {
        await environment.sync.syncDown()
        viewModel.reload()
    }
}

/// Modo de agrupación de la lista de clientes.
enum ClientsGrouping: String, CaseIterable, Identifiable {
    case byClient, byCity
    var id: String { rawValue }
    var label: String { self == .byClient ? "Por Cliente" : "Por Ciudad" }
}

/// Fila de cliente (mismo contenido en ambas vistas): nombre + badges, y código · ciudad.
private struct ClientRowLabel: View {
    let client: Client

    var body: some View {
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
