import SwiftUI

/// Entry point de la App de Vendedores.
/// Universal (iPad + iPhone), offline-first. La base local se abre al arrancar.
@main
struct DinasSalesApp: App {
    /// Contenedor de dependencias vivo durante toda la app.
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
        }
    }
}
