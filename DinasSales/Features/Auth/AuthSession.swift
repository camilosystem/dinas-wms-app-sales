import Foundation

/// Estado de sesión del vendedor. Fuente de verdad para saber si hay que mostrar el
/// login o la app. El token vive en el `TokenStore` (Keychain en producción).
@MainActor
final class AuthSession: ObservableObject {

    /// Estado de autenticación.
    enum State: Equatable {
        case unknown     // aún no se consultó el almacenamiento
        case signedOut   // sin token
        case signedIn    // token presente
    }

    @Published private(set) var state: State = .unknown
    @Published private(set) var isAuthenticating = false
    @Published private(set) var displayName: String?
    @Published var errorMessage: String?

    private let api: AuthAPI
    private let store: TokenStore

    init(api: AuthAPI, store: TokenStore) {
        self.api = api
        self.store = store
    }

    /// Restaura el estado al arrancar leyendo el token guardado.
    func restore() {
        do {
            state = (try store.read()?.isEmpty == false) ? .signedIn : .signedOut
        } catch {
            // Si el almacenamiento falla, tratamos como sin sesión (login de nuevo).
            state = .signedOut
        }
    }

    /// Inicia sesión: llama al middleware, guarda el JWT y pasa a `signedIn`.
    func login(username: String, password: String) async {
        errorMessage = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let response = try await api.login(username: username, password: password)
            try store.save(response.token)
            displayName = response.displayName
            state = .signedIn
        } catch APIError.unauthorized {
            errorMessage = "Usuario o contraseña incorrectos."
        } catch APIError.missingBaseURL {
            errorMessage = "Falta configurar la URL del middleware."
        } catch {
            errorMessage = "No se pudo iniciar sesión. Revisa la conexión."
        }
    }

    /// Cierra sesión: borra el token y vuelve a `signedOut`.
    func logout() {
        try? store.clear()
        displayName = nil
        state = .signedOut
    }

    /// La sesión expiró (401 del middleware): limpia el token y pide re-login.
    func sessionExpired() {
        try? store.clear()
        displayName = nil
        errorMessage = "Tu sesión expiró. Inicia sesión de nuevo."
        state = .signedOut
    }
}
