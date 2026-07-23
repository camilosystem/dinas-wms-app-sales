import SwiftUI

/// Nivel 2 del catálogo "Por Categoría": los ítems de UNA categoría en el grid de 2 columnas.
/// Es una pantalla propia con UN SOLO `LazyVGrid` (no anida con nada → sin el anti-patrón que
/// causó el congelamiento). Tiene su propio buscador, que filtra dentro de la categoría (igual
/// que "Por Producto"). El filtrado se hace en el ViewModel y se cachea; el `body` no recalcula.
struct CategoryItemsView: View {
    @StateObject private var viewModel: CatalogViewModel
    let categoryName: String

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    init(database: AppDatabase, categoryName: String, filter: CatalogCategoryFilter) {
        _viewModel = StateObject(wrappedValue: CatalogViewModel(
            repository: CatalogRepository(database: database), categoryFilter: filter))
        self.categoryName = categoryName
    }

    var body: some View {
        VStack(spacing: 0) {
            categoryHeader
            searchField
            if viewModel.items.isEmpty {
                ContentUnavailableViewCompat(
                    title: "Sin resultados",
                    message: "Ningún ítem coincide con la búsqueda en \(categoryName).",
                    systemImage: "square.grid.2x2"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(viewModel.items) { item in
                            NavigationLink {
                                ItemDetailView(item: item)
                            } label: {
                                CatalogCell(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(categoryName)
        .navigationBarTitleDisplayModeInlineCompat()
        .task { viewModel.reload() }
    }

    /// Contexto de la vista: nombre de la categoría en tamaño mediano (title3) + una pista discreta
    /// de que se puede deslizar hacia la derecha para volver. No compite con el grid (color
    /// secundario, texto pequeño) ni reemplaza el título de la barra de navegación.
    private var categoryHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(categoryName)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Label("Desliza para volver", systemImage: "chevron.left")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 6)
    }

    /// Buscador explícito, siempre visible (mismo criterio que el resto de la app).
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Buscar en \(categoryName)", text: $viewModel.searchText)
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
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
