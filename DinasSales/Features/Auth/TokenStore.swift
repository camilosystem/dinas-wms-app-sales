import Foundation

/// Abstracción del almacenamiento del JWT.
///
/// Permite inyectar una implementación de Keychain en producción y una en memoria
/// en tests (el Keychain no está disponible sin entitlements en el host de pruebas).
protocol TokenStore {
    /// Lee el token guardado, o `nil` si no hay sesión.
    func read() throws -> String?
    /// Guarda (o reemplaza) el token.
    func save(_ token: String) throws
    /// Borra el token (cerrar sesión).
    func clear() throws
}

/// Implementación de producción: guarda el JWT en el Keychain.
struct KeychainTokenStore: TokenStore {
    private let keychain: KeychainStore
    private let key: String

    init(keychain: KeychainStore = KeychainStore(), key: String = "jwt") {
        self.keychain = keychain
        self.key = key
    }

    func read() throws -> String? { try keychain.get(key) }
    func save(_ token: String) throws { try keychain.set(token, for: key) }
    func clear() throws { try keychain.delete(key) }
}

/// Implementación en memoria para tests y previews.
final class InMemoryTokenStore: TokenStore {
    private var token: String?

    init(token: String? = nil) { self.token = token }

    func read() throws -> String? { token }
    func save(_ token: String) throws { self.token = token }
    func clear() throws { token = nil }
}
