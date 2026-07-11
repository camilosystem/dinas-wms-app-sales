import Foundation

/// Contenedor de dependencias de la app (composición raíz).
///
/// Mantiene vivas las piezas de larga duración: base de datos local, cliente HTTP
/// y motor de sincronización. Se inyecta por el árbol de vistas como `EnvironmentObject`.
///
/// Es un esqueleto: las piezas están declaradas pero su implementación se completa
/// en las siguientes iteraciones del MVP.
@MainActor
final class AppEnvironment: ObservableObject {
    let database: AppDatabase
    let api: APIClient
    let sync: SyncEngine
    let auth: AuthSession
    let pendingOrders: PendingOrdersObserver
    let network: NetworkMonitor

    init() {
        // Base local en el contenedor de la app. Si falla la apertura, es un error
        // no recuperable: la app offline-first no puede operar sin su base.
        let database: AppDatabase
        do {
            database = try AppDatabase.makeShared()
        } catch {
            fatalError("No se pudo abrir la base local: \(error)")
        }
        self.database = database

        // El token del Keychain alimenta tanto al cliente HTTP (Authorization: Bearer)
        // como a la sesión, para que ambos vean el mismo almacenamiento.
        let tokenStore = KeychainTokenStore()
        let api = APIClient(
            baseURL: AppConfig.middlewareBaseURL,
            tokenProvider: { try? tokenStore.read() }
        )
        self.api = api

        let auth = AuthSession(api: api, store: tokenStore)
        self.auth = auth

        // Un 401 durante la sincronización expira la sesión → la app vuelve al login.
        let sync = SyncEngine(database: database, api: api,
                              onUnauthorized: { auth.sessionExpired() })
        self.sync = sync

        self.pendingOrders = PendingOrdersObserver(database: database)

        // Auto-sync al recuperar la red, solo si hay sesión activa.
        let network = NetworkMonitor()
        network.onReconnect = { [weak auth, weak sync] in
            guard let auth, let sync, auth.state == .signedIn else { return }
            Task { await sync.sync() }
        }
        self.network = network
    }
}
