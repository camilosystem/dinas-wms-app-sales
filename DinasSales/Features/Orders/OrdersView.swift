import SwiftUI

/// Pestaña de Órdenes: lista de órdenes (borrador/confirmada/sincronizada) y creación
/// de una orden nueva (cliente primero → carrito).
struct OrdersView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var summaries: [OrderSummary] = []
    @State private var path: [OrderRoute] = []
    @State private var showClientPicker = false
    @State private var loadError = false

    private var ordersRepo: OrdersRepository { OrdersRepository(database: environment.database) }
    private var clientsRepo: ClientsRepository { ClientsRepository(database: environment.database) }

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
                    list
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

    private var list: some View {
        List(summaries) { summary in
            NavigationLink(value: route(for: summary.order)) {
                OrderRow(summary: summary)
            }
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
            OrderStatusBadge(status: summary.order.status)
        }
    }
}
