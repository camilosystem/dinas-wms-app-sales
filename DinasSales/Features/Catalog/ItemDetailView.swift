import SwiftUI

/// Detalle de un ítem con imagen grande y datos del catálogo.
struct ItemDetailView: View {
    let item: Item

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RemoteImage(urlString: item.imageURL)
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.title2.bold())
                    Text(item.itemCode).font(.subheadline).foregroundStyle(.secondary)
                }

                stat("Disponible", item.available.formatted(),
                     color: item.available > 0 ? .green : .red)

                // Catálogo general (sin cliente): SOLO Lista 3 (nunca Lista 1 ni Lista 2).
                VStack(alignment: .leading, spacing: 4) {
                    Text("Precio").font(.caption).foregroundStyle(.secondary)
                    priceRow("Lista 3", item.priceList3)
                }

                if let category = item.category, !category.isEmpty {
                    row("Categoría", category)
                }
                if let barcode = item.barcode, !barcode.isEmpty {
                    row("Código de barras", barcode)
                }
            }
            .padding()
        }
        .navigationTitle(item.itemCode)
        .navigationBarTitleDisplayModeInlineCompat()
    }

    private func stat(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).foregroundStyle(color)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }

    private func priceRow(_ title: String, _ price: Double) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(MoneyFormat.string(price))
            if price == 0 {
                Text("(sin precio)").font(.caption2).foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
    }
}

