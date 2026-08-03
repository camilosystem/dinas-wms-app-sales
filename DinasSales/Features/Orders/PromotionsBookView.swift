import SwiftUI

/// Libro de promociones del vendedor (★ v0.28.0). Se abre desde "Agregar ítems". Consulta
/// `GET /promotions` EN VIVO (requiere conexión; el server ya filtra por activas/vigentes/
/// asignadas). Grilla de tarjetas con búsqueda por `?q=`; al abrir una, configura las cantidades
/// y agrega el bloque completo al carrito.
struct PromotionsBookView: View {
    let api: PromotionsAPI
    let database: AppDatabase
    /// Lista de precio con la que se costean las líneas del bloque (la del carrito).
    let addList: Int
    let isOnline: () -> Bool
    /// Al confirmar un bloque: (título, promotion_group_id, líneas). Cierra el libro.
    let onAddPromotion: (String, String, [PromotionLineInput]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var promotions: [PromotionSummary] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                content
            }
            .navigationTitle("Promociones")
            .navigationBarTitleDisplayModeInlineCompat()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { dismiss() } }
            }
            .task { await load() }
        }
    }

    @ViewBuilder private var content: some View {
        if !isOnline() {
            ContentUnavailableViewCompat(
                title: "Sin conexión",
                message: "Las promociones se consultan en línea. Conéctate para ver el libro.",
                systemImage: "wifi.slash").frame(maxHeight: .infinity)
        } else if loading && promotions.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, promotions.isEmpty {
            ContentUnavailableViewCompat(title: "No se pudo cargar", message: errorMessage,
                                         systemImage: "exclamationmark.triangle").frame(maxHeight: .infinity)
        } else if promotions.isEmpty {
            ContentUnavailableViewCompat(
                title: query.isEmpty ? "Sin promociones" : "Sin resultados",
                message: query.isEmpty ? "No tienes promociones asignadas y vigentes."
                                       : "Ninguna promoción coincide con la búsqueda.",
                systemImage: "tag").frame(maxHeight: .infinity)
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(promotions) { promo in
                    NavigationLink {
                        PromotionDetailView(api: api, database: database, summary: promo,
                                            addList: addList) { title, groupId, lines in
                            onAddPromotion(title, groupId, lines)
                            dismiss()
                        }
                    } label: {
                        PromotionCard(promo: promo)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Buscar por título, código o ítem", text: $query)
                .autocorrectionDisabled()
                .onChange(of: query) { _ in debouncedSearch() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal).padding(.top, 8).padding(.bottom, 4)
    }

    private func debouncedSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await load()
        }
    }

    private func load() async {
        guard isOnline() else { return }
        loading = true; errorMessage = nil
        defer { loading = false }
        do {
            promotions = try await api.fetchPromotions(query: query.isEmpty ? nil : query)
        } catch {
            errorMessage = "No se pudieron cargar las promociones. Revisa la conexión."
        }
    }
}

/// Tarjeta de la grilla: título + tipo.
private struct PromotionCard: View {
    let promo: PromotionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: promo.type == .freeItems ? "gift.fill" : "tag.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text(promo.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Text(promo.type.label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
                .foregroundStyle(Color.accentColor)
        }
        .padding(12)
        .frame(height: 140, alignment: .topLeading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Detalle de una promoción: configura cantidades de condición (mín. `min_quantity`) y de
/// beneficio (mín. la cantidad de la promo), y agrega el bloque completo al carrito con un
/// `promotion_group_id` nuevo. "Agregar al carrito" se habilita solo con todas las condiciones
/// mínimas cumplidas.
struct PromotionDetailView: View {
    let api: PromotionsAPI
    let database: AppDatabase
    let summary: PromotionSummary
    let addList: Int
    let onConfirm: (String, String, [PromotionLineInput]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var detail: PromotionDetail?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var conditionQty: [String: Double] = [:]
    @State private var benefitQty: [String: Double] = [:]

    var body: some View {
        Group {
            if let detail {
                form(detail)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableViewCompat(title: "No disponible",
                    message: errorMessage ?? "No se pudo cargar la promoción.",
                    systemImage: "tag.slash").frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(summary.title)
        .navigationBarTitleDisplayModeInlineCompat()
        .task { await load() }
    }

    private func form(_ detail: PromotionDetail) -> some View {
        Form {
            Section {
                ForEach(detail.conditionItems, id: \.itemCode) { item in
                    qtyRow(code: item.itemCode,
                           subtitle: "Mínimo \(item.minQuantity.formatted())",
                           quantity: conditionQty[item.itemCode] ?? item.minQuantity,
                           min: 0,
                           belowMin: (conditionQty[item.itemCode] ?? item.minQuantity) < item.minQuantity) {
                        conditionQty[item.itemCode] = $0
                    }
                }
            } header: {
                Text("Condición — a precio completo")
            } footer: {
                Text("Configura las cantidades a precio completo. Deben cumplir el mínimo de cada ítem para habilitar el beneficio.")
            }

            Section {
                ForEach(detail.benefitItems, id: \.itemCode) { item in
                    qtyRow(code: item.itemCode,
                           subtitle: item.discountPct >= 100 ? "Gratis"
                                                             : "\(item.discountPct.formatted())% dcto",
                           quantity: benefitQty[item.itemCode] ?? item.quantity,
                           min: item.quantity,
                           belowMin: false) {
                        benefitQty[item.itemCode] = $0
                    }
                }
            } header: {
                Text(detail.type == .freeItems ? "Beneficio — gratis" : "Beneficio — con descuento")
            }

            Section {
                Button {
                    confirm(detail)
                } label: {
                    Text("Agregar al carrito").frame(maxWidth: .infinity)
                }
                .disabled(!canAdd(detail))
            } footer: {
                if !canAdd(detail) {
                    Text("Cumple las cantidades mínimas de condición para agregar la promoción.")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func qtyRow(code: String, subtitle: String, quantity: Double, min: Double,
                        belowMin: Bool, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(itemName(code)).font(.body.weight(.medium))
            Text("\(code) · \(subtitle)")
                .font(.caption)
                .foregroundStyle(belowMin ? .orange : .secondary)
            Stepper(value: Binding(get: { quantity }, set: { set(Swift.max(min, $0)) }),
                    in: min...1_000_000, step: 1) {
                Text("Cantidad: \(quantity.formatted())").font(.subheadline)
            }
        }
        .padding(.vertical, 2)
    }

    /// Habilitado solo si cada ítem de condición cumple su cantidad mínima.
    private func canAdd(_ detail: PromotionDetail) -> Bool {
        detail.conditionItems.allSatisfy {
            (conditionQty[$0.itemCode] ?? $0.minQuantity) >= $0.minQuantity
        }
    }

    private func confirm(_ detail: PromotionDetail) {
        var lines: [PromotionLineInput] = []
        for item in detail.conditionItems {
            let qty = conditionQty[item.itemCode] ?? item.minQuantity
            lines.append(PromotionLineInput(itemCode: item.itemCode, quantity: qty, discountPct: 0))
        }
        for item in detail.benefitItems {
            let qty = benefitQty[item.itemCode] ?? item.quantity
            lines.append(PromotionLineInput(itemCode: item.itemCode, quantity: qty,
                                            discountPct: item.discountPct))
        }
        onConfirm(detail.title, UUID().uuidString, lines)
        dismiss()
    }

    private func itemName(_ code: String) -> String {
        let item = (try? CatalogRepository(database: database).item(code: code)) ?? nil
        return item?.name ?? code
    }

    private func load() async {
        loading = true; errorMessage = nil
        defer { loading = false }
        do { detail = try await api.fetchPromotion(id: summary.promotionId) }
        catch { errorMessage = "No se pudo cargar la promoción." }
    }
}
