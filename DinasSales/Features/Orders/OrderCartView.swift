import SwiftUI

/// Carrito de una orden (borrador): agrega ítems, ajusta cantidad, **lista de precio por
/// línea** y descuento de línea; guarda como borrador o confirma. `unit_price` toma el
/// precio del ítem en la lista elegida (0 es válido y ordenable).
struct OrderCartView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel: OrderCartViewModel
    /// Se llama al confirmar o guardar, para que el flujo padre cierre y refresque.
    let onFinish: () -> Void

    @State private var showItemPicker = false
    @State private var showDiscardConfirm = false
    /// Advertencia de retención pendiente de mostrar (nil = nada que advertir).
    @State private var pendingHoldWarning: HoldWarning?

    init(order: Order, clientName: String, database: AppDatabase, onFinish: @escaping () -> Void) {
        // Política de precios: solo Lista 3 (+ Lista 2 si está autorizada). Nunca Lista 1.
        let client = try? ClientsRepository(database: database).client(code: order.clientCode)
        let authorized = client?.authorizedPriceLists ?? []
        let sapDefault = client?.defaultPriceList ?? 0
        _viewModel = StateObject(wrappedValue: OrderCartViewModel(
            order: order,
            clientName: clientName,
            authorizedPriceLists: PriceListPolicy.visibleLists(authorized: authorized),
            defaultPriceList: PriceListPolicy.addList(authorized: authorized, defaultList: sapDefault),
            credit: client?.credit ?? .zero,
            orders: OrdersRepository(database: database),
            catalog: CatalogRepository(database: database)
        ))
        self.onFinish = onFinish
    }

    var body: some View {
        List {
            Section {
                if viewModel.rows.isEmpty {
                    Text("Carrito vacío. Agrega ítems.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.normalRows) { row in
                        CartRowView(
                            row: row,
                            authorizedPriceLists: viewModel.authorizedPriceLists,
                            canChoosePriceList: viewModel.canChoosePriceList,
                            onQuantity: { viewModel.setQuantity(row, quantity: $0) },
                            onPriceList: { viewModel.setPriceList(row, priceList: $0) }
                        )
                    }
                }
            } header: {
                Text(viewModel.clientName)
            } footer: {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }

            // ★ v0.28.0 — Un Section por bloque de promoción. Inmutable: líneas solo-lectura y una
            // acción para quitar el bloque completo (no se editan líneas sueltas).
            ForEach(viewModel.promotionBlocks, id: \.groupId) { block in
                Section {
                    ForEach(block.rows) { row in PromoBlockRow(row: row) }
                    Button(role: .destructive) {
                        viewModel.removePromotion(groupId: block.groupId)
                    } label: {
                        Label("Quitar promoción", systemImage: "trash")
                    }
                } header: {
                    Label(block.title, systemImage: "tag.fill")
                        .foregroundStyle(.tint)
                }
            }

            Section {
                HStack {
                    Text("Total").font(.headline)
                    Spacer()
                    Text(MoneyFormat.string(viewModel.total)).font(.headline)
                }
            }

            Section {
                Button(role: .destructive) {
                    showDiscardConfirm = true
                } label: {
                    Label("Descartar borrador", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Orden")
        .navigationBarTitleDisplayModeInlineCompat()
        .confirmationDialog("¿Descartar este borrador?", isPresented: $showDiscardConfirm,
                            titleVisibility: .visible) {
            Button("Descartar borrador", role: .destructive) {
                if viewModel.discard() { onFinish() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se eliminará la orden y sus líneas. Esta acción no se puede deshacer.")
        }
        // ★ "Agregar ítems" va en el BODY, no en la toolbar: en `.primaryAction` el Label
        // colapsa a solo-ícono (mismo bug ya validado). Como botón prominente el texto se ve.
        .safeAreaInset(edge: .bottom) {
            Button {
                showItemPicker = true
            } label: {
                Label("Agregar ítems", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Confirmar") {
                    // La app ADVIERTE si la orden quedará retenida, pero NO bloquea:
                    // si hay aviso, se muestra y el vendedor decide; si no, confirma directo.
                    if let warning = viewModel.holdWarning {
                        pendingHoldWarning = warning
                    } else {
                        confirmOrder()
                    }
                }
                .disabled(viewModel.rows.isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                // El borrador ya está persistido; "Guardar" solo cierra el flujo.
                Button("Guardar borrador") { onFinish() }
            }
        }
        .sheet(isPresented: $showItemPicker) {
            ItemPickerView(
                database: environment.database,
                priceLists: viewModel.authorizedPriceLists,   // visibles: [3] o [2,3]
                addList: viewModel.defaultPriceList,           // con la que se agrega
                quantities: viewModel.quantitiesByItem,
                onSetQuantity: { item, qty in viewModel.setQuantity(item: item, quantity: qty) },
                promotionsAPI: environment.api,
                isOnline: { environment.network.isOnline },
                onAddPromotion: { title, groupId, lines in
                    viewModel.addPromotion(title: title, groupId: groupId, lines: lines)
                }
            )
        }
        // Advertencia de retención por cartera. Es un AVISO, no un bloqueo: el vendedor
        // puede tomar la orden igual (quizá ya habló con la oficina, o el cliente paga hoy).
        .confirmationDialog(
            "Aviso de cartera",
            isPresented: Binding(get: { pendingHoldWarning != nil },
                                 set: { if !$0 { pendingHoldWarning = nil } }),
            titleVisibility: .visible,
            presenting: pendingHoldWarning
        ) { _ in
            Button("Confirmar de todos modos") { confirmOrder() }
            Button("Revisar la orden", role: .cancel) { pendingHoldWarning = nil }
        } message: { warning in
            Text(warning.message)
        }
        .task { viewModel.reload() }
    }

    /// Confirma y cierra el flujo. Se llama directo o tras aceptar la advertencia.
    private func confirmOrder() {
        pendingHoldWarning = nil
        if viewModel.confirm() { onFinish() }
    }
}

/// Fila de solo-lectura de una línea de promoción (el bloque es inmutable).
private struct PromoBlockRow: View {
    let row: CartRow

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(MoneyFormat.string(row.lineTotal)).font(.callout.weight(.semibold))
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        let qty = "×\(row.quantity.formatted())"
        if row.discountPct >= 100 { return "\(qty) · Gratis" }
        if row.discountPct > 0 { return "\(qty) · \(row.discountPct.formatted())% dcto" }
        return "\(qty) · \(MoneyFormat.string(row.unitPrice)) c/u"
    }
}

/// Fila de línea: nombre, precio, stepper de cantidad, lista de precio y descuento.
private struct CartRowView: View {
    let row: CartRow
    let authorizedPriceLists: [Int]
    let canChoosePriceList: Bool
    let onQuantity: (Double) -> Void
    let onPriceList: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.body.weight(.medium))
                    Text("\(row.itemCode) · \(MoneyFormat.string(row.unitPrice)) c/u")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(MoneyFormat.string(row.lineTotal)).font(.callout.weight(.semibold))
            }

            // El descuento por línea está OCULTO por ahora (line_discount_pct sigue viajando
            // en el contrato como 0). Se re-habilitará por ítem cuando exista el módulo de
            // promociones (el admin fijará un descuento MÁXIMO por ítem desde el Dashboard).
            HStack(spacing: 16) {
                Stepper(value: Binding(
                    get: { row.quantity },
                    set: { onQuantity($0) }
                ), in: 0...100_000, step: 1) {
                    Text("Cant: \(row.quantity.formatted())")
                        .font(.subheadline)
                }
            }

            availabilityNote

            // Selector de lista de precio (solo si el cliente tiene más de una autorizada).
            if canChoosePriceList {
                Picker("Lista", selection: Binding(
                    get: { row.priceList },
                    set: { onPriceList($0) }
                )) {
                    ForEach(authorizedPriceLists, id: \.self) { list in
                        Text("Lista \(list)").tag(list)
                    }
                }
                .pickerStyle(.segmented)
            } else {
                Text("Lista \(row.priceList)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .swipeActions {
            Button(role: .destructive) { onQuantity(0) } label: {
                Label("Quitar", systemImage: "trash")
            }
        }
    }

    /// Disponibilidad de la línea (foto de la última sincronización). Si lo pedido excede lo
    /// disponible, se marca en rojo con advertencia — AVISA, no bloquea (el middleware decide).
    @ViewBuilder private var availabilityNote: some View {
        if row.exceedsAvailable {
            Label("Pediste \(row.quantity.formatted()) y hay \(row.available.formatted()) disponibles",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        } else {
            Text("Disponible: \(row.available.formatted()) · según última sincronización")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
