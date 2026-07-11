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

    init() {
        // Base local en el contenedor de la app. Si falla la apertura, es un error
        // no recuperable: la app offline-first no puede operar sin su base.
        do {
            self.database = try AppDatabase.makeShared()
        } catch {
            fatalError("No se pudo abrir la base local: \(error)")
        }
        // El token del Keychain alimenta tanto al cliente HTTP (Authorization: Bearer)
        // como a la sesión, para que ambos vean el mismo almacenamiento.
        let tokenStore = KeychainTokenStore()
        self.api = APIClient(
            baseURL: AppConfig.middlewareBaseURL,
            tokenProvider: { try? tokenStore.read() }
        )
        self.sync = SyncEngine(database: database, api: api)
        self.auth = AuthSession(api: api, store: tokenStore)
    }
}
