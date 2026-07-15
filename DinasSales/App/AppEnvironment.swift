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

        // La sesión (con el JWT) vive en el Keychain. El cliente HTTP toma el token de
        // ahí para el Authorization: Bearer, y la sesión gobierna el acceso a la app.
        let sessionStore = KeychainSessionStore()
        let api = APIClient(
            baseURL: AppConfig.middlewareBaseURL,
            tokenProvider: { try? sessionStore.read()?.token }
        )
        self.api = api

        let auth = AuthSession(api: api, store: sessionStore)
        self.auth = auth

        // Un 401 durante la sincronización expira la sesión → la app vuelve al login.
        let sync = SyncEngine(database: database, api: api,
                              onUnauthorized: { auth.sessionExpired() })
        self.sync = sync

        // Login ONLINE → resetea las marcas de sync para que la próxima bajada sea
        // completa y reconcilie (baja el set actual del vendedor; quita lo que ya no
        // le corresponde, salvo lo referenciado por sus órdenes locales).
        auth.onOnlineLogin = { [weak sync] in sync?.resetWatermarks() }

        self.pendingOrders = PendingOrdersObserver(database: database)

        // Conectividad re-evaluada activamente: el monitor SONDEA al middleware (no solo
        // mira la interfaz de red) y se recupera solo o con el botón "Reintentar". NO
        // dispara sync — sigue siendo manual, disparado por el vendedor.
        self.network = NetworkMonitor(probe: { await api.checkReachability() })
    }
}
