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
    @State private var reportedCredits: [CreditRequest] = []
    @State private var paymentToCancel: AccountPayment?
    @State private var creditToCancel: CreditRequest?

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

            // Reportes ya hechos desde la app, con su estado. Solo-lectura; un reporte que sigue
            // PENDIENTE_APROBACION (Reportado) se puede CANCELAR deslizando (★ v0.21.0).
            if !reportedPayments.isEmpty {
                Section {
                    ForEach(reportedPayments) { payment in
                        reportedPaymentRow(payment)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if payment.reportedStatus == .reportado {
                                    Button("Cancelar", role: .destructive) { paymentToCancel = payment }
                                }
                            }
                    }
                } header: {
                    Text("Pagos reportados")
                } footer: {
                    Text("Desliza un pago Reportado para cancelarlo (solo mientras la oficina no lo haya aprobado/rechazado).")
                }
            }

            if !reportedCredits.isEmpty {
                Section("Solicitudes de crédito reportadas") {
                    ForEach(reportedCredits) { credit in
                        reportedCreditRow(credit)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if credit.reportedStatus == .reportado {
                                    Button("Cancelar", role: .destructive) { creditToCancel = credit }
                                }
                            }
                    }
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
        .task { reloadCartera() }
        // Al cerrar cualquiera de las hojas, recarga (puede haber un reporte nuevo).
        .onChange(of: showReportPayment) { showing in if !showing { reloadCartera() } }
        .onChange(of: showRequestCredit) { showing in if !showing { reloadCartera() } }
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
        .confirmationDialog("Cancelar pago",
            isPresented: Binding(get: { paymentToCancel != nil },
                                 set: { if !$0 { paymentToCancel = nil } }),
            presenting: paymentToCancel) { payment in
            Button("Cancelar pago", role: .destructive) { Task { await cancelPayment(payment) } }
            Button("Volver", role: .cancel) {}
        } message: { _ in
            Text("El pago quedará CANCELADO. Solo es posible mientras la oficina no lo haya aprobado o rechazado.")
        }
        .confirmationDialog("Cancelar solicitud",
            isPresented: Binding(get: { creditToCancel != nil },
                                 set: { if !$0 { creditToCancel = nil } }),
            presenting: creditToCancel) { credit in
            Button("Cancelar solicitud", role: .destructive) { Task { await cancelCredit(credit) } }
            Button("Volver", role: .cancel) {}
        } message: { _ in
            Text("La solicitud quedará CANCELADA. Solo es posible mientras la oficina no la haya decidido.")
        }
        .alert("Cartera", isPresented: $showResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    // MARK: - Filas

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
                badge(payment.reportedStatus)
            }
            Text("\(payment.method.label) · \(payment.paymentDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary)
            // Facturas incluidas en el pago (invoice_doc_num de las applications guardadas).
            if !payment.proposedApplications.isEmpty {
                Text("Facturas: \(payment.proposedApplications.map(\.invoiceDocNum).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reportedCreditRow(_ credit: CreditRequest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(creditTitle(credit)).font(.body.weight(.medium))
                Spacer()
                badge(credit.reportedStatus)
            }
            Text("\(credit.reason.label) · \(credit.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary)
            if let invoice = credit.invoiceDocNum, !invoice.isEmpty {
                Text("Factura: \(invoice)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func creditTitle(_ credit: CreditRequest) -> String {
        switch credit.mode {
        case .sinItems: return credit.manualAmount.map { MoneyFormat.string($0) } ?? "Crédito"
        case .conItems: return "Crédito por ítems"
        }
    }

    /// Badge de estado — el `ReportedStatus` de pago y de crédito son idénticos en cases.
    @ViewBuilder private func badge(_ status: AccountPayment.ReportedStatus) -> some View {
        switch status {
        case .porEnviar:   pill("Por enviar", .orange)
        case .reportado:   pill("Reportado", .blue)
        case .conProblema: pill("Con problema", .red)
        case .cancelado:   pill("Cancelado", .gray)
        }
    }

    @ViewBuilder private func badge(_ status: CreditRequest.ReportedStatus) -> some View {
        switch status {
        case .porEnviar:   pill("Por enviar", .orange)
        case .reportado:   pill("Reportado", .blue)
        case .conProblema: pill("Con problema", .red)
        case .cancelado:   pill("Cancelado", .gray)
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    // MARK: - Acciones

    private func cancelPayment(_ payment: AccountPayment) async {
        let service = CarteraSubmitService(
            repo: CarteraRepository(database: environment.database), api: environment.api)
        do {
            let outcome = try await service.cancelPayment(
                paymentUUID: payment.paymentUUID, reason: nil, isOnline: environment.network.isOnline)
            resultMessage = message(for: outcome, canceledNoun: "Pago cancelado.")
        } catch {
            resultMessage = "No se pudo cancelar el pago: \(error.localizedDescription)"
        }
        showResult = true
        reloadCartera()
    }

    private func cancelCredit(_ credit: CreditRequest) async {
        let service = CarteraSubmitService(
            repo: CarteraRepository(database: environment.database), api: environment.api)
        do {
            let outcome = try await service.cancelCreditRequest(
                requestUUID: credit.requestUUID, reason: nil, isOnline: environment.network.isOnline)
            resultMessage = message(for: outcome, canceledNoun: "Solicitud cancelada.")
        } catch {
            resultMessage = "No se pudo cancelar la solicitud: \(error.localizedDescription)"
        }
        showResult = true
        reloadCartera()
    }

    private func message(for outcome: CarteraCancelOutcome, canceledNoun: String) -> String {
        switch outcome {
        case .canceled:                 return canceledNoun
        case .needsConnection:          return "Necesitas conexión para cancelar un reporte ya enviado."
        case .alreadyDecided(let msg):  return msg
        case .failed(let msg):          return msg
        }
    }

    private func reloadCartera() {
        let repo = CarteraRepository(database: environment.database)
        reportedPayments = (try? repo.payments(clientCode: client.clientCode)) ?? []
        reportedCredits = (try? repo.creditRequests(clientCode: client.clientCode)) ?? []
    }
}
