import SwiftUI

/// Franja que avisa que no hay conexión. La app es offline-first: el vendedor puede
/// seguir trabajando; esto solo informa que la sincronización está en pausa.
struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text("Sin conexión — trabajando offline")
            Spacer()
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.orange)
    }
}
