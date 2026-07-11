import Foundation

/// Formateo de importes.
///
/// Dinas opera solo en NY/NJ/CT/PA, en dólares: la moneda es **USD fija** (decisión del
/// Arquitecto). No hay campo `currency` en el contrato ni manejo multi-moneda.
enum MoneyFormat {
    static let currencyCode = "USD"

    static func string(_ amount: Double) -> String {
        amount.formatted(.currency(code: currencyCode))
    }
}
