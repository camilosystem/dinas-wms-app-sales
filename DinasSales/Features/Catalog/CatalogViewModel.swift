import Foundation

/// Una sección de la vista "Por Categoría": la categoría (encabezado) y sus ítems.
struct CatalogSection: Identifiable, Equatable {
    let category: String        // nombre a mostrar; "Sin categoría" para el bucket vacío
    let items: [Item]
    let isNoCategory: Bool       // true = sección "Sin categoría" (va al final)
    var id: String { category }
}

/// Estado de la pantalla de catálogo. Lee de la base local (offline) vía repositorio.
@MainActor
final class CatalogViewModel: ObservableObject {
    @Published var searchText = "" { didSet { reload() } }
    @Published private(set) var items: [Item] = []
    /// Secciones por categoría, CACHEADAS: se recalculan solo al recargar (no en cada render).
    /// Recomputar la agrupación en cada actualización de SwiftUI congelaba el hilo principal.
    @Published private(set) var categorySections: [CatalogSection] = []
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
            categorySections = Self.groupByCategory(items)
            loadError = false
        } catch {
            items = []
            categorySections = []
            loadError = true
        }
    }

    /// Agrupa ítems por categoría: categorías ordenadas alfabéticamente, ítems por nombre dentro
    /// de cada una. Los sin categoría van en "Sin categoría" AL FINAL. Como recibe los ítems ya
    /// filtrados, una categoría sin resultados no genera sección (no se muestra vacía). Pura.
    static func groupByCategory(_ items: [Item],
                                noCategoryLabel: String = "Sin categoría") -> [CatalogSection] {
        var buckets: [String: [Item]] = [:]
        var noCategory: [Item] = []
        for item in items {
            let category = item.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if category.isEmpty { noCategory.append(item) }
            else { buckets[category, default: []].append(item) }
        }
        let byName: (Item, Item) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        var sections = buckets.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { CatalogSection(category: $0, items: buckets[$0]!.sorted(by: byName),
                                  isNoCategory: false) }
        if !noCategory.isEmpty {
            sections.append(CatalogSection(category: noCategoryLabel,
                                           items: noCategory.sorted(by: byName), isNoCategory: true))
        }
        return sections
    }
}
