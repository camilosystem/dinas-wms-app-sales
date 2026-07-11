import SwiftUI

/// Selector de ítems del catálogo para agregar al carrito. Búsqueda local (offline).
/// Se presenta como hoja; cada toque agrega una unidad y muestra la cantidad actual.
struct ItemPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: CatalogViewModel

    /// Cantidades ya en el carrito, por código de ítem (para mostrar el contador).
    let quantities: [String: Double]
    let onAdd: (Item) -> Void

    /// Unidades agregadas en esta sesión de selección (feedback inmediato).
    @State private var addedHere: [String: Double] = [:]

    init(database: AppDatabase, quantities: [String: Double], onAdd: @escaping (Item) -> Void) {
        _viewModel = StateObject(
            wrappedValue: CatalogViewModel(repository: CatalogRepository(database: database))
        )
        self.quantities = quantities
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            List(viewModel.items) { item in
                Button {
                    addedHere[item.itemCode, default: 0] += 1
                    onAdd(item)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.body.weight(.medium))
                            HStack(spacing: 6) {
                                Text(item.itemCode)
                                if let price = item.price {
                                    Text("· \(MoneyFormat.string(price))")
                                }
                                Text("· Disp \(item.available.formatted())")
                                    .foregroundStyle(item.available > 0 ? .green : .red)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        let qty = (quantities[item.itemCode] ?? 0) + (addedHere[item.itemCode] ?? 0)
                        if qty > 0 {
                            Text("×\(qty.formatted())")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Agregar ítems")
            .searchable(text: $viewModel.searchText, prompt: "Código, nombre o palabra")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
            .task { viewModel.reload() }
        }
    }
}
