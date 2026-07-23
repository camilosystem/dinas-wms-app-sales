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
                // Buscador SIEMPRE visible EN EL CUERPO (no en la barra de navegación): así el
                // banner offline lo empuja hacia abajo y nunca lo tapa. El toggle de vista va a
                // la derecha como ícono compacto, sin robarle ancho al buscador.
                HStack(spacing: 10) {
                    searchField
                    modeToggle
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

                if viewModel.clients.isEmpty {
                    emptyState
                } else {
                    switch grouping {
                    case .byClient: flatList
                    case .byCity: cityList
                    }
                }
            }
            .navigationTitle("Clientes")
            .refreshable { await sync() }
            .task { viewModel.reload() }
        }
    }

    /// Buscador explícito, siempre visible (mismo criterio que ClientPickerView).
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Código, nombre, ciudad o ruta", text: $viewModel.searchText)
                .autocorrectionDisabled()
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Toggle de vista de SOLO ÍCONO en la esquina: un botón que alterna Por Cliente ↔ Por
    /// Ciudad. El ícono cambia según el modo activo (persona / edificios), relleno y en color
    /// de acento → es obvio cuál está activo. No compite por ancho con el buscador.
    private var modeToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                grouping = (grouping == .byClient) ? .byCity : .byClient
            }
        } label: {
            Image(systemName: grouping.icon)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cambiar vista de clientes")
        .accessibilityValue(grouping.label)
    }

    private var emptyState: some View {
        ContentUnavailableViewCompat(
            title: viewModel.searchText.isEmpty ? "Sin clientes" : "Sin resultados",
            message: viewModel.searchText.isEmpty
                ? "Desliza hacia abajo para sincronizar."
                : "Ningún cliente coincide con la búsqueda.",
            systemImage: "person.2"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    /// Ícono del modo ACTIVO (relleno): persona para Por Cliente, edificios para Por Ciudad.
    var icon: String { self == .byClient ? "person.crop.circle.fill" : "building.2.fill" }
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
