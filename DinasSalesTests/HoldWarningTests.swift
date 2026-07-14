import XCTest
@testable import DinasSales

/// La app ADVIERTE, el middleware DECIDE. Estos tests fijan la regla local de advertencia
/// y, sobre todo, que la app NO recalcula el umbral de días de gracia (usa `has_overdue`).
final class HoldWarningTests: XCTestCase {

    private func credit(balance: Double = 0, limit: Double = 1_000, available: Double? = nil,
                        overdueCount: Int = 0, overdueAmount: Double = 0,
                        maxDaysOverdue: Int = 0, hasOverdue: Bool = false,
                        graceDays: Int = 5) -> ClientCredit {
        ClientCredit(balance: balance, creditLimit: limit,
                     creditAvailable: available ?? (limit - balance),
                     overdueCount: overdueCount, overdueAmount: overdueAmount,
                     maxDaysOverdue: maxDaysOverdue, hasOverdue: hasOverdue, graceDays: graceDays)
    }

    // MARK: - Regla de advertencia

    func test_clienteAlDia_dentroDeCupo_sinAdvertencia() {
        let c = credit(balance: 100, limit: 1_000, hasOverdue: false)
        XCTAssertNil(HoldWarning.evaluate(credit: c, orderTotal: 100),
                     "cliente al día y dentro de cupo: no se advierte")
    }

    func test_excedeCupo_advierte() {
        // balance 900 + orden 200 = 1100 > cupo 1000 → excede.
        let c = credit(balance: 900, limit: 1_000, hasOverdue: false)
        let w = HoldWarning.evaluate(credit: c, orderTotal: 200)
        XCTAssertNotNil(w)
        XCTAssertTrue(w!.exceedsCredit)
        XCTAssertFalse(w!.hasOverdue)
        XCTAssertTrue(w!.message.contains("cupo"))
    }

    func test_justoEnElCupo_noAdvierte() {
        // balance 800 + orden 200 = 1000, NO es > 1000 (regla con >).
        let c = credit(balance: 800, limit: 1_000, hasOverdue: false)
        XCTAssertNil(HoldWarning.evaluate(credit: c, orderTotal: 200))
    }

    func test_mora_advierteAunqueDentroDeCupo() {
        let c = credit(balance: 0, limit: 1_000, overdueCount: 3, overdueAmount: 4_500,
                       maxDaysOverdue: 20, hasOverdue: true)
        let w = HoldWarning.evaluate(credit: c, orderTotal: 10)
        XCTAssertNotNil(w)
        XCTAssertFalse(w!.exceedsCredit)
        XCTAssertTrue(w!.hasOverdue)
        XCTAssertTrue(w!.message.contains("3 facturas vencidas"))
    }

    func test_cupoYMora_advierteAmbos() {
        let c = credit(balance: 900, limit: 1_000, overdueCount: 1, overdueAmount: 500,
                       maxDaysOverdue: 10, hasOverdue: true)
        let w = HoldWarning.evaluate(credit: c, orderTotal: 300)
        XCTAssertNotNil(w)
        XCTAssertTrue(w!.exceedsCredit)
        XCTAssertTrue(w!.hasOverdue)
    }

    // MARK: - ★ La app NO recalcula el umbral de días de gracia

    func test_noRecalculaGracia_confiaEnHasOverdueFalse() {
        // 100 días de atraso PERO el servidor dice has_overdue=false (su umbral manda).
        // La app NO debe inventar mora recalculando 100 > 5.
        let c = credit(balance: 0, limit: 1_000, maxDaysOverdue: 100, hasOverdue: false)
        let w = HoldWarning.evaluate(credit: c, orderTotal: 10)
        XCTAssertNil(w, "si el servidor dice has_overdue=false, la app NO advierte mora")
    }

    func test_noRecalculaGracia_confiaEnHasOverdueTrue() {
        // Solo 2 días de atraso (por debajo de una gracia naíf de 5) pero el servidor dice
        // has_overdue=true. La app confía en el servidor y advierte.
        let c = credit(balance: 0, limit: 1_000, overdueCount: 1, overdueAmount: 100,
                       maxDaysOverdue: 2, hasOverdue: true)
        let w = HoldWarning.evaluate(credit: c, orderTotal: 10)
        XCTAssertNotNil(w, "si el servidor dice has_overdue=true, la app advierte")
        XCTAssertTrue(w!.hasOverdue)
    }

    // MARK: - Estado de cartera (indicador visual)

    func test_status_alDia() {
        XCTAssertEqual(credit(balance: 100, limit: 1_000, hasOverdue: false).status, .alDia)
    }

    func test_status_enMora() {
        XCTAssertEqual(credit(balance: 100, limit: 1_000, hasOverdue: true).status, .enMora)
    }

    func test_status_excedeCupo_tienePrioridad() {
        // cupo disponible negativo → excede, aunque también tenga mora.
        let c = credit(balance: 1_200, limit: 1_000, available: -200, hasOverdue: true)
        XCTAssertEqual(c.status, .excedeCupo)
    }
}
