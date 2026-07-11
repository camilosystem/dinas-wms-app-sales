import Foundation

/// Estado de la pantalla de catálogo. Lee de la base local (offline) vía repositorio.
@MainActor
final class CatalogViewModel: ObservableObject {
    @Published var searchText = "" { didSet { reload() } }
    @Published private(set) var items: [Item] = []
    @Published private(set) var loadError = false

    private let repository: CatalogRepository

    init(repository: CatalogRepository) {
        self.repository = repository
    }

    /// Carga (o recarga) la lista aplicando el texto de búsqueda actual.
    /// Llamar en `onAppear` y después de sincronizar.
    func reload() {
        do {
            items = try repository.items(matching: searchText)
            loadError = false
        } catch {
            items = []
            loadError = true
        }
    }
}
