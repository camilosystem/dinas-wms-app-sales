import SwiftUI

/// Enruta entre login y la app según el estado de sesión.
/// Es la vista raíz que se muestra en la ventana.
struct AuthGate: View {
    @EnvironmentObject private var environment: AppEnvironment

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
            }
        }
        .task { environment.auth.restore() }
    }
}
