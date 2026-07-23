#if os(iOS)
import UIKit

/// Utilidades compartidas para la foto de evidencia de cartera (Reportar Pago / Solicitar Crédito).
/// La evidencia debe viajar LIGERA (~150-300 KB): no bloquear la sync por subir imágenes pesadas.
extension UIImage {
    /// Reduce el lado mayor a ~1024px. Clave: fija `format.scale = 1`, si no el renderer usa el
    /// scale de la pantalla (×2/×3 en Retina) y el CGImage sale a 2x/3x los píxeles pedidos —
    /// anulando el resize (p. ej. 1024pt @3x → 3072px). Con scale=1, 1024pt = 1024px reales.
    func resizedForEvidence(maxSide: CGFloat = 1024) -> UIImage {
        let side = max(size.width, size.height)
        guard side > maxSide else { return self }
        let scale = maxSide / side
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    /// Reduce (~1024px) y comprime a JPEG (~70%), devolviendo la evidencia lista en base64.
    func evidenceBase64(compressionQuality: CGFloat = 0.7) -> String? {
        resizedForEvidence().jpegData(compressionQuality: compressionQuality)?.base64EncodedString()
    }
}
#endif
