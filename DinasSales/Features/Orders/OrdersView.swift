import SwiftUI

/// Pestaña de Órdenes: lista de órdenes (borrador/confirmada/sincronizada) y creación
/// de una orden nueva (cliente primero → carrito).
struct OrdersView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var summaries: [OrderSummary] = []
    @State private var path: [OrderRoute] = []
    @State private var showClientPicker = false
    @State private var loadError = false
    @State private var orderToDiscard: OrderSummary?

    private var ordersRepo: OrdersRepository { OrdersRepository(database: environment.database) }
    private var clientsRepo: ClientsRepository { ClientsRepository(database: environment.database) }

    private var overdueCount: Int { summaries.filter(\.isOverdue).count }
    private var rejectedCount: Int { summaries.filter { $0.order.status == .rejected }.count }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if summaries.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "Sin órdenes",
                        message: "Crea una orden nueva con el botón +.",
                        systemImage: "cart"
                    )
                } else {
                    VStack(spacing: 0) {
                        if rejectedCount > 0 { rejectedBanner }
                        if overdueCount > 0 { overdueBanner }
                        list
                    }
                }
            }
            .navigationTitle("Órdenes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showClientPicker = true
                    } label: {
                        Label("Nueva orden", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: OrderRoute.self) { route in
                destination(for: route)
            }
            .sheet(isPresented: $showClientPicker) {
                NavigationStack {
                    ClientPickerView(database: environment.database) { client in
                        startOrder(for: client)
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancelar") { showClientPicker = false }
                        }
                    }
                }
            }
            .onAppear(perform: reload)
        }
    }

    /// Aviso: órdenes rechazadas por el servidor. Requieren atención (corregir/descartar).
    private var rejectedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
            Text(rejectedCount == 1
                 ? "1 orden rechazada — requiere atención"
                 : "\(rejectedCount) órdenes rechazadas — requieren atención")
                .font(.callout.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(.red)
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.red.opacity(0.12))
    }

    /// Aviso rojo: hay pedidos vencidos (>7 días sin enviar). El vendedor decide qué hacer.
    private var overdueBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
            Text(overdueCount == 1
                 ? "Tienes 1 pedido vencido (más de 7 días sin enviar)"
                 : "Tienes \(overdueCount) pedidos vencidos (más de 7 días sin enviar)")
                .font(.callout.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(.red)
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.red.opacity(0.1))
    }

    private var list: some View {
        List {
            ForEach(summaries) { summary in
                NavigationLink(value: route(for: summary.order)) {
                    OrderRow(summary: summary)
                }
                // Descartar: borradores, vencidos y RECHAZADAS (acción explícita). Las
                // confirmadas recientes y las sincronizadas NO se descartan desde aquí.
                .swipeActions(edge: .trailing) {
                    if summary.order.status == .draft || summary.isOverdue
                        || summary.order.status == .rejected {
                        Button(role: .destructive) {
                            orderToDiscard = summary
                        } label: {
                            Label("Descartar", systemImage: "trash")
                        }
                    }
                }
                .swipeActions(edge: .leading) {
                    // Enviar un vencido "igual": viaja con su taken_at real.
                    if summary.isOverdue {
                        Button { sendOverdue(summary) } label: {
                            Label("Enviar", systemImage: "paperplane")
                        }
                        .tint(.blue)
                    }
                    // Corregir una rechazada: vuelve a borrador para editarla.
                    if summary.order.status == .rejected {
                        Button { correct(summary) } label: {
                            Label("Corregir", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                }
            }
        }
        .confirmationDialog(
            discardTitle,
            isPresented: Binding(get: { orderToDiscard != nil },
                                 set: { if !$0 { orderToDiscard = nil } }),
            titleVisibility: .visible,
            presenting: orderToDiscard
        ) { summary in
            Button("Descartar", role: .destructive) { discard(summary) }
            Button("Cancelar", role: .cancel) { orderToDiscard = nil }
        } message: { _ in
            Text("Se eliminará la orden y sus líneas. Esta acción no se puede deshacer.")
        }
    }

    private var discardTitle: String {
        switch orderToDiscard?.order.status {
        case .rejected: return "¿Descartar esta orden rechazada?"
        default: return (orderToDiscard?.isOverdue ?? false)
            ? "¿Descartar este pedido vencido?" : "¿Descartar este borrador?"
        }
    }

    // MARK: - Navegación

    @ViewBuilder
    private func destination(for route: OrderRoute) -> some View {
        if let order = try? ordersRepo.order(uuid: route.clientUUID) {
            let name = (try? clientsRepo.client(code: order.clientCode)?.name) ?? order.clientCode
            switch route {
            case .cart:
                OrderCartView(order: order, clientName: name,
                              database: environment.database) {
                    path.removeAll()
                    reload()
                }
            case .readOnly:
                OrderReadOnlyView(order: order, clientName: name,
                                  database: environment.database)
            }
        } else {
            Text("Orden no encontrada.")
        }
    }

    private func route(for order: Order) -> OrderRoute {
        order.status == .draft ? .cart(order.clientUUID) : .readOnly(order.clientUUID)
    }

    private func startOrder(for client: Client) {
        do {
            let order = try ordersRepo.startOrder(clientCode: client.clientCode)
            showClientPicker = false
            path = [.cart(order.clientUUID)]
        } catch {
            loadError = true
            showClientPicker = false
        }
    }

    /// Corregir una rechazada: la reabre como borrador y la abre en el carrito.
    private func correct(_ summary: OrderSummary) {
        do {
            try ordersRepo.reopenRejected(orderUUID: summary.order.clientUUID)
            reload()
            path = [.cart(summary.order.clientUUID)]
        } catch {
            loadError = true
        }
    }

    /// Descarte EXPLÍCITO (borrador o vencido). Nunca automático.
    private func discard(_ summary: OrderSummary) {
        do {
            try ordersRepo.discardOrder(orderUUID: summary.order.clientUUID)
        } catch {
            loadError = true
        }
        orderToDiscard = nil
        reload()
    }

    /// Envía un vencido "igual" (con su taken_at real). La decisión de qué hacer con un
    /// pedido viejo se toma del lado del servidor.
    private func sendOverdue(_ summary: OrderSummary) {
        Task {
            await environment.sync.pushOrder(summary.order)
            reload()
        }
    }

    private func reload() {
        do {
            summaries = try ordersRepo.summaries()
            loadError = false
        } catch {
            summaries = []
            loadError = true
        }
    }
}

/// Ruta de navegación de órdenes (Hashable para NavigationStack).
enum OrderRoute: Hashable {
    case cart(String)       // editar borrador
    case readOnly(String)   // ver confirmada/sincronizada

    var clientUUID: String {
        switch self {
        case .cart(let id), .readOnly(let id): return id
        }
    }
}

/// Fila de la lista de órdenes.
private struct OrderRow: View {
    let summary: OrderSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.clientName).font(.body.weight(.medium))
                Text("\(summary.itemCount) ítem(s) · \(MoneyFormat.string(summary.total))")
                    .font(.caption).foregroundStyle(.secondary)
                if summary.order.status == .rejected, let reason = summary.order.rejectionReason {
                    Text(reason)
                        .font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
                // Retenida por cartera: el vendedor debe saber que espera aprobación.
                if summary.order.creditVerdict == .retenidaCartera {
                    Text("Esperando aprobación de cartera"
                         + (summary.order.holdReason.map { " · \($0.label)" } ?? ""))
                        .font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
                // Rechazada por la oficina: se muestra el motivo (para explicárselo al cliente).
                if summary.order.creditVerdict == .rechazada {
                    Text(summary.order.decisionNote ?? "Rechazada por la oficina")
                        .font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
                // ★ v0.11.0 — Resultado de la entrega de un vistazo (solo estados terminales).
                if let delivery = summary.order.deliveryStatus, delivery.isResult {
                    Label(delivery.label, systemImage: delivery.icon)
                        .font(.caption2).foregroundStyle(delivery.color).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                OrderStatusBadge(status: summary.order.status,
                                 creditVerdict: summary.order.creditVerdict)
                if summary.isOverdue {
                    Text("Vencido")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red.opacity(0.15))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                }
            }
        }
    }
}
