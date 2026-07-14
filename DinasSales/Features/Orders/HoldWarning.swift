import Foundation

/// Predicción LOCAL de que una orden quedará RETENIDA por cartera (★ v0.4.0).
///
/// Espeja la regla del middleware con los datos de la ÚLTIMA sincronización, SOLO para
/// **advertir** al vendedor. Es informativa: la app advierte, **NUNCA bloquea**. El
/// middleware re-evalúa con datos frescos al recibir la orden y su veredicto manda; los
/// dos pueden diferir (el saldo cambió) y está bien.
///
/// ⚠️ Usa `credit.hasOverdue`, que viene CALCULADO del servidor. La app NO recalcula el
/// umbral de días de gracia — si mañana cambia en el servidor, esto lo refleja solo.
struct HoldWarning: Equatable {
    let exceedsCredit: Bool
    let hasOverdue: Bool
    let credit: ClientCredit
    let orderTotal: Double

    /// Regla de retención (idéntica a la del contrato):
    ///   (a) balance + total de la orden > credit_limit   → excede cupo
    ///   (b) has_overdue == true                           → mora
    /// Devuelve `nil` si, según los datos locales, la orden NO se retendría.
    static func evaluate(credit: ClientCredit, orderTotal: Double) -> HoldWarning? {
        let exceeds = credit.balance + orderTotal > credit.creditLimit
        let overdue = credit.hasOverdue
        guard exceeds || overdue else { return nil }
        return HoldWarning(exceedsCredit: exceeds, hasOverdue: overdue,
                           credit: credit, orderTotal: orderTotal)
    }

    /// Mensaje claro para el vendedor. Ej.:
    /// "Esta orden quedará retenida para aprobación: el cliente excede su cupo de crédito
    ///  por $1,200.00 y tiene 3 facturas vencidas ($4,500.00)."
    var message: String {
        var parts: [String] = []
        if exceedsCredit {
            let over = credit.balance + orderTotal - credit.creditLimit
            parts.append("excede su cupo de crédito por \(MoneyFormat.string(over))")
        }
        if hasOverdue {
            let n = credit.overdueCount
            let facturas = n == 1 ? "1 factura vencida" : "\(n) facturas vencidas"
            parts.append("tiene \(facturas) (\(MoneyFormat.string(credit.overdueAmount)))")
        }
        let detail = parts.joined(separator: " y ")
        return "Esta orden quedará retenida para aprobación: el cliente \(detail)."
    }
}
