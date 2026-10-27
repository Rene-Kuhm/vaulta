# Proposal: vaulta-sync-migration (T4 de ADR-004)

> Migración de los dos consumidores de los servicios viejos
> de sync al nuevo `BidirectionalSyncService`. T4 del
> roadmap de `docs/adr/0004-sync-layer-roadmap.md`.

## Intent

Cerrar el estado transitorio del sync layer. Antes de este
change coexistían tres servicios
(`BidirectionalSyncService` + los dos `@Deprecated`) pero
solo los viejos eran los que `device_sync_bootstrap.dart` y
`DeviceSyncLifecycle` instanciaban. Esto contradecía la
decisión de ADR-004 ("`BidirectionalSyncService` es la
base") y dejaba el codebase en un limbo donde
`flutter analyze` mostraba `@Deprecated` warnings sin que
nadie los arreglara.

Resultado esperado:
- Los dos consumers usan `BidirectionalSyncService`
  exclusivamente.
- `DeviceSyncLifecycle` toma un solo `syncService` (no dos
  separados).
- `IncrementalPullSyncService` y `IncrementalPushSyncService`
  siguen existiendo con `@Deprecated` (T5 los borra en un
  follow-up aparte, parte de
  `vaulta-public-api-docs-extended`).
- Tests verdes, analyze limpio.

## Scope

### In Scope

- Refactor de `device_sync_bootstrap.dart` para instanciar
  `BidirectionalSyncService` en lugar de los dos servicios
  viejos.
- Refactor de `DeviceSyncLifecycle` (en
  `device_registration_service.dart`) para tomar un solo
  `syncService` opcional. Eliminación de los params
  `pullSyncService` y `pushSyncService`.
- Wiring del `conflictResolver.triggerPushSync` al
  `syncService.runNow` (que dispara un drain de push, igual
  que hacía `pushSyncService.runNow` antes).
- Tests de `DeviceSyncLifecycle` actualizados; nuevo test
  que verifica que `syncService.onSessionStarted` y
  `syncService.onAppResumed` se llaman en el flujo correcto.
- 2 commits lógicos: uno para `device_sync_bootstrap.dart`,
  otro para `DeviceSyncLifecycle` + tests.

### Out of Scope

- Borrar `IncrementalPullSyncService.dart` y
  `incremental_push_sync_service.dart` (T5 de ADR-004, parte
  de `vaulta-public-api-docs-extended`). Por ahora siguen
  con `@Deprecated` y nadie los importa.
- Cambios en el formato del vault, en el cifrado, o en el
  sync contract.
- Extender la regla `public_member_api_docs` a `lib/app/` y
  `lib/features/` (eso es
  `vaulta-public-api-docs-extended`).

## Capabilities

### Modified Capabilities

- `bidirectional-sync`: ahora se ejerce desde los dos
  consumers; hasta ahora solo se testeaba en aislamiento.

## Approach

### Fase 1: `device_sync_bootstrap.dart`

Cambios:
- Eliminar las dos `IncrementalPullSyncService` /
  `IncrementalPushSyncService` instantiations.
- Crear una sola `BidirectionalSyncService` con los mismos
  parámetros que tenía `IncrementalPullSyncService`
  (incluido el `applyLocalSnapshots`).
- `SyncConflictResolver(triggerPushSync: ...)` ahora recibe
  `syncService.runNow`.
- `mutationSink?.attach(...)` ahora recibe `syncService`.
- `DeviceSyncLifecycle(...)` recibe `syncService: syncService`
  (un solo param) en lugar de los dos separados.

### Fase 2: `DeviceSyncLifecycle` (`device_registration_service.dart`)

Cambios:
- Reemplazar `IncrementalPullSyncService? pullSyncService` +
  `IncrementalPushSyncService? pushSyncService` por un solo
  `BidirectionalSyncService? syncService`.
- Reemplazar `_pullSyncService?.onSessionStarted()` +
  `_pushSyncService?.onSessionStarted()` por
  `_syncService?.onSessionStarted()` (el nuevo servicio corre
  pull y push internamente).
- Reemplazar `_pullSyncService?.onAppResumed()` +
  `_pushSyncService?.onAppResumed()` por
  `_syncService?.onAppResumed()`.

### Fase 3: Tests

- Los tests existentes en
  `device_registration_service_test.dart` NO pasan
  `pullSyncService`/`pushSyncService` al lifecycle, así que
  siguen pasando sin cambios (siguen testeando solo la
  lógica de registration/heartbeat/revocation).
- `security_gate_test.dart` tampoco pasa sync services al
  lifecycle, sigue pasando sin cambios.
- Agregar un test nuevo en
  `device_registration_service_test.dart` que verifique que
  `syncService.onSessionStarted` y `syncService.onAppResumed`
  se llaman cuando el lifecycle los invoca. Usar un
  `_FakeBidirectionalSyncService` que cuente las llamadas.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `lib/core/sync/device_sync_bootstrap.dart` | Modified | Single service instantiation |
| `lib/core/sync/device_registration_service.dart` | Modified | `DeviceSyncLifecycle` API: pullSyncService + pushSyncService → syncService |
| `test/core/sync/device_registration_service_test.dart` | Modified | New test for syncService wiring |
| `lib/core/sync/incremental_pull_sync_service.dart` | Unchanged | Sigue con `@Deprecated` hasta T5 |
| `lib/core/sync/incremental_push_sync_service.dart` | Unchanged | Sigue con `@Deprecated` hasta T5 |
| `test/core/sync/incremental_pull_sync_service_test.dart` | Unchanged | Sigue verde (test del servicio viejo) |
| `test/core/sync/incremental_push_sync_service_test.dart` | Unchanged | Sigue verde (test del servicio viejo) |

## Risks

| Risk | Mitigation |
|------|------------|
| Breaking change en `DeviceSyncLifecycle` API afecta a otros call sites | Único call site del lifecycle además del bootstrap es el test de `security_gate_test.dart`, que no pasa los params removidos. Verificado con grep. |
| Conflicto de timing en el wiring: el lifecycle llama `_syncService.onSessionStarted()` pero el sync service necesita `mutationSink` ya atado para recibir mutaciones | El bootstrap hace `mutationSink?.attach(syncService)` ANTES de crear el lifecycle. Orden ya correcto en el código viejo, lo preservamos. |
| Tests de los servicios viejos fallan porque los archivos cambiados en este change los importan | No tocamos los archivos de los servicios viejos. Solo los consumers. Los tests viejos siguen importándolos y siguen pasando. |
| `BidirectionalSyncService.runNow` se comporta diferente a `IncrementalPushSyncService.runNow` | `BidirectionalSyncService.runNow` es semánticamente idéntico: `_triggerPush()` que drena la queue con el mutex. Verificado en `bidirectional_sync_service_test.dart`. |

## Rollback Plan

Revert de los commits de este change. Los servicios viejos
siguen existiendo (no se borran), así que el revert devuelve
al estado anterior sin data corruption.

## Success Criteria

- [x] `flutter analyze` retorna `No issues found!` (los
      `@Deprecated` warnings desaparecen porque no hay más
      consumers).
- [x] `flutter test` pasa los 92 tests existentes + el test
      nuevo del wiring de `syncService` (94/94 verde).
- [x] Coverage gate sigue en `OK: 52.4% >= 50%`.
- [x] `git grep "pullSyncService\|pushSyncService"` en
      `lib/` retorna 0 resultados.
- [x] Los archivos `incremental_pull_sync_service.dart` y
      `incremental_push_sync_service.dart` siguen existiendo
      con `@Deprecated` (no se borran acá, eso es T5).

## Commits del change (en orden cronológico)

1. `af3a823` — `refactor(sync): consolidate
   device_sync_bootstrap onto BidirectionalSyncService`
   (Fase 1).
2. `ade5bc9` — `refactor(sync): consolidate
   DeviceSyncLifecycle onto a single syncService param +
   add wiring tests` (Fase 2 + Fase 3).

## Trabajo downstream (posterior, en otros changes)

- T5: borrar los 2 servicios viejos cuando 0 references →
  parte de `vaulta-public-api-docs-extended` (cerrado en
  commit `7bf96fc`).
