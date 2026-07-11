import SwiftUI

/// Catálogo: grilla (imagen, código, nombre, disponible, comentarios) y búsqueda por
/// código/nombre/palabra sobre la base local (offline). Detalle con imagen grande.
///
/// Pull-to-refresh dispara una sincronización de bajada y recarga la lista.
struct CatalogView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel: CatalogViewModel

    init(database: AppDatabase) {
        _viewModel = StateObject(
            wrappedValue: CatalogViewModel(repository: CatalogRepository(database: database))
        )
    }

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.items.isEmpty {
                    ContentUnavailableViewCompat(
                        title: viewModel.searchText.isEmpty ? "Catálogo vacío" : "Sin resultados",
                        message: viewModel.searchText.isEmpty
                            ? "Desliza hacia abajo para sincronizar."
                            : "Ningún ítem coincide con la búsqueda.",
                        systemImage: "square.grid.2x2"
                    )
                } else {
                    grid
                }
            }
            .navigationTitle("Catálogo")
            .searchable(text: $viewModel.searchText, prompt: "Código, nombre o palabra")
            .refreshable { await sync() }
            .task { viewModel.reload() }
        }
    }

    private var grid: some View {
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

    private func sync() async {
        await environment.sync.syncDown()
        viewModel.reload()
    }
}

/// Celda de la grilla: imagen, código, nombre, disponible y comentarios.
private struct CatalogCell: View {
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

            if let comments = item.comments, !comments.isEmpty {
                Text(comments)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
