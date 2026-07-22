import Foundation

/// Una línea del carrito lista para mostrar (línea + nombre del ítem + total).
struct CartRow: Identifiable, Equatable {
    let lineId: Int64
    let itemCode: String
    let name: String
    let quantity: Double
    let unitPrice: Double
    let priceList: Int
    let discountPct: Double
    /// Disponible del ítem según la ÚLTIMA sincronización (foto, no tiempo real).
    let available: Double
    var id: Int64 { lineId }
    var lineTotal: Double { quantity * unitPrice * (1 - discountPct / 100) }
    /// Pidió más de lo que había disponible en la última sincronización → advertir (no bloquea).
    var exceedsAvailable: Bool { quantity > available }
}

/// Estado del carrito de UNA orden (borrador) para un cliente.
///
/// El vendedor elige la lista de precio POR LÍNEA, solo entre las autorizadas del cliente.
/// Si el cliente tiene una sola lista autorizada, no hay selector (se usa esa).
@MainActor
final class OrderCartViewModel: ObservableObject {
    let order: Order
    let clientName: String
    /// Listas que el vendedor puede usar con este cliente (1 o 2).
    let authorizedPriceLists: [Int]
    let defaultPriceList: Int
    /// Cartera del cliente (última sync), para ADVERTIR si la orden quedará retenida.
    let credit: ClientCredit

    @Published private(set) var rows: [CartRow] = []
    @Published private(set) var total: Double = 0
    @Published var errorMessage: String?

    private let orders: OrdersRepository
    private let catalog: CatalogRepository

    var canChoosePriceList: Bool { authorizedPriceLists.count > 1 }

    init(order: Order, clientName: String,
         authorizedPriceLists: [Int], defaultPriceList: Int,
         credit: ClientCredit = .zero,
         orders: OrdersRepository, catalog: CatalogRepository) {
        self.order = order
        self.clientName = clientName
        self.authorizedPriceLists = authorizedPriceLists.isEmpty ? [defaultPriceList] : authorizedPriceLists
        self.defaultPriceList = defaultPriceList
        self.credit = credit
        self.orders = orders
        self.catalog = catalog
    }

    /// Advertencia de retención según los datos locales, o `nil` si la orden no se
    /// retendría. INFORMATIVA: nunca impide confirmar (la app advierte, el server decide).
    var holdWarning: HoldWarning? {
        HoldWarning.evaluate(credit: credit, orderTotal: total)
    }

    /// Recarga las líneas desde la base y recalcula el total.
    func reload() {
        do {
            let lines = try orders.lines(orderUUID: order.clientUUID)
            rows = try lines.map { line in
                let item = try catalog.item(code: line.itemCode)
                return CartRow(lineId: line.id ?? 0, itemCode: line.itemCode,
                               name: item?.name ?? line.itemCode,
                               quantity: line.quantity, unitPrice: line.unitPrice,
                               priceList: line.priceList, discountPct: line.lineDiscountPct,
                               available: item?.available ?? 0)
            }
            total = rows.reduce(0) { $0 + $1.lineTotal }
            errorMessage = nil
        } catch {
            errorMessage = "No se pudo cargar el carrito."
        }
    }

    /// Cantidades en el carrito por ítem (todas las listas), para el contador del picker.
    var quantitiesByItem: [String: Double] {
        rows.reduce(into: [:]) { $0[$1.itemCode, default: 0] += $1.quantity }
    }

    /// Añade un ítem con la lista por defecto del cliente (o suma 1 si ya está en esa lista).
    func addOne(_ item: Item) { add(item, quantity: 1) }

    /// Añade `quantity` unidades del ítem con la lista por defecto (suma a lo ya existente en
    /// esa lista). Ignora cantidades ≤ 0: nunca crea una línea vacía.
    func add(_ item: Item, quantity: Double) {
        guard quantity > 0 else { return }
        let current = rows.first { $0.itemCode == item.itemCode && $0.priceList == defaultPriceList }?.quantity ?? 0
        write { try orders.setQuantity(orderUUID: order.clientUUID, itemCode: item.itemCode,
                                       priceList: defaultPriceList, quantity: current + quantity) }
    }

    /// Fija la cantidad ABSOLUTA del ítem en la lista por defecto (para el stepper del picker,
    /// que edita el carrito directamente). En 0 quita la línea; si no existía y es > 0, la crea.
    func setQuantity(item: Item, quantity: Double) {
        let existing = rows.first { $0.itemCode == item.itemCode && $0.priceList == defaultPriceList }
        if quantity <= 0 {
            if let existing { write { try orders.removeLine(lineId: existing.lineId) } }
        } else {
            write { try orders.setQuantity(orderUUID: order.clientUUID, itemCode: item.itemCode,
                                           priceList: defaultPriceList, quantity: quantity) }
        }
    }

    func setQuantity(_ row: CartRow, quantity: Double) {
        if quantity <= 0 {
            write { try orders.removeLine(lineId: row.lineId) }
        } else {
            write { try orders.setQuantity(orderUUID: order.clientUUID, itemCode: row.itemCode,
                                           priceList: row.priceList, quantity: quantity) }
        }
    }

    func setDiscount(_ row: CartRow, percent: Double) {
        write { try orders.setDiscount(lineId: row.lineId, percent: percent) }
    }

    func setPriceList(_ row: CartRow, priceList: Int) {
        write { try orders.setPriceList(lineId: row.lineId, priceList: priceList) }
    }

    /// Descarta el borrador (y sus líneas). Devuelve `true` si se eliminó.
    func discard() -> Bool {
        do {
            try orders.deleteDraft(orderUUID: order.clientUUID)
            return true
        } catch {
            errorMessage = "No se pudo descartar el borrador."
            return false
        }
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
