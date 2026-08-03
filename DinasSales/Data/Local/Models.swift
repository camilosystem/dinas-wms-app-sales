import Foundation
import GRDB

// Modelos de dominio persistidos en SQLite (GRDB).
//
// Los nombres de columna (CodingKeys en snake_case) coinciden con el contrato
// `openapi.yaml`: así el MISMO tipo sirve para decodificar el JSON del middleware y
// para persistir en la base local, sin capa de mapeo intermedia.

// MARK: - Item (catálogo)

/// Ítem del catálogo (schema `CatalogItem`, v0.3.0).
///
/// Trae los precios de las 3 listas (todos NO nullable; **0 es válido y ORDENABLE** —
/// muestras, publicidad, promociones). `has_price` es derivado (precio != 0) y solo es
/// informativo: NUNCA bloquea agregar al carrito. La app NO recalcula stock.
struct Item: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var itemCode: String        // PK; identificador del ítem
    var name: String
    var category: String?
    var barcode: String?
    var priceList1: Double      // precio en la lista 1 (0 = sin precio configurado, ordenable)
    var priceList2: Double
    var priceList3: Double
    var stock: Double?          // stock físico en SAP (informativo)
    var available: Double       // disponible ya calculado por el middleware
    var imageURL: String?       // descarga diferida; no viaja en el delta
    var active: Bool            // si false, la app no lo muestra

    var id: String { itemCode }

    static let databaseTableName = "items"

    enum CodingKeys: String, CodingKey {
        case itemCode = "item_code"
        case name, category, barcode
        case priceList1 = "price_list_1"
        case priceList2 = "price_list_2"
        case priceList3 = "price_list_3"
        case stock, available
        case imageURL = "image_url"
        case active
        // has_price_1/2/3 llegan en el JSON pero se DERIVAN de los precios (se ignoran).
    }

    /// Precio del ítem en la lista dada (1/2/3).
    func price(forList list: Int) -> Double {
        switch list {
        case 1: return priceList1
        case 2: return priceList2
        default: return priceList3
        }
    }

    /// ¿Hay precio configurado en esa lista? Informativo (precio 0 = sin configurar).
    func hasPrice(forList list: Int) -> Bool {
        price(forList: list) != 0
    }
}

/// Política de precios de la app de VENDEDOR (una sola fuente de verdad):
/// - La **Lista 1** NUNCA se muestra ni se usa, en ningún contexto.
/// - La **Lista 3** siempre está visible (lista pública, como el catálogo).
/// - La **Lista 2** solo si el cliente la tiene autorizada (contexto con cliente).
enum PriceListPolicy {
    /// Listas de precio VISIBLES/usables. `authorized` vacío = catálogo general (sin cliente)
    /// → solo Lista 3. Con cliente, se agrega la Lista 2 si está autorizada. Nunca la Lista 1.
    static func visibleLists(authorized: [Int]) -> [Int] {
        authorized.contains(2) ? [2, 3] : [3]
    }

    /// Lista con la que se AGREGA al carrito: Lista 2 si el cliente la tiene autorizada Y es su
    /// lista por defecto (`default_price_list`); si no, Lista 3. Nunca Lista 1.
    static func addList(authorized: [Int], defaultList: Int) -> Int {
        (authorized.contains(2) && defaultList == 2) ? 2 : 3
    }
}

// `active` NO está en el `required` del contrato: si el middleware lo omitiera, la
// decodificación sintetizada (que lo exige) tumbaría el catálogo ENTERO. Se decodifica con
// `decodeIfPresent` (default true: ausente → activo). Va en extensión para conservar el
// init por miembros (usado al construir Item en tests). Mismo patrón que Client/ClientCredit.
extension Item {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemCode = try c.decode(String.self, forKey: .itemCode)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        barcode = try c.decodeIfPresent(String.self, forKey: .barcode)
        priceList1 = try c.decode(Double.self, forKey: .priceList1)
        priceList2 = try c.decode(Double.self, forKey: .priceList2)
        priceList3 = try c.decode(Double.self, forKey: .priceList3)
        stock = try c.decodeIfPresent(Double.self, forKey: .stock)
        available = try c.decode(Double.self, forKey: .available)
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
    }
}

// MARK: - Client

/// Cliente asignado al vendedor (schema `Client`).
/// Solo se guardan los que devuelve `GET /sync/clients` (filtrados por token).
struct Client: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var clientCode: String      // PK
    var name: String
    var address: String?
    var city: String?
    var zipcode: String?
    var managerName: String?
    var shippingRoute: String?
    var defaultPriceList: Int   // lista por defecto (de SAP); siempre está en las autorizadas
    /// Listas que el vendedor PUEDE usar con este cliente (1 o 2). GRDB la persiste como
    /// JSON en su columna. El selector por línea solo ofrece estas.
    var authorizedPriceLists: [Int]
    /// Flag LOCAL (el servidor no lo envía): `false` = dado de baja en SAP pero conservado
    /// porque tiene órdenes locales. No se puede usar para pedidos nuevos.
    var active: Bool = true
    /// Situación de cartera (★ v0.4.0). GRDB la persiste como JSON en la columna `credit`.
    /// La app la usa para ADVERTIR offline; el middleware decide con datos frescos.
    var credit: ClientCredit = .zero
    /// Facturas abiertas del cliente (★ v0.17.5). GRDB la persiste como JSON en la columna
    /// `open_invoices`. Base para proponer imputaciones al reportar un pago de cartera.
    var openInvoices: [OpenInvoiceSummary] = []

    var id: String { clientCode }

    static let databaseTableName = "clients"

    enum CodingKeys: String, CodingKey {
        case clientCode = "client_code"
        case name, address, city, zipcode
        case managerName = "manager_name"
        case shippingRoute = "shipping_route"
        case defaultPriceList = "default_price_list"
        case authorizedPriceLists = "authorized_price_lists"
        case active
        case credit
        case openInvoices = "open_invoices"
    }
}

// MARK: - ClientCredit (cartera, ★ v0.4.0)

/// Situación de cartera del cliente (schema `ClientCredit`). Datos de la ÚLTIMA
/// sincronización: la app ADVIERTE con ellos, pero el middleware re-evalúa al recibir
/// la orden. `has_overdue` viene CALCULADO del servidor — la app NO recalcula el umbral
/// de días de gracia; solo muestra y usa lo que llega.
struct ClientCredit: Codable, Equatable {
    var balance: Double          // saldo actual (de SAP). ES LA CIFRA OFICIAL.
    var creditLimit: Double      // cupo de crédito
    var creditAvailable: Double  // credit_limit − balance. Puede ser NEGATIVO.
    var overdueCount: Int        // facturas vencidas (más allá de la gracia)
    var overdueAmount: Double    // monto total vencido
    var maxDaysOverdue: Int      // días de atraso de la factura más vencida
    /// Conveniencia del servidor: true si la mora supera los días de gracia.
    /// La app NO recalcula este umbral; lo usa tal cual.
    var hasOverdue: Bool
    var graceDays: Int           // días de gracia vigentes (informativo)

    enum CodingKeys: String, CodingKey {
        case balance
        case creditLimit = "credit_limit"
        case creditAvailable = "credit_available"
        case overdueCount = "overdue_count"
        case overdueAmount = "overdue_amount"
        case maxDaysOverdue = "max_days_overdue"
        case hasOverdue = "has_overdue"
        case graceDays = "grace_days"
    }

    /// Estado de cartera para el indicador visual. `excedeCupo` tiene prioridad sobre
    /// `enMora` solo para el color; el texto puede combinar ambos.
    enum Status { case alDia, enMora, excedeCupo }

    var status: Status {
        if creditAvailable < 0 { return .excedeCupo }
        if hasOverdue { return .enMora }
        return .alDia
    }

    /// Crédito en cero (cliente al día, sin cupo). Default para construir `Client` por
    /// miembros; los datos reales siempre lo sobrescriben al sincronizar.
    static let zero = ClientCredit(
        balance: 0, creditLimit: 0, creditAvailable: 0, overdueCount: 0,
        overdueAmount: 0, maxDaysOverdue: 0, hasOverdue: false, graceDays: 0
    )
}

// MARK: - OpenInvoiceSummary (facturas abiertas del cliente, ★ v0.17.5)

/// Factura abierta del cliente (schema `OpenInvoiceSummary`). Se sincroniza offline dentro de
/// `Client.open_invoices` para que el vendedor pueda proponer imputaciones (`proposed_applications`)
/// al reportar un pago de cartera SIN conexión. Como `credit`: dato de la ÚLTIMA sincronización,
/// puede estar desactualizado — el aprobador ve el estado fresco al confirmar la imputación real.
struct OpenInvoiceSummary: Codable, Equatable {
    var invoiceDocNum: String    // DocNum de la factura (vw_CxC)
    var amount: Double           // saldo ABIERTO de esa factura (no el total facturado)
    var invoiceDate: Date
    var dueDate: Date

    enum CodingKeys: String, CodingKey {
        case invoiceDocNum = "invoice_doc_num"
        case amount
        case invoiceDate = "invoice_date"
        case dueDate = "due_date"
    }
}

// Campos opcionales del contrato: los no-requeridos (`overdue_*`, `has_overdue`,
// `grace_days`) se decodifican con default 0/false para tolerar respuestas mínimas.
// Va en extensión para conservar el init por miembros (usado en tests y al construir).
extension ClientCredit {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        balance = try c.decode(Double.self, forKey: .balance)
        creditLimit = try c.decode(Double.self, forKey: .creditLimit)
        creditAvailable = try c.decode(Double.self, forKey: .creditAvailable)
        overdueCount = try c.decodeIfPresent(Int.self, forKey: .overdueCount) ?? 0
        overdueAmount = try c.decodeIfPresent(Double.self, forKey: .overdueAmount) ?? 0
        maxDaysOverdue = try c.decodeIfPresent(Int.self, forKey: .maxDaysOverdue) ?? 0
        hasOverdue = try c.decodeIfPresent(Bool.self, forKey: .hasOverdue) ?? false
        graceDays = try c.decodeIfPresent(Int.self, forKey: .graceDays) ?? 0
    }
}

// `active` es un flag LOCAL: el JSON del servidor no lo trae. Decodificamos con
// `decodeIfPresent` (default true) para que sirva tanto para el JSON del middleware
// (ausente → activo) como para la fila de la base (presente → su valor). Va en una
// extensión para NO perder el init por miembros (usado al construir Client).
extension Client {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientCode = try c.decode(String.self, forKey: .clientCode)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        city = try c.decodeIfPresent(String.self, forKey: .city)
        zipcode = try c.decodeIfPresent(String.self, forKey: .zipcode)
        managerName = try c.decodeIfPresent(String.self, forKey: .managerName)
        shippingRoute = try c.decodeIfPresent(String.self, forKey: .shippingRoute)
        defaultPriceList = try c.decode(Int.self, forKey: .defaultPriceList)
        authorizedPriceLists = try c.decode([Int].self, forKey: .authorizedPriceLists)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
        credit = try c.decode(ClientCredit.self, forKey: .credit)
        // Opcional en el contrato (ausente en clientes sin facturas abiertas) → [] tolerante.
        openInvoices = try c.decodeIfPresent([OpenInvoiceSummary].self, forKey: .openInvoices) ?? []
    }
}

// MARK: - Order (local)

/// Estado local de una orden: borrador → confirmada → sincronizada.
/// `rejected` = el middleware la rechazó con un error PERMANENTE (400/404): no se
/// reintenta; el vendedor debe corregirla o descartarla.
enum OrderStatus: String, Codable {
    case draft          // borrador
    case confirmed      // confirmada (taken_at), pendiente de subir
    case synced         // sincronizada con el middleware
    case rejected       // rechazada por error permanente (no se reintenta)
}

/// Veredicto de CARTERA que emite el middleware al recibir la orden (schema
/// `OrderStatus` del contrato v0.4.0). Es ORTOGONAL al ciclo local de envío
/// (`OrderStatus`): una orden `.synced` localmente puede estar APROBADA o RETENIDA.
/// `nil` hasta que la orden se envía. La app solo lo MUESTRA; no lo evalúa.
enum CreditVerdict: String, Codable {
    case sincronizada = "SINCRONIZADA"       // transitorio; el server la mueve enseguida
    case retenidaCartera = "RETENIDA_CARTERA" // excede cupo o mora; espera al admin
    case aprobada = "APROBADA"                // cartera OK o el admin la liberó
    case rechazada = "RECHAZADA"              // el admin la rechazó
}

/// Por qué se retuvo la orden (schema `HoldReason`). Presente solo si el veredicto
/// es `retenidaCartera`.
enum HoldReason: String, Codable {
    case cupoExcedido = "CUPO_EXCEDIDO"
    case mora = "MORA"
    case cupoYMora = "CUPO_Y_MORA"

    /// Texto para el vendedor.
    var label: String {
        switch self {
        case .cupoExcedido: return "Excede el cupo de crédito"
        case .mora: return "Tiene facturas vencidas"
        case .cupoYMora: return "Excede el cupo y tiene facturas vencidas"
        }
    }
}

/// Resultado de la ENTREGA de un pedido (schema `DeliveryStatus`, ★ v0.11.0). Lo registra
/// el admin en el Dashboard y baja vía GET /sync/orders. Conceptualmente `nil` y `.pendiente`
/// son DISTINTOS (nil = aún no salió el camión; PENDIENTE = ya va en ruta), pero ver más
/// abajo. La app solo lo MUESTRA. Decodificación tolerante: llega como `String?` en el DTO
/// (SyncDTO) y se mapea con `init(rawValue:)`, así un valor desconocido → nil (no revienta
/// el sync); el enum nunca se decodifica directo de la red.
enum DeliveryStatus: String, Codable {
    case pendiente = "PENDIENTE"                 // el camión salió, va en ruta
    case entregado = "ENTREGADO"                 // el cliente recibió todo
    case entregadoParcial = "ENTREGADO_PARCIAL"  // recibió, pero rechazó ítems
    case noEntregado = "NO_ENTREGADO"            // no recibió nada

    /// ¿Se le muestra al vendedor una sección/indicador de entrega? Todos los estados que
    /// emite el middleware se muestran: `.pendiente` → "En ruta" (★ activado: el middleware ya
    /// emite PENDIENTE, distingue "en ruta" de "aún no despachado"), y los terminales su
    /// resultado. Solo `nil` (sin registrar) no pinta nada, y eso se filtra antes (optional).
    var isResult: Bool { true }
}

/// Orden tomada por el vendedor. Modelo LOCAL; se transforma a `OrderCreate` al subir.
///
/// Nace con un `clientUUID` (UUID v4) generado en el dispositivo; ese UUID es la clave
/// de idempotencia hacia `POST /orders` y NO se regenera en reintentos.
struct Order: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var clientUUID: String      // UUID v4 local; clave de idempotencia (PK)
    var clientCode: String      // cliente asignado
    var status: OrderStatus
    var notes: String?
    var createdAt: Date         // creación del borrador (local)
    var takenAt: Date?          // momento en que se confirmó offline (taken_at del contrato)
    var syncedAt: Date?         // cuándo el middleware la aceptó
    var orderNumber: String?    // número interno devuelto por el middleware
    var rejectionReason: String? // motivo del error permanente (si status = .rejected)
    /// Veredicto de cartera del middleware (★ v0.4.0). `nil` hasta enviarse.
    /// Se ACTUALIZA en cada sync vía `GET /sync/orders` (★ v0.4.1): el admin pudo
    /// aprobar/rechazar después de enviada.
    var creditVerdict: CreditVerdict?
    /// Motivo de la retención (si `creditVerdict == .retenidaCartera`).
    var holdReason: HoldReason?
    /// Nota del aprobador o MOTIVO del rechazo (★ v0.4.1). El vendedor se lo explica al
    /// cliente. Presente cuando el admin ya decidió (aprobó/rechazó).
    var decisionNote: String?
    /// Cuándo el admin decidió (★ v0.4.1).
    var decidedAt: Date?
    /// Resultado de la ENTREGA (★ v0.11.0). `nil` mientras no se registre.
    var deliveryStatus: DeliveryStatus?
    /// Por qué no se entregó (o se entregó parcial), YA formateado por el middleware. Se
    /// muestra tal cual. `nil` si no aplica (entregado completo, o sin registrar).
    var deliveryReason: String?
    /// Cuándo se registró la entrega (★ v0.11.0).
    var deliveredAt: Date?

    var id: String { clientUUID }

    static let databaseTableName = "orders"

    enum CodingKeys: String, CodingKey {
        case clientUUID = "client_uuid"
        case clientCode = "client_code"
        case status, notes
        case createdAt = "created_at"
        case takenAt = "taken_at"
        case syncedAt = "synced_at"
        case orderNumber = "order_number"
        case rejectionReason = "rejection_reason"
        case creditVerdict = "credit_verdict"
        case holdReason = "hold_reason"
        case decisionNote = "decision_note"
        case decidedAt = "decided_at"
        case deliveryStatus = "delivery_status"
        case deliveryReason = "delivery_reason"
        case deliveredAt = "delivered_at"
    }
}

// MARK: - OrderLine (local)

/// Línea de una orden (se transforma al schema `OrderLine` del contrato al subir).
struct OrderLine: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: Int64?              // autoincrement local
    var orderUUID: String      // FK -> orders.client_uuid
    var itemCode: String
    var quantity: Double
    var unitPrice: Double       // precio unitario = precio del ítem en la lista elegida
    var lineDiscountPct: Double // descuento de línea en % (0–100)
    var priceList: Int          // lista elegida para ESTA línea (1/2/3); obligatorio en v0.3.0
    /// ★ v0.28.0 — UUID del bloque de promoción (condición + beneficio comparten uno). nil en
    /// líneas normales. Viaja en el POST.
    var promotionGroupId: String?
    /// ★ v0.28.0 — Título de la promoción, SOLO local (para el encabezado del bloque en el
    /// carrito). NO se envía al server.
    var promotionTitle: String?

    static let databaseTableName = "order_lines"

    /// ¿Esta línea pertenece a un bloque de promoción? (inmutable en el carrito)
    var isPromotion: Bool { promotionGroupId != nil }

    enum CodingKeys: String, CodingKey {
        case id
        case orderUUID = "order_uuid"
        case itemCode = "item_code"
        case quantity
        case unitPrice = "unit_price"
        case lineDiscountPct = "line_discount_pct"
        case priceList = "price_list"
        case promotionGroupId = "promotion_group_id"
        case promotionTitle = "promotion_title"
    }

    // Deja que SQLite asigne el rowid autoincremental.
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Estado de cuenta (★ v0.4.0)

/// Tipo de documento del estado de cuenta.
enum StatementDocType: String, Codable {
    case invoice = "INVOICE"                     // el cliente debe (open_amount > 0)
    case creditNote = "CREDIT_NOTE"              // resta deuda (open_amount < 0)
    case paymentOnAccount = "PAYMENT_ON_ACCOUNT" // resta deuda (open_amount < 0)
}

/// Documento del estado de cuenta (schema `StatementDocument`). Se persiste en GRDB para
/// consulta OFFLINE. `id`, `clientCode` y `asOf` son LOCALES (no vienen por-documento en
/// el JSON): se rellenan al guardar. El resto viene del contrato.
struct StatementDocument: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: Int64?              // autoincrement local
    var clientCode: String     // a qué cliente pertenece (local)
    var asOf: Date?            // foto de cartera del statement (local)
    var docType: StatementDocType
    var docNum: String
    var docDate: Date?
    var dueDate: Date?          // NULL para NC y pagos (no vencen)
    var docTotal: Double
    /// POSITIVO para facturas (deuda); NEGATIVO para NC y pagos (restan deuda).
    var openAmount: Double
    var daysOverdue: Int?       // negativo = aún no vence; NULL para NC y pagos
    var isFromSage: Bool
    var sageDocNumber: String?

    static let databaseTableName = "statement_documents"

    enum CodingKeys: String, CodingKey {
        case id
        case clientCode = "client_code"
        case asOf = "as_of"
        case docType = "doc_type"
        case docNum = "doc_num"
        case docDate = "doc_date"
        case dueDate = "due_date"
        case docTotal = "doc_total"
        case openAmount = "open_amount"
        case daysOverdue = "days_overdue"
        case isFromSage = "is_from_sage"
        case sageDocNumber = "sage_doc_number"
    }

    /// ¿Está vencida? Solo aplica a facturas (las NC/pagos no vencen).
    var isOverdue: Bool { (daysOverdue ?? 0) > 0 }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// `id`, `client_code` y `as_of` no vienen por-documento en el JSON del servidor: se
// decodifican con default y se rellenan al persistir. Igual patrón que Client.active.
extension StatementDocument {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id)
        clientCode = try c.decodeIfPresent(String.self, forKey: .clientCode) ?? ""
        asOf = try c.decodeIfPresent(Date.self, forKey: .asOf)
        docType = try c.decode(StatementDocType.self, forKey: .docType)
        docNum = try c.decode(String.self, forKey: .docNum)
        docDate = try c.decodeIfPresent(Date.self, forKey: .docDate)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        docTotal = try c.decode(Double.self, forKey: .docTotal)
        openAmount = try c.decode(Double.self, forKey: .openAmount)
        daysOverdue = try c.decodeIfPresent(Int.self, forKey: .daysOverdue)
        isFromSage = try c.decodeIfPresent(Bool.self, forKey: .isFromSage) ?? false
        sageDocNumber = try c.decodeIfPresent(String.self, forKey: .sageDocNumber)
    }
}

/// Estado de cuenta completo (schema `ClientStatement`). DTO de red: la app persiste
/// `documents` (como `StatementDocument`) y `credit` (en el cliente). `as_of` acompaña.
struct ClientStatement: Codable, Equatable {
    var clientCode: String
    var clientName: String?
    var credit: ClientCredit?
    var documents: [StatementDocument]
    var asOf: Date?

    enum CodingKeys: String, CodingKey {
        case clientCode = "client_code"
        case clientName = "client_name"
        case credit
        case documents
        case asOf = "as_of"
    }
}

// MARK: - SyncState

/// Marca de agua por recurso para la sincronización incremental.
/// Guarda el `server_time` recibido en la última bajada; se reenvía como `since`.
struct SyncState: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var resource: String        // "catalog" | "clients"
    var lastSyncedAt: Date?     // server_time de la última bajada

    var id: String { resource }

    static let databaseTableName = "sync_state"

    enum CodingKeys: String, CodingKey {
        case resource
        case lastSyncedAt = "last_synced_at"
    }
}
