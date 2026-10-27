# Proposal: vaulta-sync-surface-reduction

> Implementación de la decisión (b) "Reducir superficie" de
> ADR-004 (Roadmap de `lib/core/sync/`). Fase S4 del plan
> trimestral.

## Intent

Reducir la superficie de `lib/core/sync/` consolidando los dos
servicios de sync incremental
(`IncrementalPullSyncService` + `IncrementalPushSyncService`) en
uno solo bidireccional, y marcando los concerns internos como
tales vía docstrings + barrel.

Referencia: `docs/adr/0004-sync-layer-roadmap.md` sección
"Decisión" e "Implementación por lotes".

## Scope

### In Scope

- Crear `lib/core/sync/bidirectional_sync_service.dart` que
  consolida los dos servicios viejos.
- Tests del nuevo servicio (TDD Red→Green→Refactor).
- Marcar `DeviceRegistrationRepository` y
  `DeviceSessionRevocationService` con docstrings que
  declaren su uso interno de `lib/core/sync/`.
- Crear `lib/core/sync/sync_internal.dart` como barrel que
  re-exporta las APIs internas.
- Agregar `@Deprecated('Use BidirectionalSyncService instead.
  Will be removed in a subsequent change.')` en los dos
  servicios viejos.
- **NO** se migran los consumidores todavía (eso es T4,
  separado, según ADR-004).
- **NO** se borran los archivos viejos en este change.

### Out of Scope

- Migrar `device_sync_bootstrap.dart` y
  `DeviceSyncLifecycle` al nuevo servicio (T4, según
  ADR-004). Esto es `vaulta-sync-migration`.
- Borrar `incremental_pull_sync_service.dart` y
  `incremental_push_sync_service.dart` (T5, según ADR-004).
  Esto se completa en
  `vaulta-public-api-docs-extended`.
- Cambios en el formato del vault o en el cifrado.
- Activar la regla `public_member_api_docs` para todo `lib/`
  (eso es `vaulta-public-api-docs` y su follow-up
  `-extended`).

## Capabilities

### New Capabilities

- `bidirectional-sync`: servicio único que reemplaza pull +
  push incrementales con una sola pieza de código. Coordina
  cursor de pull persistido y queue de push con
  backoff/retry/conflict.

### Modified Capabilities

- `sync-internal-export`: export único
  `sync/sync_internal.dart` para concerns de sync que las
  features no deberían importar.

## Approach

### T1: `BidirectionalSyncService`

- API: `implements LocalVaultMutationSink` (recibe mutaciones
  locales).
- Lifecycle: `onSessionStarted()`, `onAppResumed()`, `runNow()`
  (trigger explícito para el conflict resolver),
  `pullNow({bool force = false})`.
- Estado interno:
  - Pull: cursor persistido, `lastPullAt` para throttle.
  - Push: queue persistida, flag `_running` +
    `_rerunRequested`.
- Parámetros con prefijo `pull*` o `push*` para claridad
  cuando aplica a uno solo de los dos lados.
- TDD: tests para happy path pull, happy path push, retry
  con backoff, conflict detection, throttle de pull, queue
  mutation, mutex de push.

### T2: docstring "internal" + barrel `sync_internal.dart`

- Docstrings explícitos en
  `DeviceRegistrationRepository` y `DeviceSessionRevocationService`
  declarando que son para uso interno de `lib/core/sync/`.
- Crear `lib/core/sync/sync_internal.dart` que re-exporta
  ambos archivos.
- **Desviación documentada**: la propuesta original de usar la
  anotación `@internal` de `package:meta` **no se ejecuta**.
  El lint `invalid_internal_annotation` la rechaza: `@internal`
  solo aplica a elementos privados del package (símbolos con
  `_` o dentro de `lib/src/`). Como ambas clases son públicas
  por diseño de la API, la convención queda en (a) docstrings
  que explican el contrato, (b) el barrel `sync_internal.dart`
  como punto único de re-export. La enforcement real (CI grep
  + lint custom) queda para un follow-up dedicado si la
  convención se rompe en la práctica.

### T3: deprecation notices

- `@Deprecated('Use BidirectionalSyncService instead. Will be
  removed in a subsequent change.')` en las dos clases
  viejas.
- Las deprecaciones aparecen como `info` (no fallan el build).

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `lib/core/sync/bidirectional_sync_service.dart` | New | 767 líneas, servicio consolidado |
| `lib/core/sync/sync_internal.dart` | New | 12 líneas, barrel |
| `test/core/sync/bidirectional_sync_service_test.dart` | New | 393 líneas, tests TDD |
| `lib/core/sync/device_registration_repository.dart` | Modified | +docstring "internal" |
| `lib/core/sync/device_session_revocation_service.dart` | Modified | +docstring "internal" |
| `lib/core/sync/incremental_pull_sync_service.dart` | Modified | +`@Deprecated` |
| `lib/core/sync/incremental_push_sync_service.dart` | Modified | +`@Deprecated` |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| API del nuevo servicio rompe consumidores cuando migren (T4) | Low | Tests exhaustivos en este change; el T4 los ejercita en contexto real |
| `@internal` no se enforce en mismo package | High (por diseño) | Documentado en ADR-004; enforcement es por CI grep en follow-up dedicado |
| Deprecation warnings saturan el log de CI | Low | Las deprecaciones son `info` por default, no aparecen en errores |
| Tests viejos del pull/push fallen porque sus archivos cambian | Low | Solo agrego `@Deprecated`, no cambio semántica |

## Rollback Plan

- `git revert` del merge commit.
- Los 2 archivos viejos (`incremental_pull_sync_service.dart`,
  `incremental_push_sync_service.dart`) vuelven a no tener
  `@Deprecated`.
- El nuevo archivo `bidirectional_sync_service.dart` queda
  como código muerto (compila, pasa tests, pero no se usa) —
  cleanup trivial.

## Dependencies

- `package:meta` (ya viene transitivamente; se importa
  explícitamente para `@Deprecated`).
- Flutter estable (sin cambios de SDK).

## Success Criteria

- [x] `flutter analyze` retorna 0 issues (las deprecaciones
      son `info`).
- [x] `flutter test` pasa (86 tests existentes + 6 nuevos
      del bidirectional).
- [x] `lib/core/sync/sync_internal.dart` existe y re-exporta
      los 2 archivos internos.
- [x] `grep -r 'Features must not import' lib/core/sync/`
      matchea en ambos archivos marcados.
- [x] Los consumidores actuales (`device_sync_bootstrap.dart`,
      `DeviceSyncLifecycle`) siguen funcionando con los
      servicios viejos (la migración es T4, downstream).
- [x] 2 commits en master (`6e65f0d` + `10a6a51`) con
      mensajes conventional.

## Commits del change (en orden cronológico)

1. `6e65f0d` — `feat(sync): add BidirectionalSyncService
   consolidating pull+push` (T1, scaffolding del change).
2. `10a6a51` — `refactor(sync): deprecate old services and
   add internal barrel` (T2, T3).

## Trabajo downstream (posterior, en otros changes)

- T4: migrar los dos consumers al nuevo servicio →
  `vaulta-sync-migration`.
- T5: borrar los servicios viejos cuando 0 references →
  parte de `vaulta-public-api-docs-extended`.
- Enforce real de "internal" via CI grep → change aparte si
  la convención se rompe en la práctica.
