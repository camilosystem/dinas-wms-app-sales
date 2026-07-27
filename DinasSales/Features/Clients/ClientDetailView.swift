import SwiftUI

/// Detalle de un cliente asignado.
struct ClientDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let client: Client

    @State private var showReportPayment = false
    @State private var showRequestCredit = false
    @State private var resultMessage: String?
    @State private var showResult = false
    @State private var reportedPayments: [AccountPayment] = []

    var body: some View {
        List {
            if !client.active {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Cliente dado de baja en SAP. Se conserva porque tiene órdenes en la app; no puedes tomarle pedidos nuevos.")
                            .font(.callout)
                    }
                    .foregroundStyle(.orange)
                }
            }

            Section("Cliente") {
                row("Código", client.clientCode)
                row("Nombre", client.name)
            }

            Section("Cartera") {
                CreditSummaryRows(credit: client.credit)
                NavigationLink {
                    StatementView(
                        clientCode: client.clientCode,
                        clientName: client.name,
                        api: environment.api,
                        database: environment.database,
                        isOnline: { environment.network.isOnline },
                        onUnauthorized: { environment.auth.sessionExpired() }
                    )
                } label: {
                    Label("Ver estado de cuenta", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    showReportPayment = true
                } label: {
                    Label("Reportar Pago", systemImage: "dollarsign.circle")
                }
                Button {
                    showRequestCredit = true
                } label: {
                    Label("Solicitar Crédito", systemImage: "arrow.uturn.backward.circle")
                }
            }

            // Pagos ya reportados desde la app, con su estado. Solo-lectura: evita que el vendedor
            // reporte dos veces lo mismo por no ver que ya lo hizo. No bloquea reportar otros.
            if !reportedPayments.isEmpty {
                Section("Pagos reportados") {
                    ForEach(reportedPayments) { reportedPaymentRow($0) }
                }
            }

            Section("Ubicación") {
                if let address = client.address, !address.isEmpty { row("Dirección", address) }
                if let city = client.city, !city.isEmpty { row("Ciudad", city) }
                if let zip = client.zipcode, !zip.isEmpty { row("Código postal", zip) }
            }

            Section("Logística") {
                if let manager = client.managerName, !manager.isEmpty {
                    row("Encargado", manager)
                }
                if let route = client.shippingRoute, !route.isEmpty {
                    row("Ruta de reparto", route)
                }
            }
        }
        .navigationTitle(client.name)
        .navigationBarTitleDisplayModeInlineCompat()
        .task { reloadPayments() }
        // Al cerrar la hoja de Reportar Pago, recarga la lista (puede haber uno nuevo).
        .onChange(of: showReportPayment) { showing in if !showing { reloadPayments() } }
        .sheet(isPresented: $showReportPayment) {
            ReportPaymentView(client: client) { message in
                resultMessage = message
                showResult = true
            }
        }
        .sheet(isPresented: $showRequestCredit) {
            RequestCreditView(client: client) { message in
                resultMessage = message
                showResult = true
            }
        }
        .alert("Cartera", isPresented: $showResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    private func reportedPaymentRow(_ payment: AccountPayment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(MoneyFormat.string(payment.amount)).font(.body.weight(.medium))
                Spacer()
                statusBadge(payment.reportedStatus)
            }
            Text("\(payment.method.label) · \(payment.paymentDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func statusBadge(_ status: AccountPayment.ReportedStatus) -> some View {
        let text: String, color: Color
        switch status {
        case .porEnviar:   (text, color) = ("Por enviar", .orange)
        case .reportado:   (text, color) = ("Reportado", .blue)
        case .conProblema: (text, color) = ("Con problema", .red)
        }
        return Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    private func reloadPayments() {
        reportedPayments = (try? CarteraRepository(database: environment.database)
            .payments(clientCode: client.clientCode)) ?? []
    }
}
