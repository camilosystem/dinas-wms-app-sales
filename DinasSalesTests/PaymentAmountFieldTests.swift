import XCTest
@testable import DinasSales

/// Auto-relleno del campo "Monto pagado" desde la selección de facturas, con la regla de que una
/// edición manual "adueña" el campo y ya no se sobrescribe.
final class PaymentAmountFieldTests: XCTestCase {

    func test_seleccionar2Facturas_autoPueblaLaSuma() {
        var field = PaymentAmountField()
        field.selectionChanged(selectedSum: 100)             // 1 factura marcada
        XCTAssertEqual(field.amount, 100)
        field.selectionChanged(selectedSum: 100 + 55.25)     // se marca una 2ª
        XCTAssertEqual(field.amount, 155.25, "auto-puebla con la suma de las 2 seleccionadas")
        XCTAssertFalse(field.manuallyEdited)
    }

    func test_editarMontoAmano_luegoSeleccionarOtra_noSobrescribe() {
        var field = PaymentAmountField()
        field.selectionChanged(selectedSum: 155.25)          // auto-poblado
        field.userEdited(150)                                 // pago parcial escrito a mano
        XCTAssertEqual(field.amount, 150)
        XCTAssertTrue(field.manuallyEdited)

        field.selectionChanged(selectedSum: 230)              // marca otra factura después
        XCTAssertEqual(field.amount, 150, "no sobrescribe lo que el vendedor escribió a mano")
    }

    func test_deseleccionarTodo_vuelveACero_ySiguePudiendoAutoPoblar() {
        var field = PaymentAmountField()
        field.selectionChanged(selectedSum: 100)
        field.selectionChanged(selectedSum: 0)                // se deseleccionó todo
        XCTAssertEqual(field.amount, 0)
        field.selectionChanged(selectedSum: 80)               // vuelve a marcar algo
        XCTAssertEqual(field.amount, 80, "sin edición manual, sigue auto-poblándose")
    }
}
