import SwiftUI

/// Órdenes: toma de pedido (cliente asignado + carrito con cantidades y descuento de
/// línea), guardar borrador o confirmar, y estado local borrador → confirmada → sincronizada.
///
/// Esqueleto: pantalla base. El carrito y el ciclo de estados se implementan en la
/// iteración de Toma de orden.
struct OrdersView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableViewCompat(
                title: "Órdenes",
                message: "Toma de pedido offline: carrito, borrador y confirmar.",
                systemImage: "cart"
            )
            .navigationTitle("Órdenes")
        }
    }
}
