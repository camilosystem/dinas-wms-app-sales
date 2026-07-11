import SwiftUI

/// Vista de una orden ya confirmada o sincronizada (no editable).
struct OrderReadOnlyView: View {
    @StateObject private var viewModel: OrderCartViewModel
    let status: OrderStatus
    let orderNumber: String?

    init(order: Order, clientName: String, database: AppDatabase) {
        _viewModel = StateObject(wrappedValue: OrderCartViewModel(
            order: order,
            clientName: clientName,
            orders: OrdersRepository(database: database),
            catalog: CatalogRepository(database: database)
        ))
        self.status = order.status
        self.orderNumber = order.orderNumber
    }

    var body: some View {
        List {
            Section("Cliente") {
                Text(viewModel.clientName)
                OrderStatusBadge(status: status)
                if let number = orderNumber {
                    HStack { Text("N.º orden").foregroundStyle(.secondary); Spacer(); Text(number) }
                }
            }

            Section("Ítems") {
                ForEach(viewModel.rows) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            Text("\(row.quantity.formatted()) × \(MoneyFormat.string(row.unitPrice))"
                                 + (row.discountPct > 0 ? "  (−\(row.discountPct.formatted())%)" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(MoneyFormat.string(row.lineTotal)).font(.callout)
                    }
                }
            }

            Section {
                HStack {
                    Text("Total").font(.headline)
                    Spacer()
                    Text(MoneyFormat.string(viewModel.total)).font(.headline)
                }
            }
        }
        .navigationTitle("Orden")
        .navigationBarTitleDisplayModeInlineCompat()
        .task { viewModel.reload() }
    }
}

/// Insignia de estado de la orden.
struct OrderStatusBadge: View {
    let status: OrderStatus

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var label: String {
        switch status {
        case .draft: return "Borrador"
        case .confirmed: return "Confirmada"
        case .synced: return "Sincronizada"
        }
    }

    private var color: Color {
        switch status {
        case .draft: return .orange
        case .confirmed: return .blue
        case .synced: return .green
        }
    }
}
