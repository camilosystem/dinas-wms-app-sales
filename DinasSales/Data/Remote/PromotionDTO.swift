import Foundation

// Modelos del libro de promociones (★ v0.28.0). Se consultan EN VIVO contra el middleware
// (GET /promotions, ya filtrado por el server: solo activas, vigentes y asignadas al vendedor).
// No se persisten: la promoción se consulta con conexión; el bloque resultante SÍ se encola
// offline como líneas normales del carrito, con su promotion_group_id.

/// Tipo de promoción. FREE_ITEMS → beneficios con discount_pct=100. DISCOUNTED_ITEMS → cada
/// beneficio con su propio discount_pct.
enum PromotionType: String, Codable, Equatable {
    case freeItems = "FREE_ITEMS"
    case discountedItems = "DISCOUNTED_ITEMS"

    var label: String {
        switch self {
        case .freeItems: return "Gratis"
        case .discountedItems: return "Con descuento"
        }
    }
}

/// Vista resumida para la grilla del libro (`PromotionSummary`).
struct PromotionSummary: Decodable, Identifiable, Equatable {
    let promotionId: String
    let title: String
    let type: PromotionType

    var id: String { promotionId }

    enum CodingKeys: String, CodingKey {
        case promotionId = "promotion_id"
        case title, type
    }
}

/// Ítem de condición: se compra a precio completo; `minQuantity` es el mínimo requerido.
struct PromotionConditionItem: Decodable, Equatable {
    let itemCode: String
    let minQuantity: Double

    enum CodingKeys: String, CodingKey {
        case itemCode = "item_code"
        case minQuantity = "min_quantity"
    }
}

/// Ítem de beneficio: se agrega con `discountPct` (100 si FREE_ITEMS). `quantity` es el mínimo.
struct PromotionBenefitItem: Decodable, Equatable {
    let itemCode: String
    let quantity: Double
    let discountPct: Double

    enum CodingKeys: String, CodingKey {
        case itemCode = "item_code"
        case quantity
        case discountPct = "discount_pct"
    }
}

/// Detalle completo (`PromotionDetail`): condición + beneficio.
struct PromotionDetail: Decodable, Identifiable, Equatable {
    let promotionId: String
    let title: String
    let type: PromotionType
    let conditionItems: [PromotionConditionItem]
    let benefitItems: [PromotionBenefitItem]

    var id: String { promotionId }

    enum CodingKeys: String, CodingKey {
        case promotionId = "promotion_id"
        case title, type
        case conditionItems = "condition_items"
        case benefitItems = "benefit_items"
    }
}

/// Envoltorio de `GET /promotions`.
struct PromotionsResponse: Decodable {
    let promotions: [PromotionSummary]
}
