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

    /// Usuario cuyo archivo de base está abierto ahora (para detectar el cambio de usuario).
    private var currentDBUser: String?

    init() {
        // La sesión (con el JWT) vive en el Keychain. El cliente HTTP toma el token de ahí.
        let sessionStore = KeychainSessionStore()

        // ★ Aislamiento por usuario: se abre el archivo del usuario YA guardado (si reabrimos la
        // app con sesión). Dos vendedores en el mismo dispositivo NUNCA ven datos del otro.
        let initialUser = (try? sessionStore.read())?.username
        let database: AppDatabase
        do {
            database = try AppDatabase.makeForUser(initialUser)
        } catch {
            fatalError("No se pudo abrir la base local: \(error)")
        }
        self.database = database
        self.currentDBUser = initialUser

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

        let pendingOrders = PendingOrdersObserver(database: database)
        self.pendingOrders = pendingOrders

        // Conectividad re-evaluada activamente: el monitor SONDEA al middleware (no solo mira la
        // interfaz de red) y se recupera solo o con el botón "Reintentar". NO dispara sync.
        self.network = NetworkMonitor(probe: { await api.checkReachability() })

        // Login ONLINE → (1) si entró OTRO usuario, apunta la base a SU archivo y reinicia el
        // observador (aislamiento estructural; el login offline solo reactiva al mismo usuario);
        // (2) resetea las marcas de sync para que la próxima bajada sea completa y reconcilie.
        // Va al final: capturar `self` exige que todas las props estén inicializadas.
        auth.onOnlineLogin = { [weak self, weak sync, weak pendingOrders] in
            if let self {
                let user = (try? sessionStore.read())?.username
                if user != self.currentDBUser {
                    self.currentDBUser = user
                    try? self.database.reopen(forUser: user)
                    pendingOrders?.restart()
                }
            }
            sync?.resetWatermarks()
        }
    }
}
