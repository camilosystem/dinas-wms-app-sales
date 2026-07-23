import SwiftUI

/// Enruta entre login y la app según el estado de sesión.
/// Es la vista raíz que se muestra en la ventana.
struct AuthGate: View {
    @EnvironmentObject private var environment: AppEnvironment
    // Observa `auth` DIRECTAMENTE: es un ObservableObject anidado en AppEnvironment,
    // así que sus cambios (state → signedIn) no llegarían vía `environment` solo.
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        // ★ El banner offline va en un VStack ARRIBA del contenido (no como `safeAreaInset`, que
        // solapaba las barras de navegación y tapaba controles: engranaje/"Cerrar sesión" en Home,
        // "Guardar/Confirmar" en el carrito, etc.). Así EMPUJA todo hacia abajo y nunca tapa nada.
        // Fix en un solo lugar → cubre todas las pantallas, presentes y futuras.
        VStack(spacing: 0) {
            if !network.isOnline { OfflineBanner() }

            Group {
                switch auth.state {
                case .unknown:
                    ProgressView()
                case .signedOut:
                    LoginView()
                case .signedIn:
                    RootView()
                        .environmentObject(environment.pendingOrders)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { auth.restore() }
    }
}
