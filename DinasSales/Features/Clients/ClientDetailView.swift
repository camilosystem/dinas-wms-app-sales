import SwiftUI

/// Detalle de un cliente asignado.
struct ClientDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let client: Client

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
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}
