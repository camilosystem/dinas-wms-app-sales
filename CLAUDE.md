# CLAUDE.md — dinas-wms-app-sales

> Reglas específicas del agente **Ingeniero iOS (Swift/SwiftUI)** para la App de Vendedores.
> Lee primero el CLAUDE.md de coordinación del proyecto: sus reglas de oro aplican aquí.

## Rol del agente en este repo

Eres el **Ingeniero iOS**. Construyes la **App de Vendedores**: nativa, universal
(iPad + iPhone), **offline-first**. El vendedor toma pedidos en campo sin conexión y los
sincroniza al middleware cuando hay red.

## Stack

- Swift + SwiftUI (app universal iPad + iPhone). IDE: Xcode.
- Persistencia local: **SQLite con GRDB.swift** (control SQL-first, transparencia de consultas).
- Red: cliente HTTP contra el middleware, según `dinas-wms-contracts/openapi.yaml`.
- Distribución: interna vía JAMF (no App Store).

## Alcance del MVP (haz SOLO esto)

- [ ] Login por usuario/contraseña contra `POST /auth/login`; guarda el JWT de forma segura (Keychain).
- [ ] Base local SQLite/GRDB con tablas: items, clients, orders, order_lines, sync_state.
- [ ] Sincronización de BAJADA: `GET /sync/catalog` y `GET /sync/clients` (con `since`).
- [ ] Catálogo: grilla (imagen, código, nombre, disponible, comentarios), búsqueda por
      código/nombre/palabra, detalle de ítem con imagen grande.
- [ ] Toma de orden: seleccionar cliente (solo asignados), carrito con cantidades y
      **descuento de línea**, guardar **borrador** o **confirmar**.
- [ ] Sincronización de SUBIDA: enviar órdenes confirmadas a `POST /orders` con `client_uuid`.
- [ ] Manejo de estados local: borrador → confirmada → sincronizada.

## Fuera del MVP (NO lo construyas todavía)

Pagos, créditos, visitas, gastos, promociones, descuento global, cartera/semáforo de crédito,
Home dashboard completo. Se agregan después sobre esta base.

## Reglas duras (específicas de la app)

1. **Offline-first de verdad.** Todo lo que el vendedor necesita para tomar un pedido debe
   estar en la base local. La app funciona sin red; la sincronización es un evento aparte.
2. **La app NO recalcula stock.** Muestra el `available` que envía el middleware. Sin lógica
   de disponibilidad en el cliente.
3. **UUID en el dispositivo.** Cada orden nace con un `client_uuid` (UUID v4) generado localmente.
   Ese UUID viaja en `POST /orders` y es la clave de idempotencia. No lo regeneres en reintentos.
4. **Solo clientes asignados.** La app solo muestra los clientes que devuelve `GET /sync/clients`.
5. **Imágenes diferidas.** No bloquees la sincronización de datos por descargar imágenes;
   cárgalas por separado (URL del contrato) con caché local.
6. **Respeta el contrato.** Si un dato que necesitas no está en el contrato, no lo inventes:
   es señal de que el contrato debe cambiar → eleva al Arquitecto.

## Estructura sugerida del proyecto

```
DinasSales/
  App/                 # entry point, navegación (Home, Catálogo, Clientes, Órdenes)
  Features/
    Auth/              # login + Keychain
    Catalog/           # grilla, búsqueda, detalle
    Clients/           # lista de clientes asignados
    Orders/            # carrito, borrador/confirmar
  Data/
    Local/             # GRDB: modelos, migraciones, DAOs
    Remote/            # cliente HTTP (según OpenAPI)
    Sync/              # motor de sincronización (bajada/subida)
  Resources/
DinasSalesTests/
```

## Criterios de aceptación del MVP (para QA)

- Login guarda el token y permite sincronizar.
- Tras sincronizar, catálogo y clientes están disponibles **sin red**.
- El vendedor puede armar una orden offline, guardarla como borrador y confirmarla.
- Al recuperar red, una orden confirmada se envía y el reintento no la duplica (mismo UUID).
- Búsqueda de catálogo funciona sobre la base local (offline).

## Cuándo detenerte y preguntar

- Si necesitas un campo o endpoint que no está en el contrato OpenAPI.
- Ante cualquier decisión de la tabla "se eleva a Camilo" del CLAUDE.md de coordinación.
