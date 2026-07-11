import SwiftUI

/// Carrito de una orden (borrador): agrega ítems, ajusta cantidad y descuento de línea,
/// guarda como borrador o confirma. `unit_price` viene del catálogo (no editable).
struct OrderCartView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel: OrderCartViewModel
    /// Se llama al confirmar o guardar, para que el flujo padre cierre y refresque.
    let onFinish: () -> Void

    @State private var showItemPicker = false

    init(order: Order, clientName: String, database: AppDatabase, onFinish: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: OrderCartViewModel(
            order: order,
            clientName: clientName,
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
                            onQuantity: { viewModel.setQuantity(itemCode: row.itemCode, quantity: $0) },
                            onDiscount: { viewModel.setDiscount(itemCode: row.itemCode, percent: $0) }
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
        }
        .navigationTitle("Orden")
        .navigationBarTitleDisplayModeInlineCompat()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showItemPicker = true
                } label: {
                    Label("Agregar", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Confirmar") {
                    if viewModel.confirm() { onFinish() }
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
                quantities: Dictionary(uniqueKeysWithValues: viewModel.rows.map { ($0.itemCode, $0.quantity) }),
                onAdd: { viewModel.addOne($0) }
            )
        }
        .task { viewModel.reload() }
    }
}

/// Fila de línea: nombre, precio, stepper de cantidad y descuento de línea (%).
private struct CartRowView: View {
    let row: CartRow
    let onQuantity: (Double) -> Void
    let onDiscount: (Double) -> Void

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
