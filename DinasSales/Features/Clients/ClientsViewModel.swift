import Foundation

/// Una sección de la vista "Por Ciudad": la ciudad (encabezado) y sus clientes.
struct ClientCitySection: Identifiable, Equatable {
    let city: String            // nombre a mostrar; el rótulo "Sin ciudad" para el bucket vacío
    let clients: [Client]
    let isNoCity: Bool          // true = sección "Sin ciudad" (va al final)
    var id: String { city }
}

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

    /// Secciones de la lista actual (ya filtrada por búsqueda), para la vista "Por Ciudad".
    var citySections: [ClientCitySection] { Self.groupByCity(clients) }

    /// Agrupa clientes por ciudad: ciudades ordenadas alfabéticamente, clientes por nombre
    /// dentro de cada una. Los que no tienen ciudad van en "Sin ciudad" AL FINAL. Como recibe
    /// los clientes ya filtrados, una ciudad sin resultados simplemente no genera sección
    /// (no se muestra vacía). Función pura → testeable.
    static func groupByCity(_ clients: [Client],
                            noCityLabel: String = "Sin ciudad") -> [ClientCitySection] {
        var buckets: [String: [Client]] = [:]
        var noCity: [Client] = []
        for client in clients {
            let city = client.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if city.isEmpty { noCity.append(client) } else { buckets[city, default: []].append(client) }
        }
        let byName: (Client, Client) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        var sections = buckets.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { ClientCitySection(city: $0, clients: buckets[$0]!.sorted(by: byName),
                                     isNoCity: false) }
        if !noCity.isEmpty {
            sections.append(ClientCitySection(city: noCityLabel, clients: noCity.sorted(by: byName),
                                              isNoCity: true))
        }
        return sections
    }
}
