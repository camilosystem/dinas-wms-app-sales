import SwiftUI

/// Detalle del ítem como HOJA encima del listado de "Agregar ítems" (no reemplaza la pantalla).
/// Muestra imagen, categoría, disponible y precios de las 3 listas, y permite agregar al carrito
/// con su propio stepper sin cerrar el modal.
///
/// La sección "Promociones" es un ESPACIO RESERVADO (estructura lista) para las promociones
/// activables que se implementarán después — sin lógica todavía, para que ese contenido entre
/// sin rediseñar el modal.
struct ItemDetailSheet: View {
    let item: Item
    /// Lista de precio del cliente (se marca como "del cliente" y es con la que se agrega).
    let priceList: Int
    let inCartQuantity: Double
    let onAdd: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quantity: Int = 1

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

                    if inCartQuantity > 0 {
                        Label("En el carrito: \(Int(inCartQuantity))", systemImage: "cart.fill")
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

    /// Precios de las 3 listas; marca la lista del cliente. $0 es válido y ordenable (muestra/promo).
    private var pricesBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Precios").font(.caption).foregroundStyle(.secondary)
            priceRow(1, item.priceList1)
            priceRow(2, item.priceList2)
            priceRow(3, item.priceList3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func priceRow(_ list: Int, _ price: Double) -> some View {
        HStack {
            Text("Lista \(list)").foregroundStyle(.secondary)
            if list == priceList {
                Text("del cliente").font(.caption2)
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

    /// Barra inferior fija: stepper + agregar (sin obligar a cerrar el modal).
    private var addBar: some View {
        HStack(spacing: 12) {
            CompactStepper(value: $quantity, range: 1...9999)
            Button {
                onAdd(Double(quantity))
                dismiss()
            } label: {
                Label("Agregar \(quantity)", systemImage: "cart.badge.plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
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
