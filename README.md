# Dinas WMS — App de Vendedores (iOS)

App nativa (iPad + iPhone), **offline-first**, para que los vendedores tomen pedidos en
campo sin conexión y los sincronicen con el middleware cuando hay red.

- **Stack:** Swift + SwiftUI · SQLite con [GRDB.swift](https://github.com/groue/GRDB.swift) · cliente HTTP contra el middleware (`openapi.yaml`).
- **Distribución:** interna vía **JAMF** (no App Store). Ver [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

## Estado del MVP

- [x] Login usuario/contraseña (`POST /auth/login`), JWT en **Keychain**, `Authorization: Bearer`.
- [x] Base local GRDB: `items`, `clients`, `orders`, `order_lines`, `sync_state` (migración v1).
- [x] Sincronización de **bajada**: `GET /sync/catalog` + `GET /sync/clients` (con `since`), upsert.
- [x] **Catálogo**: grilla, búsqueda local offline, detalle con imagen.
- [x] **Clientes**: lista de asignados, búsqueda, detalle.
- [x] **Toma de orden**: cliente primero, carrito, descuento de línea, borrador → confirmar → descartar.
- [x] Sincronización de **subida**: `POST /orders` idempotente por `client_uuid`.
- [x] Endurecimiento: 401 → re-login, badge de pendientes, auto-sync al reconectar, banner offline, guard anti-concurrencia.

## Arquitectura

```
DinasSales/
  App/          entry point, AuthGate, RootView (tabs), AppEnvironment (composición raíz)
  Features/
    Auth/       login + Keychain (TokenStore, AuthSession)
    Catalog/    grilla, búsqueda, detalle
    Clients/    lista de asignados
    Orders/     carrito, descuento, borrador/confirmar/descartar
  Data/
    Local/      GRDB: modelos, migración (AppDatabase), repositorios
    Remote/     APIClient (según OpenAPI) + DTOs
    Sync/       SyncEngine (bajada/subida), NetworkMonitor
  Resources/    Info.plist, Assets.xcassets
DinasSalesTests/  41 tests (repos + motor de sync)
Config/           xcconfig por ambiente + ExportOptions.plist
Scripts/          generate_project.rb, make_icon.swift, archive_export.sh
```

Decisiones clave:

- **Modelos GRDB con `CodingKeys` snake_case** → el mismo tipo decodifica el JSON del
  middleware y persiste en SQLite, sin capa de mapeo.
- **Protocolos** (`AuthAPI`, `SyncDownAPI`, `SyncUpAPI`, `TokenStore`) → todo testeable
  sin red ni Keychain real.
- **Doble build:** `swift test` en host (macOS) para lógica; `.xcodeproj` para la app iOS.
- **Base local versionada** con migraciones GRDB; las liberadas son inmutables (disciplina
  en [docs/MIGRATIONS.md](docs/MIGRATIONS.md)).

## Cómo correr

### Tests (host, rápido)

```bash
swift test
```

Corre en macOS vía SPM (`Package.swift` declara `macOS(.v13)` solo para esto; el objetivo
real es iOS 16). El `@main` está bajo `#if canImport(UIKit)` para no chocar con el runner.

### Abrir la app en Xcode

El `.xcodeproj` se **genera**, no se edita a mano:

```bash
gem install --user-install xcodeproj   # una vez
ruby Scripts/generate_project.rb
open DinasSales.xcodeproj               # elige un simulador y ⌘R
```

Regenera y commitea el `.xcodeproj` cuando agregues/quites archivos `.swift` o cambies
settings del proyecto. Los `.xcconfig` se editan directamente (no requieren regenerar).

### Ambientes

Cada build configuration apunta a su `Config/*.xcconfig`:

| Config  | Ambiente | `MIDDLEWARE_BASE_URL`       | Bundle ID                 | Nombre           |
|---------|----------|----------------------------|---------------------------|------------------|
| Debug   | Dev      | `Config/Dev.xcconfig`      | `com.dinas.sales.dev`     | Dinas (Dev)      |
| Staging | Staging  | `Config/Staging.xcconfig`  | `com.dinas.sales.staging` | Dinas (Staging)  |
| Release | Prod     | `Config/Prod.xcconfig`     | `com.dinas.sales`         | Dinas Vendedores |

> ⚠️ Las URLs son **placeholders** (`*.example.com`). Reemplazar por las reales antes de
> probar contra el middleware. `MIDDLEWARE_BASE_URL` vacío → la app avisa "falta URL".

## Reglas de negocio

- **Offline-first de verdad:** todo lo necesario para tomar un pedido está en la base
  local. La sincronización es un evento aparte.
- **La app NO recalcula stock:** muestra el `available` que envía el middleware.
- **UUID en el dispositivo:** cada orden nace con un `client_uuid` (v4) generado y
  persistido localmente al crear el borrador. Es la clave de idempotencia de `POST /orders`
  y **no se regenera** en reintentos.
- **Precio — cero es decisión, null es ausencia:** `unit_price = 0` es válido (promoción /
  línea regalada); `CatalogItem.price = null` → ítem **no ordenable** (se muestra "Sin
  precio", nunca se sustituye por 0).
- **Moneda:** USD fija (Dinas opera en NY/NJ/CT/PA). Sin multi-moneda.

## Sincronización

- **Bajada:** deltas con `since` = `server_time` de la última bajada (guardado en
  `sync_state`); upsert por PK.
- **Subida:** órdenes `confirmed` → `POST /orders`. Un fallo transitorio las deja
  pendientes para reintento (mismo UUID); un 401 fuerza re-login.
- **Auto-sync** al recuperar red (solo con sesión activa); **guard anti-concurrencia**
  atómico (`@MainActor`, sin `await` entre comprobar y setear el flag) evita subidas
  duplicadas por disparos simultáneos.

> La idempotencia del lado servidor (dedup por `client_uuid`, incl. caso concurrente) es
> responsabilidad del middleware (criterios de aceptación Q1); la app garantiza su mitad:
> UUID estable y persistido, reintento con el mismo UUID, sin dobles POST.

## CI

`.github/workflows/ci.yml` corre en cada PR y push a `main`:

- `swift test` (host macOS) — protege los 41 tests.
- `xcodebuild build` del target de app para iOS Simulator — verifica que compila.

## Distribución

Ver [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md): firma (enterprise/in-house), generación
del `.ipa` (`Scripts/archive_export.sh`) y subida a JAMF.

## Contrato

`openapi.yaml` (raíz del repo) es la fuente de verdad App↔Middleware. Ningún cambio al
contrato sin aprobación del Arquitecto. Si un dato que necesitas no está en el contrato,
no lo inventes: se eleva.
