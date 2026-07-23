import SwiftUI

/// Toggle de vista de SOLO ÍCONO en una esquina: un botón que alterna entre dos modos. El ícono
/// representa el MODO ACTIVO (relleno, en color de acento) → es obvio cuál está activo, y no
/// compite por ancho con el buscador. Componente genérico reutilizable (Clientes, Catálogo…).
struct ViewModeIconToggle: View {
    /// Ícono (SF Symbol) del modo activo.
    let systemImage: String
    /// Nombre del modo activo (para accesibilidad).
    let modeName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cambiar vista")
        .accessibilityValue(modeName)
    }
}
