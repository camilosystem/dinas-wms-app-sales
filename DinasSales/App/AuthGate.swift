import SwiftUI

/// Enruta entre login y la app según el estado de sesión.
/// Es la vista raíz que se muestra en la ventana.
struct AuthGate: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        Group {
            switch environment.auth.state {
            case .unknown:
                ProgressView()
            case .signedOut:
                LoginView()
                    .environmentObject(environment.auth)
            case .signedIn:
                RootView()
                    .environmentObject(environment.pendingOrders)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Group {
                if !network.isOnline { OfflineBanner() }
            }
        }
        .task { environment.auth.restore() }
    }
}
