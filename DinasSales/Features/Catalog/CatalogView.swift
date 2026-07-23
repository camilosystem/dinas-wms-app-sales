import SwiftUI

/// Catálogo: grilla (imagen, código, nombre, disponible, comentarios) y búsqueda por
/// código/nombre/palabra sobre la base local (offline). Detalle con imagen grande.
///
/// Pull-to-refresh dispara una sincronización de bajada y recarga la lista.
struct CatalogView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel: CatalogViewModel

    /// Agrupación de la grilla: por producto (grid plano) o por categoría (grid en secciones).
    @State private var grouping: CatalogGrouping = .byProduct

    init(database: AppDatabase) {
        _viewModel = StateObject(
            wrappedValue: CatalogViewModel(repository: CatalogRepository(database: database))
        )
    }

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Buscador SIEMPRE visible EN EL CUERPO (no en la barra de navegación): el banner
                // offline lo empuja hacia abajo y nunca lo tapa. Toggle de vista a la derecha.
                HStack(spacing: 10) {
                    searchField
                    ViewModeIconToggle(systemImage: grouping.icon, modeName: grouping.label) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            grouping = (grouping == .byProduct) ? .byCategory : .byProduct
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

                if viewModel.items.isEmpty {
                    emptyState
                } else {
                    switch grouping {
                    case .byProduct:
                        productGrid
                    case .byCategory:
                        // Nivel 1: lista de categorías. Al buscar, se APLANA a los ítems que
                        // hacen match cruzando categorías (buscar un producto no exige su categoría).
                        if viewModel.searchText.isEmpty { categoryList } else { productGrid }
                    }
                }
            }
            .navigationTitle("Catálogo")
            .refreshable { await sync() }
            .task { viewModel.reload() }
        }
    }

    /// Buscador explícito, siempre visible (mismo criterio que Clientes / ClientPickerView).
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Código, nombre o palabra", text: $viewModel.searchText)
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

    private var emptyState: some View {
        ContentUnavailableViewCompat(
            title: viewModel.searchText.isEmpty ? "Catálogo vacío" : "Sin resultados",
            message: viewModel.searchText.isEmpty
                ? "Desliza hacia abajo para sincronizar."
                : "Ningún ítem coincide con la búsqueda.",
            systemImage: "square.grid.2x2"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Vista "Por Producto": grid plano (idéntico al de siempre).
    private var productGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(viewModel.items) { item in
                    cell(item)
                }
            }
            .padding()
        }
    }

    /// Nivel 1 de "Por Categoría": una LISTA simple (no grid) de categorías. Muy liviana (~30
    /// filas) → sin riesgo de congelamiento. Cada fila muestra la categoría y su conteo, y navega
    /// al nivel 2 (grid de esa categoría). Alfabético; "Sin categoría" al final (ya viene así de
    /// `categorySections`).
    private var categoryList: some View {
        List(viewModel.categorySections) { section in
            NavigationLink {
                CategoryItemsView(
                    database: environment.database,
                    categoryName: section.category,
                    filter: section.isNoCategory ? .uncategorized : .named(section.category)
                )
            } label: {
                HStack {
                    Text(section.category)
                    Spacer()
                    Text("\(section.items.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func cell(_ item: Item) -> some View {
        NavigationLink {
            ItemDetailView(item: item)
        } label: {
            CatalogCell(item: item)
        }
        .buttonStyle(.plain)
    }

    private func sync() async {
        await environment.sync.syncDown()
        viewModel.reload()
    }
}

/// Modo de agrupación del catálogo.
enum CatalogGrouping: String, CaseIterable, Identifiable {
    case byProduct, byCategory
    var id: String { rawValue }
    var label: String { self == .byProduct ? "Por Producto" : "Por Categoría" }
    /// Ícono del modo ACTIVO (relleno): cuadrícula para Por Producto, etiqueta para Por Categoría.
    var icon: String { self == .byProduct ? "square.grid.2x2.fill" : "tag.fill" }
}

/// Celda de la grilla: imagen, código, nombre, disponible y precio (Lista 3). Reutilizable en el
/// grid plano (nivel 1 / Por Producto) y en el grid de una categoría (nivel 2).
struct CatalogCell: View {
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(urlString: item.imageURL)
                .frame(height: 120)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(item.itemCode)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(item.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            Text("Disp: \(item.available.formatted())")
                .font(.caption)
                .foregroundStyle(item.available > 0 ? .green : .red)

            // Catálogo general (sin cliente): SOLO Lista 3 (nunca Lista 1 ni Lista 2).
            Text("Lista 3: \(MoneyFormat.string(item.priceList3))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
