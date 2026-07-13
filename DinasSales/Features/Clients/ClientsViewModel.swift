import Foundation

/// Estado de la pantalla de clientes. Lee de la base local (offline) vía repositorio.
@MainActor
final class ClientsViewModel: ObservableObject {
    @Published var searchText = "" { didSet { reload() } }
    @Published private(set) var clients: [Client] = []
    @Published private(set) var loadError = false

    private let repository: ClientsRepository
    /// Si `true`, solo clientes activos (para tomar órdenes NUEVAS). La pestaña Clientes
    /// usa `false`: muestra también los dados de baja que conservan órdenes.
    private let activeOnly: Bool

    init(repository: ClientsRepository, activeOnly: Bool = false) {
        self.repository = repository
        self.activeOnly = activeOnly
    }

    /// Carga (o recarga) la lista aplicando el texto de búsqueda actual.
    func reload() {
        do {
            clients = try repository.clients(matching: searchText, activeOnly: activeOnly)
            loadError = false
        } catch {
            clients = []
            loadError = true
        }
    }
}
