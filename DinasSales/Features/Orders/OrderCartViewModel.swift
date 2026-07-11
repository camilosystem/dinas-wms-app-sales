import Foundation

/// Una línea del carrito lista para mostrar (línea + nombre del ítem + total).
struct CartRow: Identifiable, Equatable {
    let itemCode: String
    let name: String
    let quantity: Double
    let unitPrice: Double
    let discountPct: Double
    var id: String { itemCode }
    var lineTotal: Double { quantity * unitPrice * (1 - discountPct / 100) }
}

/// Estado del carrito de UNA orden (borrador) para un cliente.
@MainActor
final class OrderCartViewModel: ObservableObject {
    let order: Order
    let clientName: String

    @Published private(set) var rows: [CartRow] = []
    @Published private(set) var total: Double = 0
    @Published var errorMessage: String?

    private let orders: OrdersRepository
    private let catalog: CatalogRepository

    init(order: Order, clientName: String,
         orders: OrdersRepository, catalog: CatalogRepository) {
        self.order = order
        self.clientName = clientName
        self.orders = orders
        self.catalog = catalog
    }

    /// Recarga las líneas desde la base y recalcula el total.
    func reload() {
        do {
            let lines = try orders.lines(orderUUID: order.clientUUID)
            rows = try lines.map { line in
                let name = try catalog.item(code: line.itemCode)?.name ?? line.itemCode
                return CartRow(itemCode: line.itemCode, name: name, quantity: line.quantity,
                               unitPrice: line.unitPrice, discountPct: line.lineDiscountPct)
            }
            total = rows.reduce(0) { $0 + $1.lineTotal }
            errorMessage = nil
        } catch {
            errorMessage = "No se pudo cargar el carrito."
        }
    }

    /// Añade un ítem (o suma 1 a su cantidad si ya está).
    func addOne(_ item: Item) {
        let current = rows.first(where: { $0.itemCode == item.itemCode })?.quantity ?? 0
        setQuantity(itemCode: item.itemCode, quantity: current + 1)
    }

    func setQuantity(itemCode: String, quantity: Double) {
        write { try orders.setQuantity(orderUUID: order.clientUUID, itemCode: itemCode, quantity: quantity) }
    }

    func setDiscount(itemCode: String, percent: Double) {
        write { try orders.setDiscount(orderUUID: order.clientUUID, itemCode: itemCode, percent: percent) }
    }

    /// Confirma la orden. Devuelve `true` si pasó a confirmada.
    func confirm() -> Bool {
        do {
            try orders.confirm(orderUUID: order.clientUUID)
            return true
        } catch OrdersError.emptyOrder {
            errorMessage = "Agrega al menos un ítem antes de confirmar."
            return false
        } catch {
            errorMessage = "No se pudo confirmar la orden."
            return false
        }
    }

    private func write(_ action: () throws -> Void) {
        do {
            try action()
            reload()
        } catch {
            errorMessage = "No se pudo actualizar el carrito."
        }
    }
}
