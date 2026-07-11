import Foundation

/// Estado de la pantalla de clientes. Lee de la base local (offline) vía repositorio.
@MainActor
final class ClientsViewModel: ObservableObject {
    @Published var searchText = "" { didSet { reload() } }
    @Published private(set) var clients: [Client] = []
    @Published private(set) var loadError = false

    private let repository: ClientsRepository

    init(repository: ClientsRepository) {
        self.repository = repository
    }

    /// Carga (o recarga) la lista aplicando el texto de búsqueda actual.
    func reload() {
        do {
            clients = try repository.clients(matching: searchText)
            loadError = false
        } catch {
            clients = []
            loadError = true
        }
    }
}
