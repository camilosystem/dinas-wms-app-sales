import SwiftUI

/// Detalle del ítem como HOJA encima del listado de "Agregar ítems" (no reemplaza la pantalla).
/// Muestra imagen, categoría, disponible y precios de las 3 listas. El stepper (+/-) edita el
/// carrito directamente, igual que en la grilla — sin botón de confirmación aparte (el rótulo
/// "En el carrito: N" refleja el estado en vivo).
///
/// La sección "Promociones" es un ESPACIO RESERVADO (estructura lista) para las promociones
/// activables que se implementarán después — sin lógica todavía, para que ese contenido entre
/// sin rediseñar el modal.
struct ItemDetailSheet: View {
    let item: Item
    /// Listas de precio VISIBLES: [3] o [2,3] (nunca la 1). Ya filtradas por la política.
    let priceLists: [Int]
    /// Lista con la que se AGREGA (se marca "se agrega con esta").
    let addList: Int
    let inCartQuantity: Double
    /// Fija la cantidad absoluta del ítem en el carrito (0 = quitar).
    let onSetQuantity: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Cantidad en el carrito (sembrada con lo que ya había); el stepper la edita en vivo.
    @State private var quantity: Int

    init(item: Item, priceLists: [Int], addList: Int, inCartQuantity: Double,
         onSetQuantity: @escaping (Double) -> Void) {
        self.item = item
        self.priceLists = priceLists
        self.addList = addList
        self.inCartQuantity = inCartQuantity
        self.onSetQuantity = onSetQuantity
        _quantity = State(initialValue: Int(inCartQuantity))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RemoteImage(urlString: item.imageURL)
                        .frame(maxWidth: .infinity)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.title2.bold())
                        HStack(spacing: 6) {
                            Text(item.itemCode)
                            if let category = item.category, !category.isEmpty {
                                Text("· \(category)")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    if quantity > 0 {
                        Label("En el carrito: \(quantity)", systemImage: "cart.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                    }

                    stat("Disponible", item.available.formatted(),
                         color: item.available > 0 ? .green : .red)

                    pricesBlock
                    promotionsPlaceholder
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) { addBar }
            .navigationTitle(item.itemCode)
            .navigationBarTitleDisplayModeInlineCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }

    /// Solo las listas VISIBLES (L3 siempre; L2 si autorizada). Marca la de agregado. Nunca L1.
    private var pricesBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(priceLists.count > 1 ? "Precios" : "Precio")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(priceLists, id: \.self) { list in
                priceRow(list, item.price(forList: list))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func priceRow(_ list: Int, _ price: Double) -> some View {
        HStack {
            Text("Lista \(list)").foregroundStyle(.secondary)
            if list == addList {
                Text("se agrega con esta").font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
            }
            Spacer()
            Text(MoneyFormat.string(price))
            if price == 0 {
                Text("· $0").font(.caption2).foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
    }

    /// ▸ Espacio reservado para PROMOCIONES activables (futuro). Estructura lista; sin lógica.
    private var promotionsPlaceholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Promociones", systemImage: "tag")
                .font(.caption).foregroundStyle(.secondary)
            Text("Próximamente: promociones activables para este ítem.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Barra inferior fija: el stepper edita el carrito directamente (sin botón de confirmación,
    /// igual que la grilla). El rótulo de arriba refleja el total en vivo.
    private var addBar: some View {
        HStack {
            Text(quantity > 0 ? "En el carrito" : "Agregar al carrito")
                .font(.headline)
            Spacer()
            CompactStepper(
                value: quantity,
                onDecrement: {
                    quantity = max(0, quantity - 1)
                    onSetQuantity(Double(quantity))
                },
                onIncrement: {
                    quantity += 1
                    onSetQuantity(Double(quantity))
                }
            )
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func stat(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).foregroundStyle(color)
        }
    }
}
