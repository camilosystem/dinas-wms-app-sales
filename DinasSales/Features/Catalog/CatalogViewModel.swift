import Foundation

/// Una sección de la vista "Por Categoría": la categoría (encabezado) y sus ítems.
struct CatalogSection: Identifiable, Equatable {
    let category: String        // nombre a mostrar; "Sin categoría" para el bucket vacío
    let items: [Item]
    let isNoCategory: Bool       // true = sección "Sin categoría" (va al final)
    var id: String { category }
}

/// Restringe el catálogo a UNA categoría (nivel 2 del drill-down). `.all` = catálogo completo.
enum CatalogCategoryFilter: Equatable {
    case all
    case named(String)      // una categoría concreta (nombre ya normalizado)
    case uncategorized      // "Sin categoría" (category vacía o nula)
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
    /// Si no es `.all`, la lista queda restringida a esa categoría (pantalla nivel 2).
    private let categoryFilter: CatalogCategoryFilter

    init(repository: CatalogRepository, categoryFilter: CatalogCategoryFilter = .all) {
        self.repository = repository
        self.categoryFilter = categoryFilter
    }

    /// Carga (o recarga) la lista aplicando el texto de búsqueda actual (y el filtro de categoría
    /// si lo hay). Todo el trabajo se hace aquí y se cachea; el `body` nunca recalcula.
    func reload() {
        do {
            var result = try repository.items(matching: searchText)
            switch categoryFilter {
            case .all:
                break
            case .named(let name):
                result = result.filter { Self.normalizedCategory($0) == name }
            case .uncategorized:
                result = result.filter { Self.normalizedCategory($0).isEmpty }
            }
            items = result
            // Las secciones solo importan en el catálogo completo (nivel 1).
            categorySections = (categoryFilter == .all) ? Self.groupByCategory(items) : []
            loadError = false
        } catch {
            items = []
            categorySections = []
            loadError = true
        }
    }

    private static func normalizedCategory(_ item: Item) -> String {
        item.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
