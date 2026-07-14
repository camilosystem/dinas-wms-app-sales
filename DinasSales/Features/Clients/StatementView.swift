import SwiftUI

/// Estado de cuenta del cliente (★ v0.4.0). Muestra el desglose de documentos que la app
/// guardó localmente. Al abrirse intenta refrescar si hay red; si no, muestra la última
/// foto guardada (offline-first). El `balance` oficial vive en la ficha del cliente.
struct StatementView: View {
    @StateObject private var viewModel: StatementViewModel

    init(clientCode: String, clientName: String, api: CreditAPI,
         database: AppDatabase, isOnline: @escaping () -> Bool,
         onUnauthorized: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: StatementViewModel(
            clientCode: clientCode, clientName: clientName, api: api,
            database: database, isOnline: isOnline, onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        Group {
            if viewModel.documents.isEmpty && !viewModel.hasCache {
                ContentUnavailableViewCompat(
                    title: "Sin estado de cuenta",
                    message: viewModel.isRefreshing
                        ? "Descargando…"
                        : "Conéctate y sincroniza para ver el estado de cuenta de este cliente.",
                    systemImage: "doc.text.magnifyingglass"
                )
            } else {
                list
            }
        }
        .navigationTitle("Estado de cuenta")
        .navigationBarTitleDisplayModeInlineCompat()
        .task { await viewModel.appear() }
        .refreshable { await viewModel.refresh() }
    }

    private var list: some View {
        List {
            if let asOf = viewModel.asOf {
                Section {
                    Text("Al \(asOf.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    if viewModel.showingStale {
                        Text("Sin conexión — mostrando la última foto guardada.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            if !viewModel.invoices.isEmpty {
                Section("Facturas") {
                    ForEach(viewModel.invoices) { StatementRow(doc: $0) }
                }
            }
            if !viewModel.credits.isEmpty {
                Section("Notas de crédito y pagos") {
                    ForEach(viewModel.credits) { StatementRow(doc: $0) }
                }
            }
        }
    }
}

/// Fila de un documento del estado de cuenta.
private struct StatementRow: View {
    let doc: StatementDocument

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.medium))
                    if doc.isOverdue { OverdueTag(days: doc.daysOverdue ?? 0) }
                }
                Text("N.º \(doc.docNum)").font(.caption).foregroundStyle(.secondary)
                if let due = doc.dueDate {
                    Text("Vence \(due.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if doc.isFromSage { Text("Migrado de Sage").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            // Positivo = deuda; negativo = a favor (resta). El signo comunica el sentido.
            Text(MoneyFormat.string(doc.openAmount))
                .font(.body.weight(.semibold))
                .foregroundStyle(doc.openAmount < 0 ? Color.green : Color.primary)
        }
    }

    private var title: String {
        switch doc.docType {
        case .invoice: return "Factura"
        case .creditNote: return "Nota de crédito"
        case .paymentOnAccount: return "Pago a cuenta"
        }
    }
}

/// Etiqueta "N días vencida".
private struct OverdueTag: View {
    let days: Int
    var body: some View {
        Text("\(days) d vencida")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.red.opacity(0.15))
            .foregroundStyle(.red)
            .clipShape(Capsule())
    }
}

/// Estado de la pantalla de estado de cuenta. Lee de la caché local y, si hay red,
/// refresca desde `GET /clients/{code}/statement`. Nunca borra la caché por estar offline.
@MainActor
final class StatementViewModel: ObservableObject {
    @Published private(set) var documents: [StatementDocument] = []
    @Published private(set) var asOf: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var showingStale = false

    let clientCode: String
    let clientName: String
    private let api: CreditAPI
    private let repo: StatementRepository
    private let isOnline: () -> Bool
    private let onUnauthorized: () -> Void

    init(clientCode: String, clientName: String, api: CreditAPI,
         database: AppDatabase, isOnline: @escaping () -> Bool,
         onUnauthorized: @escaping () -> Void) {
        self.clientCode = clientCode
        self.clientName = clientName
        self.api = api
        self.repo = StatementRepository(database: database)
        self.isOnline = isOnline
        self.onUnauthorized = onUnauthorized
    }

    var hasCache: Bool { !documents.isEmpty }
    var invoices: [StatementDocument] { documents.filter { $0.openAmount >= 0 } }
    var credits: [StatementDocument] { documents.filter { $0.openAmount < 0 } }

    /// Al abrir: pinta la caché y, si hay red, refresca.
    func appear() async {
        loadCache()
        if isOnline() { await refresh() }
    }

    /// Descarga el estado de cuenta y reemplaza la caché. Sin red o ante error de red,
    /// conserva lo que hubiera (marca que está mostrando una foto vieja).
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let statement = try await api.fetchStatement(clientCode: clientCode)
            try repo.save(statement)
            showingStale = false
            loadCache()
        } catch APIError.unauthorized {
            onUnauthorized()
            showingStale = hasCache
        } catch {
            // Sin conexión / error de red: se mantiene la caché (offline-first).
            showingStale = hasCache
            AppLog.sync.warning("statement \(self.clientCode, privacy: .public): no se pudo refrescar")
        }
    }

    private func loadCache() {
        documents = (try? repo.documents(clientCode: clientCode)) ?? []
        asOf = (try? repo.asOf(clientCode: clientCode)) ?? asOf
    }
}
