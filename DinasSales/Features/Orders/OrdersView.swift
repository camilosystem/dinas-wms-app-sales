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
                // Descartar: borradores y vencidos (acción explícita). Las confirmadas
                // recientes y las sincronizadas NO se descartan desde aquí.
                .swipeActions(edge: .trailing) {
                    if summary.order.status == .draft || summary.isOverdue {
                        Button(role: .destructive) {
                            orderToDiscard = summary
                        } label: {
                            Label("Descartar", systemImage: "trash")
                        }
                    }
                }
                // Enviar un vencido "igual": viaja con su taken_at real.
                .swipeActions(edge: .leading) {
                    if summary.isOverdue {
                        Button { sendOverdue(summary) } label: {
                            Label("Enviar", systemImage: "paperplane")
                        }
                        .tint(.blue)
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
        } message: { summary in
            Text(summary.isOverdue
                 ? "Se eliminará este pedido vencido y no se enviará. Esta acción no se puede deshacer."
                 : "Se eliminará la orden y sus líneas. Esta acción no se puede deshacer.")
        }
    }

    private var discardTitle: String {
        (orderToDiscard?.isOverdue ?? false) ? "¿Descartar este pedido vencido?" : "¿Descartar este borrador?"
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
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                OrderStatusBadge(status: summary.order.status)
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
