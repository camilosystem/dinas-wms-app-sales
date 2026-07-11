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

                HStack(spacing: 24) {
                    stat("Disponible", item.available.formatted(),
                         color: item.available > 0 ? .green : .red)
                    if let price = item.price {
                        stat("Precio", MoneyFormat.string(price))
                    } else {
                        // price = null: sin precio de lista → no ordenable.
                        stat("Precio", "Sin precio", color: .red)
                    }
                }

                if let category = item.category, !category.isEmpty {
                    row("Categoría", category)
                }
                if let barcode = item.barcode, !barcode.isEmpty {
                    row("Código de barras", barcode)
                }
                if let comments = item.comments, !comments.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Comentarios").font(.caption).foregroundStyle(.secondary)
                        Text(comments)
                    }
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
}
