import SwiftUI

/// Selector de cliente asignado para iniciar una orden (cliente primero).
struct ClientPickerView: View {
    @StateObject private var viewModel: ClientsViewModel
    let onSelect: (Client) -> Void

    init(database: AppDatabase, onSelect: @escaping (Client) -> Void) {
        _viewModel = StateObject(
            wrappedValue: ClientsViewModel(repository: ClientsRepository(database: database))
        )
        self.onSelect = onSelect
    }

    var body: some View {
        List(viewModel.clients) { client in
            Button {
                onSelect(client)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.name).font(.body.weight(.medium))
                    Text(client.clientCode).font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Elige cliente")
        .searchable(text: $viewModel.searchText, prompt: "Buscar cliente")
        .task { viewModel.reload() }
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
}
