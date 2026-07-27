import Foundation

/// Modela el campo "Monto pagado" de Reportar Pago con auto-relleno desde las facturas
/// seleccionadas.
///
/// Regla: mientras el vendedor NO edite el monto a mano, cada cambio de selección de facturas lo
/// auto-puebla con la suma de las seleccionadas (comodidad, no campo de solo lectura). En cuanto
/// el vendedor lo escribe a mano (p. ej. un pago parcial que no cuadra con la suma exacta), el
/// campo pasa a ser "suyo" y la selección ya no lo sobrescribe — hasta que se reinicie el
/// formulario (una instancia nueva). Se extrae de la vista para poder testear la máquina de estado.
struct PaymentAmountField: Equatable {
    private(set) var amount: Double = 0
    /// True una vez que el vendedor escribió el monto directamente.
    private(set) var manuallyEdited = false

    /// El vendedor escribió el monto → el campo queda bajo su control.
    mutating func userEdited(_ value: Double) {
        amount = value
        manuallyEdited = true
    }

    /// Cambió la selección de facturas: auto-puebla con la suma, salvo que ya se haya editado a
    /// mano. Si `selectedSum` es 0 (nada seleccionado), el campo vuelve a 0, listo para auto-
    /// poblarse de nuevo.
    mutating func selectionChanged(selectedSum: Double) {
        guard !manuallyEdited else { return }
        amount = selectedSum
    }
}
