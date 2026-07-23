import SwiftUI

/// Detalle de un cliente asignado.
struct ClientDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let client: Client

    /// Borrador recién iniciado desde el atajo (dispara la navegación al carrito).
    @State private var newOrder: Order?
    @State private var showNewOrder = false

    var body: some View {
        List {
            if !client.active {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Cliente dado de baja en SAP. Se conserva porque tiene órdenes en la app; no puedes tomarle pedidos nuevos.")
                            .font(.callout)
                    }
                    .foregroundStyle(.orange)
                }
            }

            Section("Cliente") {
                row("Código", client.clientCode)
                row("Nombre", client.name)
            }

            Section("Cartera") {
                CreditSummaryRows(credit: client.credit)
                NavigationLink {
                    StatementView(
                        clientCode: client.clientCode,
                        clientName: client.name,
                        api: environment.api,
                        database: environment.database,
                        isOnline: { environment.network.isOnline },
                        onUnauthorized: { environment.auth.sessionExpired() }
                    )
                } label: {
                    Label("Ver estado de cuenta", systemImage: "doc.text.magnifyingglass")
                }

                // Atajo: crea (o retoma) el borrador de ESTE cliente y va directo al carrito, sin
                // volver a buscarlo en el picker. Reutiliza el flujo normal (startOrder +
                // OrderCartView) → el aviso de cartera al confirmar se conserva igual. Los clientes
                // dados de baja no pueden tomar pedidos nuevos, así que solo se muestra si activo.
                if client.active {
                    Button {
                        newOrder = try? OrdersRepository(database: environment.database)
                            .startOrder(clientCode: client.clientCode)
                        showNewOrder = newOrder != nil
                    } label: {
                        Label("Nueva Orden", systemImage: "plus")
                    }
                }
            }

            Section("Ubicación") {
                if let address = client.address, !address.isEmpty { row("Dirección", address) }
                if let city = client.city, !city.isEmpty { row("Ciudad", city) }
                if let zip = client.zipcode, !zip.isEmpty { row("Código postal", zip) }
            }

            Section("Logística") {
                if let manager = client.managerName, !manager.isEmpty {
                    row("Encargado", manager)
                }
                if let route = client.shippingRoute, !route.isEmpty {
                    row("Ruta de reparto", route)
                }
            }
        }
        .navigationTitle(client.name)
        .navigationBarTitleDisplayModeInlineCompat()
        .navigationDestination(isPresented: $showNewOrder) {
            if let newOrder {
                OrderCartView(order: newOrder, clientName: client.name,
                              database: environment.database) {
                    showNewOrder = false   // al guardar/confirmar/descartar, vuelve al detalle
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}
