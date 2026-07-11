# Migraciones de la base local (GRDB)

La base local se versiona con `DatabaseMigrator` en
[`AppDatabase.swift`](../DinasSales/Data/Local/AppDatabase.swift). Cada migración tiene un
identificador único y se aplica una sola vez, en orden, sobre la base del dispositivo.

Esta app es **offline-first**: la base del vendedor guarda su trabajo (borradores, órdenes
confirmadas sin subir). Una migración mal hecha puede **destruir datos en campo**. Por eso:

## Reglas

1. **Una migración liberada es inmutable.** `v1_esquema_inicial` ya está en dispositivos.
   No se edita jamás. Todo cambio de esquema va en una migración **nueva** que se **añade
   al final** (`v2_...`, `v3_...`).

2. **Aditivas y preservando datos.** Preferir `ADD COLUMN`, `CREATE TABLE`, nuevos índices.
   Evitar renombrar/eliminar columnas o tablas con datos. Si es inevitable, migrar los
   datos dentro de la misma migración (crear lo nuevo, copiar, luego eliminar lo viejo).

3. **El identificador es la clave.** No renombrar ni reutilizar identificadores ya
   liberados: GRDB decide qué aplicar por ese string.

4. **`eraseDatabaseOnSchemaChange` es solo DEBUG.** En desarrollo recrea la base al cambiar
   una migración ya aplicada (comodidad). En **release no existe**, así que editar una
   migración liberada dejaría bases inconsistentes o crasheando en campo.

## Cómo agregar una migración

1. Añade un `registerMigration` **nuevo** al final del migrador, con un identificador
   descriptivo y versionado.
2. Si agregas/quitas campos de un modelo GRDB, actualiza el `struct` y sus `CodingKeys`
   (recuerda: las mismas `CodingKeys` sirven para JSON del contrato y columnas de la DB).
3. Cubre el cambio con un test (ver [`AppDatabaseTests`](../DinasSalesTests/AppDatabaseTests.swift)):
   que la migración crea/altera lo esperado y que un round-trip del modelo funciona.

### Ejemplo — agregar una columna

```swift
migrator.registerMigration("v2_agrega_notas_a_items") { db in
    try db.alter(table: "items") { t in
        t.add(column: "internal_notes", .text)   // nullable → no rompe filas existentes
    }
}
```

### Ejemplo — cambio destructivo (recrear tabla preservando datos)

Cuando SQLite no soporta la operación directamente (p. ej. cambiar tipo/constraint de una
columna), el patrón es: crear la tabla nueva, copiar, reemplazar.

```swift
migrator.registerMigration("v3_recrea_order_lines") { db in
    try db.create(table: "order_lines_new") { t in /* nuevo esquema */ }
    try db.execute(sql: "INSERT INTO order_lines_new SELECT ... FROM order_lines")
    try db.drop(table: "order_lines")
    try db.rename(table: "order_lines_new", to: "order_lines")
}
```

## Verificación

- `swift test` corre las pruebas de esquema y round-trip en memoria.
- El CI ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)) las ejecuta en cada PR.
