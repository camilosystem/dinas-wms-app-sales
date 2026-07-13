import SwiftUI

/// Selector de ítems del catálogo para agregar al carrito. Búsqueda local (offline).
/// Se presenta como hoja; cada toque agrega una unidad y muestra la cantidad actual.
///
/// Todos los ítems del catálogo son ORDENABLES (los no vendibles ya vienen filtrados por
/// el middleware). Un ítem a $0 se agrega con normalidad (muestra / publicidad).
struct ItemPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: CatalogViewModel

    /// Lista de precio por defecto del cliente (se agrega con esa; el precio mostrado es de ella).
    let priceList: Int
    /// Cantidades ya en el carrito, por código de ítem (para mostrar el contador).
    let quantities: [String: Double]
    let onAdd: (Item) -> Void

    /// Unidades agregadas en esta sesión de selección (feedback inmediato).
    @State private var addedHere: [String: Double] = [:]

    init(database: AppDatabase, priceList: Int, quantities: [String: Double],
         onAdd: @escaping (Item) -> Void) {
        _viewModel = StateObject(
            wrappedValue: CatalogViewModel(repository: CatalogRepository(database: database))
        )
        self.priceList = priceList
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
                                Text("· \(MoneyFormat.string(item.price(forList: priceList)))")
                                if !item.hasPrice(forList: priceList) {
                                    // Informativo, no bloquea: $0 es ordenable (muestra/promo).
                                    Text("· $0").foregroundStyle(.orange)
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
