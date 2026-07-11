import SwiftUI

/// Imagen remota con descarga diferida y caché.
///
/// Usa `AsyncImage`, que se apoya en la caché de `URLSession` (`URLCache`). No bloquea
/// la sincronización de datos: la imagen se pide por separado desde `image_url`.
struct RemoteImage: View {
    let urlString: String?
    var contentMode: ContentMode = .fit

    var body: some View {
        if let urlString, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: contentMode)
                case .failure:
                    placeholder(system: "photo")
                case .empty:
                    ProgressView()
                @unknown default:
                    placeholder(system: "photo")
                }
            }
        } else {
            placeholder(system: "shippingbox")
        }
    }

    private func placeholder(system: String) -> some View {
        Image(systemName: system)
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.1))
    }
}
