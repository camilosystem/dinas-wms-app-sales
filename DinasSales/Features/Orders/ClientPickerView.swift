import SwiftUI

/// Selector de cliente asignado para iniciar una orden (cliente primero).
///
/// El buscador es un `TextField` SIEMPRE visible arriba (no `.searchable`, que SwiftUI
/// colapsa/empuja bajo el nav bar). Cada fila muestra 4 datos: nombre, código, dirección y
/// ciudad. El filtro (nombre/código/ciudad/ruta, OR, insensible a mayúsculas y acentos) vive
/// en `ClientsRepository` — aquí solo cambia DÓNDE se teclea.
struct ClientPickerView: View {
    @StateObject private var viewModel: ClientsViewModel
    let onSelect: (Client) -> Void

    init(database: AppDatabase, onSelect: @escaping (Client) -> Void) {
        // Órdenes NUEVAS: solo clientes activos (los dados de baja no se pueden usar).
        _viewModel = StateObject(
            wrappedValue: ClientsViewModel(repository: ClientsRepository(database: database),
                                           activeOnly: true)
        )
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            List(viewModel.clients) { client in
                Button {
                    onSelect(client)
                } label: {
                    ClientRow(client: client)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if viewModel.clients.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "Sin clientes",
                        message: "Sincroniza para ver tus clientes asignados.",
                        systemImage: "person.2"
                    )
                }
            }
        }
        .navigationTitle("Elige cliente")
        .task { viewModel.reload() }
    }

    /// Buscador explícito, SIEMPRE visible arriba del todo (no depende del comportamiento
    /// nativo de `.searchable`). No fija mayúsculas: el filtro ya es case/acento-insensible.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Buscar por nombre, código o ciudad", text: $viewModel.searchText)
                .autocorrectionDisabled()
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// Fila del selector: los 4 datos legibles sin tocar la fila.
/// Nombre en negrita arriba; código · ciudad en una línea secundaria; dirección debajo.
private struct ClientRow: View {
    let client: Client

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(client.name).font(.body.weight(.semibold))

            HStack(spacing: 6) {
                Text(client.clientCode)
                if let city = client.city, !city.isEmpty {
                    Text("· \(city)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let address = client.address, !address.isEmpty {
                Text(address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
