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

        self.pendingOrders = PendingOrdersObserver(database: database)

        // El monitor de red es SOLO informativo (banner offline). La sincronización es
        // siempre manual, disparada por el vendedor — no hay auto-sync al reconectar.
        self.network = NetworkMonitor()
    }
}
