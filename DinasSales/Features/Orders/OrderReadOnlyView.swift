import SwiftUI

/// Vista de una orden ya confirmada o sincronizada (no editable).
struct OrderReadOnlyView: View {
    @StateObject private var viewModel: OrderCartViewModel
    let status: OrderStatus
    let orderNumber: String?

    init(order: Order, clientName: String, database: AppDatabase) {
        let client = try? ClientsRepository(database: database).client(code: order.clientCode)
        _viewModel = StateObject(wrappedValue: OrderCartViewModel(
            order: order,
            clientName: clientName,
            authorizedPriceLists: client?.authorizedPriceLists ?? [],
            defaultPriceList: client?.defaultPriceList ?? 1,
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
                OrderStatusBadge(status: status, creditVerdict: viewModel.order.creditVerdict)
                if let number = orderNumber {
                    HStack { Text("N.º orden").foregroundStyle(.secondary); Spacer(); Text(number) }
                }
            }

            // Retenida por cartera: espera aprobación del admin. Se muestra el motivo.
            if viewModel.order.creditVerdict == .retenidaCartera {
                Section("Retenida para aprobación de cartera") {
                    Text(viewModel.order.holdReason?.label ?? "Requiere aprobación de la oficina.")
                        .foregroundStyle(.orange)
                    Text("El pedido se envió y espera la decisión de la oficina.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Rechazada por la oficina (★ v0.4.1): motivo para explicárselo al cliente.
            if viewModel.order.creditVerdict == .rechazada {
                Section("Orden rechazada") {
                    Text(viewModel.order.decisionNote ?? "La oficina rechazó la orden.")
                        .foregroundStyle(.red)
                    decidedAtFootnote
                }
            }

            // Aprobada por la oficina: si dejó una nota, se muestra.
            if viewModel.order.creditVerdict == .aprobada,
               let note = viewModel.order.decisionNote, !note.isEmpty {
                Section("Aprobada por la oficina") {
                    Text(note)
                    decidedAtFootnote
                }
            }

            // Rechazo por error PERMANENTE de envío (400/404), distinto de la decisión de cartera.
            if status == .rejected, let reason = viewModel.order.rejectionReason {
                Section("Motivo del rechazo") {
                    Text(reason).foregroundStyle(.red)
                }
            }

            // ★ v0.11.0 — Resultado de la ENTREGA. Solo cuando hay estado terminal
            // (entregado/parcial/no entregado); `nil` y `.pendiente` no muestran nada.
            if let delivery = viewModel.order.deliveryStatus, delivery.isResult {
                Section("Entrega") {
                    Label(delivery.label, systemImage: delivery.icon)
                        .foregroundStyle(delivery.color)
                    // Motivo YA formateado por el middleware: se muestra tal cual.
                    if let reason = viewModel.order.deliveryReason, !reason.isEmpty {
                        Text(reason)
                    }
                    if let at = viewModel.order.deliveredAt {
                        Text("Registrada el \(at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Ítems") {
                ForEach(viewModel.rows) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            Text("\(row.quantity.formatted()) × \(MoneyFormat.string(row.unitPrice))"
                                 + " · Lista \(row.priceList)"
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

    /// "Decidida el …" con la fecha de la decisión del admin, si hay.
    @ViewBuilder
    private var decidedAtFootnote: some View {
        if let at = viewModel.order.decidedAt {
            Text("Decidida el \(at.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Presentación del resultado de entrega (mismo estilo visual que el veredicto de cartera:
/// color + label; el motivo lo trae el servidor ya redactado).
extension DeliveryStatus {
    var label: String {
        switch self {
        case .pendiente: return "Pendiente de entrega"
        case .entregado: return "Entregado"
        case .entregadoParcial: return "Entrega parcial"
        case .noEntregado: return "No entregado"
        }
    }

    var color: Color {
        switch self {
        case .pendiente: return .secondary
        case .entregado: return .green
        case .entregadoParcial: return .orange
        case .noEntregado: return .red
        }
    }

    var icon: String {
        switch self {
        case .pendiente: return "clock"
        case .entregado: return "checkmark.circle.fill"
        case .entregadoParcial: return "exclamationmark.triangle.fill"
        case .noEntregado: return "xmark.circle.fill"
        }
    }
}

/// Presentación del veredicto de cartera del servidor (colores/labels viven en la vista).
extension CreditVerdict {
    var label: String {
        switch self {
        case .sincronizada: return "Sincronizada"
        case .retenidaCartera: return "Retenida"
        case .aprobada: return "Aprobada"
        case .rechazada: return "Rechazada"
        }
    }

    var color: Color {
        switch self {
        case .sincronizada: return .blue
        case .retenidaCartera: return .orange   // ámbar: espera aprobación
        case .aprobada: return .green
        case .rechazada: return .red
        }
    }
}

/// Insignia de estado de la orden. Si el middleware ya emitió un VEREDICTO DE CARTERA
/// (orden `.synced` con `creditVerdict`), muestra ese veredicto — es lo que el vendedor
/// necesita para responderle al cliente. Si no, muestra el estado local de envío.
struct OrderStatusBadge: View {
    let status: OrderStatus
    var creditVerdict: CreditVerdict? = nil

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var label: String {
        if status == .synced, let verdict = creditVerdict { return verdict.label }
        switch status {
        case .draft: return "Borrador"
        case .confirmed: return "Confirmada"
        case .synced: return "Sincronizada"
        case .rejected: return "Rechazada"
        }
    }

    private var color: Color {
        if status == .synced, let verdict = creditVerdict { return verdict.color }
        switch status {
        case .draft: return .orange
        case .confirmed: return .blue
        case .synced: return .green
        case .rejected: return .red
        }
    }
}
