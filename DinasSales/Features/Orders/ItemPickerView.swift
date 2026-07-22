import SwiftUI

/// Selector de ítems del catálogo para agregar al carrito — mismo patrón visual que el
/// Catálogo: grilla con imagen/código/nombre/disponible/precio y buscador SIEMPRE visible
/// arriba (TextField explícito, insensible a mayúsculas y acentos, igual que el de clientes).
///
/// Cada celda trae un stepper (+/-) para ajustar la cantidad y agregar SIN abrir el detalle.
/// Tocar la celda (no el stepper) abre el DETALLE como hoja encima del listado — con su propio
/// stepper y espacio reservado para promociones (futuro). El mínimo del stepper es 1: nunca se
/// agrega una línea en 0.
struct ItemPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: CatalogViewModel

    /// Lista de precio por defecto del cliente (se agrega con esa; el precio mostrado es de ella).
    let priceList: Int
    /// Cantidades ya en el carrito, por código de ítem (para el badge "en carrito").
    let quantities: [String: Double]
    let onAdd: (Item, Double) -> Void

    /// Cantidad elegida en cada celda (mínimo 1).
    @State private var qtyByItem: [String: Int] = [:]
    /// Unidades agregadas en esta sesión (feedback inmediato del badge, sin recargar el padre).
    @State private var addedHere: [String: Double] = [:]
    @State private var detailItem: Item?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 165), spacing: 12)]

    init(database: AppDatabase, priceList: Int, quantities: [String: Double],
         onAdd: @escaping (Item, Double) -> Void) {
        _viewModel = StateObject(
            wrappedValue: CatalogViewModel(repository: CatalogRepository(database: database))
        )
        self.priceList = priceList
        self.quantities = quantities
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                if viewModel.items.isEmpty {
                    ContentUnavailableViewCompat(
                        title: viewModel.searchText.isEmpty ? "Catálogo vacío" : "Sin resultados",
                        message: viewModel.searchText.isEmpty
                            ? "Sincroniza para ver el catálogo."
                            : "Ningún ítem coincide con la búsqueda.",
                        systemImage: "square.grid.2x2"
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    grid
                }
            }
            .navigationTitle("Agregar ítems")
            .navigationBarTitleDisplayModeInlineCompat()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
            .task { viewModel.reload() }
            .sheet(item: $detailItem) { item in
                ItemDetailSheet(
                    item: item,
                    priceList: priceList,
                    inCartQuantity: inCart(item),
                    onAdd: { qty in commitAdd(item, quantity: qty) }
                )
            }
            .overlay(alignment: .bottom) { toastView }
        }
    }

    /// Buscador explícito SIEMPRE visible arriba (mismo criterio que ClientPickerView).
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Buscar por código, nombre o palabra", text: $viewModel.searchText)
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

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(viewModel.items) { item in
                    ItemCell(
                        item: item,
                        priceList: priceList,
                        inCart: inCart(item),
                        quantity: Binding(
                            get: { qtyByItem[item.itemCode] ?? 1 },
                            set: { qtyByItem[item.itemCode] = $0 }
                        ),
                        onOpenDetail: { detailItem = item },
                        onAdd: { commitAdd(item, quantity: Double(qtyByItem[item.itemCode] ?? 1)) }
                    )
                }
            }
            .padding()
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Label(toast, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Unidades del ítem ya en el carrito (las que venían + las agregadas en esta sesión).
    private func inCart(_ item: Item) -> Double {
        (quantities[item.itemCode] ?? 0) + (addedHere[item.itemCode] ?? 0)
    }

    /// Agrega al carrito, actualiza el badge y muestra la confirmación (toast breve).
    private func commitAdd(_ item: Item, quantity: Double) {
        guard quantity > 0 else { return }
        addedHere[item.itemCode, default: 0] += quantity
        onAdd(item, quantity)
        showToast("Agregado ×\(Int(quantity))")
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.25)) { toast = message }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            withAnimation(.easeInOut(duration: 0.25)) { toast = nil }
        }
    }
}

/// Celda tipo catálogo con stepper: la parte superior (imagen + datos) abre el detalle;
/// la barra inferior (stepper + agregar) ajusta y agrega sin salir del listado.
private struct ItemCell: View {
    let item: Item
    let priceList: Int
    let inCart: Double
    @Binding var quantity: Int
    let onOpenDetail: () -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpenDetail) {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        RemoteImage(urlString: item.imageURL)
                            .frame(height: 110)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        if inCart > 0 {
                            Label("\(Int(inCart))", systemImage: "cart.fill")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.tint, in: Capsule())
                                .foregroundStyle(.white)
                                .padding(6)
                        }
                    }
                    Text(item.itemCode).font(.caption2).foregroundStyle(.secondary)
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Disp: \(item.available.formatted())")
                        .font(.caption)
                        .foregroundStyle(item.available > 0 ? .green : .red)
                    Text(MoneyFormat.string(item.price(forList: priceList)))
                        .font(.caption.weight(.semibold))
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                CompactStepper(value: $quantity, range: 1...9999)
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Stepper compacto `[-] N [+]` para las celdas y el detalle. Cantidad entera; se detiene en
/// los extremos del rango (mínimo 1 → nunca agrega en 0).
struct CompactStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value - 1)
            }
            Text("\(value)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 30)
            stepButton("plus", enabled: value < range.upperBound) {
                value = min(range.upperBound, value + 1)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }

    private func stepButton(_ icon: String, enabled: Bool,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
