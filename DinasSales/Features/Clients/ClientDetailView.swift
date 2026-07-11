import SwiftUI

/// Detalle de un cliente asignado.
struct ClientDetailView: View {
    let client: Client

    var body: some View {
        List {
            Section("Cliente") {
                row("Código", client.clientCode)
                row("Nombre", client.name)
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
