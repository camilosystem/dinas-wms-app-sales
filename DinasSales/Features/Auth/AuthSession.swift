import Foundation
import os

/// Motivo de un login fallido (para mostrar el mensaje correcto y para tests).
enum LoginFailure: Equatable {
    case badCredentials     // 401: usuario/contraseña incorrectos
    case offlineNoSession   // sin red y sin sesión previa en el dispositivo
    case serverError        // 5xx / configuración
    case connectionError    // la red falló pese a estar "online"
}

/// Estado de sesión del vendedor y fuente de verdad para mostrar login o app.
///
/// **Sesión ligada al dispositivo (offline-first):** si el dispositivo ya tiene una
/// sesión guardada (login online previo), la app se abre SIN conexión y el vendedor
/// trabaja con los últimos datos sincronizados. No se guarda la contraseña.
@MainActor
final class AuthSession: ObservableObject {

    enum State: Equatable {
        case unknown     // aún no se consultó el almacenamiento
        case signedOut   // sin sesión en el dispositivo
        case signedIn    // sesión establecida (online u offline)
    }

    @Published private(set) var state: State = .unknown
    @Published private(set) var isAuthenticating = false
    @Published private(set) var displayName: String?
    @Published private(set) var username: String?
    /// Token vencido (401): la app sigue usable offline, pero NO puede sincronizar hasta
    /// re-autenticarse con conexión.
    @Published private(set) var needsReauth = false
    @Published private(set) var loginFailure: LoginFailure?
    @Published var errorMessage: String?

    private let api: AuthAPI
    private let store: SessionStore
    private let now: () -> Date

    init(api: AuthAPI, store: SessionStore, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.store = store
        self.now = now
    }

    /// Restaura la sesión al arrancar. Si hay sesión en el dispositivo, entra
    /// (funcione o no la red).
    func restore() {
        do {
            if let session = try store.read() {
                displayName = session.displayName
                username = session.username
                state = .signedIn
            } else {
                state = .signedOut
            }
        } catch {
            state = .signedOut
        }
    }

    /// Inicia sesión. `isOnline` decide la estrategia y el mensaje de error.
    func login(username: String, password: String, isOnline: Bool) async {
        errorMessage = nil
        loginFailure = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        guard isOnline else {
            // Sin conexión: entra si el dispositivo ya tiene sesión; si no, no puede.
            if let existing = try? store.read() {
                displayName = existing.displayName
                self.username = existing.username
                state = .signedIn
                AppLog.auth.info("login offline con sesión previa")
            } else {
                loginFailure = .offlineNoSession
                errorMessage = "Sin conexión. La primera vez necesitas conexión para iniciar sesión."
                AppLog.auth.warning("login offline sin sesión previa")
            }
            return
        }

        do {
            let response = try await api.login(username: username, password: password)
            let session = StoredSession(
                token: response.token,
                username: username,
                displayName: response.displayName,
                salespersonCode: response.salespersonCode,
                lastOnlineLoginAt: now()
            )
            try store.save(session)
            displayName = response.displayName
            self.username = username
            needsReauth = false
            state = .signedIn
            AppLog.auth.info("login exitoso")
        } catch APIError.unauthorized {
            loginFailure = .badCredentials
            errorMessage = "Usuario o contraseña incorrectos."
            AppLog.auth.warning("login: credenciales inválidas")
        } catch APIError.missingBaseURL {
            loginFailure = .serverError
            errorMessage = "Falta configurar la URL del middleware."
            AppLog.auth.error("login: falta MIDDLEWARE_BASE_URL")
        } catch APIError.server(let status) {
            loginFailure = .serverError
            errorMessage = "El servidor no responde (\(status)). Intenta más tarde."
            AppLog.auth.error("login: server \(status, privacy: .public)")
        } catch {
            loginFailure = .connectionError
            errorMessage = "No se pudo conectar con el servidor. Intenta de nuevo."
            AppLog.auth.error("login: error \(String(describing: error), privacy: .public)")
        }
    }

    /// Cierra sesión: borra la sesión del dispositivo y vuelve a `signedOut`.
    /// (Un logout deliberado sí exige reconexión para volver a entrar.)
    func logout() {
        try? store.clear()
        displayName = nil
        username = nil
        needsReauth = false
        loginFailure = nil
        state = .signedOut
    }

    /// La sesión expiró (401 durante el sync). NO borra la sesión: el vendedor sigue
    /// trabajando offline. Solo marca que hace falta re-autenticarse para sincronizar.
    func sessionExpired() {
        AppLog.auth.warning("sesión expirada (401) — se mantiene el acceso offline")
        needsReauth = true
    }
}
