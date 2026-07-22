import SwiftUI

/// Selector de ítems del catálogo para agregar al carrito — mismo patrón visual que el
/// Catálogo: grilla con imagen/código/nombre/disponible/precio y buscador SIEMPRE visible
/// arriba (TextField explícito, insensible a mayúsculas y acentos, igual que el de clientes).
///
/// El stepper (+/-) de cada celda EDITA el carrito directamente: `+` incrementa la línea, `-`
/// decrementa y en 0 la quita — sin botón de confirmación aparte. Tocar la celda (no el stepper)
/// abre el DETALLE como hoja encima del listado. Confirmación visual: badge "en carrito" en la
/// celda + toast breve al incrementar.
struct ItemPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: CatalogViewModel

    /// Lista de precio por defecto del cliente (se agrega con esa; el precio mostrado es de ella).
    let priceList: Int
    /// Cantidad absoluta del ítem en el carrito, por código (para el stepper y el badge).
    let onSetQuantity: (Item, Double) -> Void

    /// Cantidad en el carrito por ítem — fuente de verdad local del picker (sembrada con lo que
    /// ya había en el carrito). Cada +/- la actualiza y la persiste vía `onSetQuantity`.
    @State private var cartQty: [String: Double]
    @State private var detailItem: Item?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 165), spacing: 12)]

    init(database: AppDatabase, priceList: Int, quantities: [String: Double],
         onSetQuantity: @escaping (Item, Double) -> Void) {
        _viewModel = StateObject(
            wrappedValue: CatalogViewModel(repository: CatalogRepository(database: database))
        )
        self.priceList = priceList
        self.onSetQuantity = onSetQuantity
        _cartQty = State(initialValue: quantities)
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
                    inCartQuantity: qty(item),
                    onSetQuantity: { newQty in setQty(item, to: newQty) }
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
                        inCart: qty(item),
                        onOpenDetail: { detailItem = item },
                        onIncrement: { setQty(item, to: qty(item) + 1) },
                        onDecrement: { setQty(item, to: qty(item) - 1) }
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

    /// Cantidad del ítem en el carrito (según la fuente de verdad local).
    private func qty(_ item: Item) -> Double { cartQty[item.itemCode] ?? 0 }

    /// Fija la cantidad del ítem en el carrito, persiste el cambio y da la confirmación visual:
    /// toast breve solo al INCREMENTAR (el badge de la celda refleja el total en todo momento).
    private func setQty(_ item: Item, to newQuantity: Double) {
        let previous = qty(item)
        let clamped = max(0, newQuantity)
        guard clamped != previous else { return }
        cartQty[item.itemCode] = clamped
        onSetQuantity(item, clamped)
        if clamped > previous { showToast("Agregado ×\(Int(clamped))") }
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

/// Celda tipo catálogo: la parte superior (imagen + datos) abre el detalle; el stepper de abajo
/// edita el carrito directamente (+/-), sin botón de confirmación aparte.
private struct ItemCell: View {
    let item: Item
    let priceList: Int
    let inCart: Double
    let onOpenDetail: () -> Void
    let onIncrement: () -> Void
    let onDecrement: () -> Void

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

            CompactStepper(value: Int(inCart), fillWidth: true,
                           onDecrement: onDecrement, onIncrement: onIncrement)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Stepper compacto `[-] N [+]`. Edita una cantidad que vive fuera (cada toque dispara un
/// callback); se detiene en 0 (deshabilita "-"). `fillWidth` estira el número al ancho disponible.
struct CompactStepper: View {
    let value: Int
    var fillWidth: Bool = false
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: value > 0, onDecrement)
            Text("\(value)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 30, maxWidth: fillWidth ? .infinity : nil)
            stepButton("plus", enabled: true, onIncrement)
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
