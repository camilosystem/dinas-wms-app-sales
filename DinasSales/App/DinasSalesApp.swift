import SwiftUI

// El entry point solo aplica a la app iOS (iPad + iPhone). Se excluye del build de
// host (macOS) usado por `swift test`, donde `@main` chocaría con el runner de pruebas.
#if canImport(UIKit)

/// Entry point de la App de Vendedores.
/// Universal (iPad + iPhone), offline-first. La base local se abre al arrancar.
@main
struct DinasSalesApp: App {
    /// Contenedor de dependencias vivo durante toda la app.
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            AuthGate()
                .environmentObject(environment)
                .environmentObject(environment.network)
                .environmentObject(environment.sync)
        }
    }
}

#endif
