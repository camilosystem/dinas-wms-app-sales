import Foundation

/// Formateo de importes.
///
/// ⚠️ La moneda NO está en `openapi.yaml`. Se usa un placeholder; confirmar con el
/// Arquitecto el código de moneda (o si el middleware ya envía importes formateados).
enum MoneyFormat {
    static let currencyCode = "USD"   // TODO(contrato): confirmar moneda real

    static func string(_ amount: Double) -> String {
        amount.formatted(.currency(code: currencyCode))
    }
}
