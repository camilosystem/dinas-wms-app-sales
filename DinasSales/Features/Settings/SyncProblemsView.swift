import SwiftUI

/// Panel ÚNICO de problemas de sincronización: reúne todo lo que el servidor rechazó o dejó
/// atascado — órdenes rechazadas Y pagos/solicitudes de crédito fallidos — en un solo lugar,
/// con el motivo y las acciones para decidir (reintentar / descartar). Nada queda oculto en un
/// reintento silencioso.
struct SyncProblemsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var rejectedOrders: [OrderSummary] = []
    @State private var failedPayments: [AccountPayment] = []
    @State private var failedRequests: [CreditRequest] = []
    @State private var orderToDiscard: OrderSummary?

    private var carteraRepo: CarteraRepository { CarteraRepository(database: environment.database) }
    private var ordersRepo: OrdersRepository { OrdersRepository(database: environment.database) }

    /// Total de problemas (para el badge en Ajustes).
    static func count(database: AppDatabase) -> Int {
        let orders = ((try? OrdersRepository(database: database).summaries()) ?? [])
            .filter { $0.order.status == .rejected }.count
        let repo = CarteraRepository(database: database)
        return orders + ((try? repo.failedPayments())?.count ?? 0)
                      + ((try? repo.failedCreditRequests())?.count ?? 0)
    }

    private var isEmpty: Bool {
        rejectedOrders.isEmpty && failedPayments.isEmpty && failedRequests.isEmpty
    }

    var body: some View {
        Group {
            if isEmpty {
                ContentUnavailableViewCompat(
                    title: "Sin problemas",
                    message: "Nada rechazado ni atascado. Todo lo enviado fue aceptado.",
                    systemImage: "checkmark.seal"
                )
            } else {
                List {
                    if !rejectedOrders.isEmpty {
                        Section("Órdenes rechazadas") {
                            ForEach(rejectedOrders) { orderRow($0) }
                        }
                    }
                    if !failedPayments.isEmpty {
                        Section("Pagos con problema") {
                            ForEach(failedPayments) { paymentRow($0) }
                        }
                    }
                    if !failedRequests.isEmpty {
                        Section("Solicitudes de crédito con problema") {
                            ForEach(failedRequests) { requestRow($0) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Problemas de sincronización")
        .navigationBarTitleDisplayModeInlineCompat()
        .task { reload() }
        .confirmationDialog("¿Descartar esta orden?", isPresented: Binding(
            get: { orderToDiscard != nil }, set: { if !$0 { orderToDiscard = nil } }),
            titleVisibility: .visible, presenting: orderToDiscard) { summary in
            Button("Descartar", role: .destructive) {
                try? ordersRepo.discardOrder(orderUUID: summary.order.clientUUID)
                orderToDiscard = nil; reload()
            }
            Button("Cancelar", role: .cancel) { orderToDiscard = nil }
        } message: { _ in
            Text("Se eliminará la orden y sus líneas. Esta acción no se puede deshacer.")
        }
    }

    private func reload() {
        rejectedOrders = ((try? ordersRepo.summaries()) ?? [])
            .filter { $0.order.status == .rejected }
        failedPayments = (try? carteraRepo.failedPayments()) ?? []
        failedRequests = (try? carteraRepo.failedCreditRequests()) ?? []
    }

    // MARK: - Filas

    private func orderRow(_ summary: OrderSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.clientName).font(.body.weight(.medium))
            if let number = summary.order.orderNumber {
                Text("N.º \(number)").font(.caption).foregroundStyle(.secondary)
            }
            reasonLabel(summary.order.rejectionReason ?? "Rechazada por el servidor.")
        }
        .swipeActions {
            Button(role: .destructive) { orderToDiscard = summary } label: {
                Label("Descartar", systemImage: "trash")
            }
        }
    }

    private func paymentRow(_ payment: AccountPayment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pago \(payment.method.rawValue.capitalized)").font(.body.weight(.medium))
                Spacer()
                Text(MoneyFormat.string(payment.amount)).font(.callout.weight(.semibold))
            }
            Text(payment.clientCode).font(.caption).foregroundStyle(.secondary)
            reasonLabel(payment.failureReason ?? "Rechazado por el servidor.")
            actions(retry: { try? carteraRepo.retryPayment(paymentUUID: payment.paymentUUID); reload() },
                    discard: { try? carteraRepo.discardPayment(paymentUUID: payment.paymentUUID); reload() })
        }
    }

    private func requestRow(_ request: CreditRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Crédito · \(request.mode == .conItems ? "con ítems" : "sin ítems")")
                .font(.body.weight(.medium))
            Text("\(request.clientCode) · \(request.reason.rawValue)")
                .font(.caption).foregroundStyle(.secondary)
            reasonLabel(request.failureReason ?? "Rechazada por el servidor.")
            actions(retry: { try? carteraRepo.retryCreditRequest(requestUUID: request.requestUUID); reload() },
                    discard: { try? carteraRepo.discardCreditRequest(requestUUID: request.requestUUID); reload() })
        }
    }

    private func reasonLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.red)
    }

    /// Fila de acciones para un ítem de cartera: reintentar (vuelve a la cola) o descartar.
    private func actions(retry: @escaping () -> Void, discard: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button("Reintentar", action: retry).buttonStyle(.bordered)
            Button("Descartar", role: .destructive, action: discard).buttonStyle(.bordered)
            Spacer()
        }
        .font(.callout)
        .padding(.top, 2)
    }
}
