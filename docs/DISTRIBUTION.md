# Distribución interna (JAMF)

La App de Vendedores se distribuye **internamente vía JAMF** (no App Store), como
**enterprise / in-house** (Apple Developer Enterprise Program).

## Requisitos (una sola vez)

1. **Team ID** de la cuenta Enterprise (10 caracteres). Ponerlo en:
   - `Config/Base.xcconfig` → `DEVELOPMENT_TEAM = XXXXXXXXXX`
   - `Config/ExportOptions.plist` → `teamID`
2. **Certificado de distribución** (*Apple Distribution*) instalado en el llavero.
3. **Perfil de aprovisionamiento in-house** para el bundle `com.dinas.sales`.
   Poner su nombre en `Config/ExportOptions.plist` → `provisioningProfiles`.

## Generar el .ipa

```bash
Scripts/archive_export.sh Release        # producción (o: Staging)
# => build/ipa-Release/DinasSales.ipa
```

El script hace `xcodebuild archive` + `-exportArchive` con `Config/ExportOptions.plist`.
El build de **dispositivo requiere firma**: sin certificado/perfil válidos, falla.

## Subir a JAMF

1. En **JAMF Pro → Computers/Devices → Mobile Device Apps → In-House**, sube el `.ipa`.
2. Asigna el **scope** (grupos de dispositivos/vendedores).
3. Distribución **Automatic** (push) o **Self Service**, según política.

## Ambientes

| Build config | Ambiente | URL (`MIDDLEWARE_BASE_URL`) | Nombre | Bundle ID |
|---|---|---|---|---|
| Debug   | Dev     | `Config/Dev.xcconfig`     | Dinas (Dev)     | `com.dinas.sales.dev` |
| Staging | Staging | `Config/Staging.xcconfig` | Dinas (Staging) | `com.dinas.sales.staging` |
| Release | Prod    | `Config/Prod.xcconfig`    | Dinas Vendedores | `com.dinas.sales` |

> ⚠️ Las URLs son **placeholders** (`*.example.com`). Reemplazar por las reales antes de distribuir.
> Cada ambiente usa su propio **bundle ID**, así que Dev/Staging/Prod se pueden instalar en paralelo
> en un mismo dispositivo. `Config/ExportOptions.plist` mapea el perfil de **prod** (`com.dinas.sales`);
> para archivar Staging/Dev, agrega su bundle ID y perfil in-house correspondiente en `provisioningProfiles`.

## Regenerar el proyecto Xcode

`DinasSales.xcodeproj` se **genera**, no se edita a mano:

```bash
ruby Scripts/generate_project.rb
```

Los `.xcconfig` y `ExportOptions.plist` se editan directamente (no requieren regenerar).
