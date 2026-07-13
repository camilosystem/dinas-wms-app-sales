import Foundation
import GRDB

/// Punto de acceso a la base local SQLite (GRDB).
///
/// Encapsula el `DatabaseQueue` y define las migraciones del esquema.
/// Toda lectura/escritura de la app pasa por aquí.
struct AppDatabase {
    /// Cola de acceso a la base. GRDB serializa los accesos.
    let dbQueue: DatabaseQueue

    init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try migrator.migrate(dbQueue)
    }

    // MARK: - Fábricas

    /// Base compartida de la app, en Application Support.
    static func makeShared() throws -> AppDatabase {
        let fm = FileManager.default
        let folder = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dbURL = folder.appendingPathComponent("dinas-sales.sqlite")
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        return try AppDatabase(dbQueue)
    }

    /// Base en memoria, para tests.
    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    // MARK: - Migraciones
    //
    // DISCIPLINA DE MIGRACIONES (ver docs/MIGRATIONS.md):
    //
    // 1. Una migración registrada y liberada es INMUTABLE. `v1_esquema_inicial` ya está
    //    en dispositivos de vendedores: NO se edita. Cualquier cambio de esquema va en una
    //    migración NUEVA (`v2_...`, `v3_...`) que se AÑADE al final.
    // 2. Las migraciones son ADITIVAS y preservan datos: `ADD COLUMN`, `CREATE TABLE`,
    //    nuevos índices. Evitar operaciones destructivas (renombrar/eliminar columnas con
    //    datos); si son inevitables, migrar los datos dentro de la misma migración.
    // 3. `eraseDatabaseOnSchemaChange` está activo SOLO en DEBUG: recrea la base al cambiar
    //    una migración ya aplicada (comodidad de desarrollo). En release NO existe, así que
    //    editar una migración liberada dejaría bases inconsistentes en campo.
    // 4. El identificador de cada migración es su clave: no reutilizar ni renombrar los ya
    //    liberados.

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // Solo desarrollo: recrea la base si cambia una migración YA aplicada. En release
        // no aplica — por eso las migraciones liberadas son inmutables (ver arriba).
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_esquema_inicial") { db in
            // Catálogo (schema CatalogItem). available es double (ya calculado).
            try db.create(table: "items") { t in
                t.primaryKey("item_code", .text)
                t.column("name", .text).notNull()
                t.column("category", .text)
                t.column("barcode", .text).indexed()
                t.column("comments", .text)
                t.column("price", .double)
                t.column("stock", .double)
                t.column("available", .double).notNull().defaults(to: 0)
                t.column("image_url", .text)
                t.column("active", .boolean).notNull().defaults(to: true)
            }

            // Clientes asignados (schema Client).
            try db.create(table: "clients") { t in
                t.primaryKey("client_code", .text)
                t.column("name", .text).notNull()
                t.column("address", .text)
                t.column("city", .text)
                t.column("zipcode", .text)
                t.column("manager_name", .text)
                t.column("shipping_route", .text)
            }

            // Órdenes (modelo local; se sube como OrderCreate).
            try db.create(table: "orders") { t in
                t.primaryKey("client_uuid", .text)   // UUID v4 local; idempotencia
                t.column("client_code", .text).notNull()
                    .references("clients", onDelete: .restrict)
                t.column("status", .text).notNull()
                t.column("notes", .text)
                t.column("created_at", .datetime).notNull()
                t.column("taken_at", .datetime)
                t.column("synced_at", .datetime)
                t.column("order_number", .text)
            }

            try db.create(table: "order_lines") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("order_uuid", .text).notNull()
                    .references("orders", column: "client_uuid", onDelete: .cascade)
                t.column("item_code", .text).notNull()
                t.column("quantity", .double).notNull()
                t.column("unit_price", .double).notNull()
                t.column("line_discount_pct", .double).notNull().defaults(to: 0)
                t.column("price_list", .text)
            }

            // Marca de agua por recurso (server_time de la última bajada).
            try db.create(table: "sync_state") { t in
                t.primaryKey("resource", .text)      // "catalog" | "clients"
                t.column("last_synced_at", .datetime)
            }
        }

        // v0.3.0: 3 listas de precio por ítem, listas autorizadas por cliente, y
        // price_list obligatorio por línea. Preserva las órdenes del vendedor.
        migrator.registerMigration("v2_listas_de_precio") { db in
            // items: nuevo esquema con 3 listas (sin `price`/`comments`). Es CACHÉ → se
            // re-sincroniza; recrear la tabla es seguro (nada la referencia).
            try db.drop(table: "items")
            try db.create(table: "items") { t in
                t.primaryKey("item_code", .text)
                t.column("name", .text).notNull()
                t.column("category", .text)
                t.column("barcode", .text).indexed()
                t.column("price_list_1", .double).notNull().defaults(to: 0)
                t.column("price_list_2", .double).notNull().defaults(to: 0)
                t.column("price_list_3", .double).notNull().defaults(to: 0)
                t.column("stock", .double)
                t.column("available", .double).notNull().defaults(to: 0)
                t.column("image_url", .text)
                t.column("active", .boolean).notNull().defaults(to: true)
            }

            // clients: listas de precio (aditivo).
            try db.alter(table: "clients") { t in
                t.add(column: "default_price_list", .integer).notNull().defaults(to: 1)
                // authorized_price_lists: GRDB persiste el [Int] como JSON en esta columna.
                t.add(column: "authorized_price_lists", .text).notNull().defaults(to: "[1]")
            }

            // order_lines: price_list pasa a entero OBLIGATORIO (1/2/3). Se recrea la tabla
            // preservando las órdenes; las líneas legacy (price_list nulo) se rellenan con 1.
            // order_lines es tabla hija (nada la referencia) → recrear es seguro con FK on.
            try db.create(table: "order_lines_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("order_uuid", .text).notNull()
                    .references("orders", column: "client_uuid", onDelete: .cascade)
                t.column("item_code", .text).notNull()
                t.column("quantity", .double).notNull()
                t.column("unit_price", .double).notNull()
                t.column("line_discount_pct", .double).notNull().defaults(to: 0)
                t.column("price_list", .integer).notNull().defaults(to: 1)
            }
            try db.execute(sql: """
                INSERT INTO order_lines_new
                    (id, order_uuid, item_code, quantity, unit_price, line_discount_pct, price_list)
                SELECT id, order_uuid, item_code, quantity, unit_price, line_discount_pct,
                       COALESCE(CAST(price_list AS INTEGER), 1)
                FROM order_lines
                """)
            try db.drop(table: "order_lines")
            try db.rename(table: "order_lines_new", to: "order_lines")

            // El esquema de catálogo/clientes cambió → forzar re-sync COMPLETO (sin `since`).
            try db.execute(sql: "DELETE FROM sync_state")
        }

        return migrator
    }
}
