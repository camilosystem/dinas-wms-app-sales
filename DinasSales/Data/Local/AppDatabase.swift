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

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // Durante desarrollo, recrea la base si cambian migraciones ya aplicadas.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_esquema_inicial") { db in
            try db.create(table: "items") { t in
                t.primaryKey("id", .text)
                t.column("code", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("available", .integer).notNull().defaults(to: 0)
                t.column("comments", .text)
                t.column("image_url", .text)
                t.column("updated_at", .datetime)
            }

            try db.create(table: "clients") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("address", .text)
                t.column("updated_at", .datetime)
            }

            try db.create(table: "orders") { t in
                t.primaryKey("client_uuid", .text)   // UUID v4 local; idempotencia
                t.column("client_id", .text).notNull()
                    .references("clients", onDelete: .restrict)
                t.column("status", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("confirmed_at", .datetime)
                t.column("synced_at", .datetime)
            }

            try db.create(table: "order_lines") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("order_uuid", .text).notNull()
                    .references("orders", column: "client_uuid", onDelete: .cascade)
                t.column("item_id", .text).notNull()
                t.column("quantity", .integer).notNull()
                t.column("line_discount", .double).notNull().defaults(to: 0)
            }

            try db.create(table: "sync_state") { t in
                t.primaryKey("resource", .text)      // "catalog" | "clients"
                t.column("last_synced_at", .datetime)
            }
        }

        return migrator
    }
}
