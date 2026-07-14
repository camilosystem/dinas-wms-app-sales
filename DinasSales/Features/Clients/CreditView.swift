import SwiftUI

/// Indicador visual del estado de cartera del cliente (al día / en mora / excede cupo).
/// El estado lo determina el servidor (`credit_available`, `has_overdue`); la app solo
/// lo pinta — NO recalcula umbrales.
struct CreditStatusBadge: View {
    let status: ClientCredit.Status

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var text: String {
        switch status {
        case .alDia: return "Al día"
        case .enMora: return "En mora"
        case .excedeCupo: return "Excede cupo"
        }
    }

    private var color: Color {
        switch status {
        case .alDia: return .green
        case .enMora: return .orange
        case .excedeCupo: return .red
        }
    }
}

/// Filas del resumen de cartera, para incrustar en una `Section`. Muestra saldo (oficial),
/// cupo, cupo disponible (negativo resaltado) y la mora si la hay.
struct CreditSummaryRows: View {
    let credit: ClientCredit

    var body: some View {
        LabeledRow(title: "Estado") { CreditStatusBadge(status: credit.status) }
        LabeledRow(title: "Saldo") {
            Text(MoneyFormat.string(credit.balance)).fontWeight(.semibold)
        }
        LabeledRow(title: "Cupo") { Text(MoneyFormat.string(credit.creditLimit)) }
        LabeledRow(title: "Cupo disponible") {
            Text(MoneyFormat.string(credit.creditAvailable))
                .foregroundStyle(credit.creditAvailable < 0 ? Color.red : Color.primary)
                .fontWeight(credit.creditAvailable < 0 ? .semibold : .regular)
        }
        if credit.overdueCount > 0 {
            LabeledRow(title: "Facturas vencidas") {
                Text("\(credit.overdueCount) · \(MoneyFormat.string(credit.overdueAmount))")
                    .foregroundStyle(.orange)
            }
            LabeledRow(title: "Más atrasada") {
                Text("\(credit.maxDaysOverdue) días")
                    .foregroundStyle(credit.maxDaysOverdue > 0 ? Color.orange : Color.primary)
            }
        }
    }
}

/// Fila título ↔ contenido, alineada como el resto del detalle de cliente.
struct LabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            content.multilineTextAlignment(.trailing)
        }
    }
}
