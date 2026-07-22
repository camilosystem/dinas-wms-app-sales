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
        // Listas de precio del cliente (para elegir por línea, solo entre las autorizadas).
        let client = try? ClientsRepository(database: database).client(code: order.clientCode)
        let authorized = client?.authorizedPriceLists ?? []
        let defaultList = client?.defaultPriceList ?? (authorized.first ?? 1)
        _viewModel = StateObject(wrappedValue: OrderCartViewModel(
            order: order,
            clientName: clientName,
            authorizedPriceLists: authorized,
            defaultPriceList: defaultList,
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
                    ForEach(viewModel.rows) { row in
                        CartRowView(
                            row: row,
                            authorizedPriceLists: viewModel.authorizedPriceLists,
                            canChoosePriceList: viewModel.canChoosePriceList,
                            onQuantity: { viewModel.setQuantity(row, quantity: $0) },
                            onDiscount: { viewModel.setDiscount(row, percent: $0) },
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
                priceList: viewModel.defaultPriceList,
                quantities: viewModel.quantitiesByItem,
                onAdd: { item, qty in viewModel.add(item, quantity: qty) }
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

/// Fila de línea: nombre, precio, stepper de cantidad, lista de precio y descuento.
private struct CartRowView: View {
    let row: CartRow
    let authorizedPriceLists: [Int]
    let canChoosePriceList: Bool
    let onQuantity: (Double) -> Void
    let onDiscount: (Double) -> Void
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

            HStack(spacing: 16) {
                Stepper(value: Binding(
                    get: { row.quantity },
                    set: { onQuantity($0) }
                ), in: 0...100_000, step: 1) {
                    Text("Cant: \(row.quantity.formatted())")
                        .font(.subheadline)
                }

                HStack(spacing: 4) {
                    Text("Desc %").font(.subheadline).foregroundStyle(.secondary)
                    TextField("0", value: Binding(
                        get: { row.discountPct },
                        set: { onDiscount($0) }
                    ), format: .number)
                    .frame(width: 48)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyleRoundedCompat()
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                }
            }

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
}

private extension View {
    /// `.textFieldStyle(.roundedBorder)` existe en iOS y macOS, pero lo aislamos por
    /// claridad del compat de plataforma.
    @ViewBuilder
    func textFieldStyleRoundedCompat() -> some View {
        self.textFieldStyle(.roundedBorder)
    }
}
