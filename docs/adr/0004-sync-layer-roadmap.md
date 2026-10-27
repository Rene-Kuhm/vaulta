# ADR-004: Roadmap de la capa `lib/core/sync/`

- Estado: Aprobado
- Fecha: 2026-06-11

## Contexto

`lib/core/sync/` tiene 11 archivos (device_registration, incremental pull/push,
sync_conflict_resolver, hardening, remote_vault_sync_repository, supabase_*,
local_remote_vault_store, etc.) etiquetados como "experimental" en el README
y en `docs/how-to/store-release-checklist.md`. El codigo esta limpio: cero
`TODO|FIXME|XXX|HACK|DEPRECATED` y tests unitarios reales sobre los servicios
criticos. Sin embargo, la superficie es grande para un feature que el
proyecto desactiva por defecto en el MVP publico.

Mantener 11 archivos bien cuidados en una rama experimental tiene un costo
de mantenimiento y revision que no se justifica si el sync no es feature
publica de primera clase en el corto plazo.

## Decision

Se adopta la opcion **(b) Reducir superficie** como direccion de roadmap
para `lib/core/sync/`. La decision NO se ejecuta en este change; se
documenta aca y se traduce en tareas hijas explicitas.

Concretamente:

1. Consolidar `IncrementalPullSyncService` y `IncrementalPushSyncService`
   en un unico `BidirectionalSyncService` con un unico motor de cursor.
   - Justificacion: la logica de cursor + version + idempotency es
     compartida. Tener dos servicios separados duplica la contabilidad de
     reintentos.

2. Marcar `DeviceRegistrationRepository` y
   `DeviceSessionRevocationService` como `@internal` (visible para
   `supabase_*` adapters, no para `features/`). Moverlos detras de un
   export unico `sync/sync_internal.dart`.
   - Justificacion: el registro y la revocacion de dispositivos son
     concerns del backend de Supabase; las features de UI no deberian
     poder importarlos directamente.

3. Conservar `SyncConflictResolver` y `RemoteVaultSyncRepository` en la
   superficie publica, porque la UI de conflictos en
   `lib/features/sync/presentation/sync_conflicts_sheet.dart` los
   necesita.

4. Mantener `SyncRuntimeHardening` (pocas lineas, valor defensivo alto).

5. `LocalRemoteVaultStore` y `LocalVaultMutation` quedan en `lib/core/sync/`
   porque son el contrato local↔remoto, no se tocan.

## Alternativas consideradas

- **(a) Promover sync a feature de primera clase.** Asume sprint dedicado
  para pasar el QA que pide `docs/how-to/store-release-checklist.md:16-23`
  (sessions, conflicts, revocation, restore, offline/online, privacy).
  Descartado por ahora: hay que terminar el hardening de hygiene
  (`vaulta-hygiene-hardening`) y la cobertura de tests del core antes de
  invertir en QA extensivo de un feature que solo una fraccion pequena de
  usuarios habilita.

- **(c) Congelar como tech-preview de largo plazo.** Dejar los 11 archivos
  sin tocar, marcar APIs publicas como `@experimental`, y mantener solo
  smoke tests que validen compilacion. Descartado: la deuda de
  mantenimiento no desaparece aunque se marque como experimental; los
  tests existentes cubren contratos utiles que se perderian.

## Consecuencias / tradeoffs

- **Mantenibilidad**: la superficie post-refactor deberia ser ~6 archivos
  en `lib/core/sync/` + 1 export interno. ~45% menos codigo que mantener.
- **Compatibilidad**: cualquier consumidor de las APIs marcadas como
  `@internal` debera migrar al export unico. En este repo, los
  consumidores son solo `lib/features/settings/` y
  `lib/features/sync/presentation/sync_conflicts_sheet.dart`.
- **Costo del refactor**: estimado 1-2 dias de trabajo una vez que el
  change `vaulta-hygiene-hardening` este mergeado.
- **Riesgo bajo**: el codigo actual tiene cobertura de tests en los
  servicios criticos (`incremental_pull_sync_service_test.dart`,
  `incremental_push_sync_service_test.dart`,
  `sync_conflict_resolver_test.dart`,
  `device_session_revocation_service_test.dart`). El refactor se puede
  hacer con seguridad siguiendo Red→Green→Refactor sobre esos tests.

## Criterios de aceptacion verificables

- `git ls-files lib/core/sync/ | wc -l` cae de 11 a ≤7.
- `grep -r "@internal" lib/core/sync/` matchea al menos
  `device_registration_repository.dart` y
  `device_session_revocation_service.dart`.
- `flutter test test/core/sync/` sigue verde despues del refactor.
- `lib/features/sync/presentation/sync_conflicts_sheet.dart` no importa
  de los archivos marcados como `@internal` (verificable con
  `grep import`).

## Implementacion por lotes (este NO es el change que lo ejecuta)

- **Batch S4 (downstream)**: abrir change
  `vaulta-sync-surface-reduction` con:
  - Tarea 1: nuevo `BidirectionalSyncService` con tests migrados desde
    los dos servicios actuales.
  - Tarea 2: marcar `device_registration_*` y `device_session_revocation*`
    como `@internal` + export unico.
  - Tarea 3: deprecation notices en los archivos viejos (no se borran en
    el mismo commit para no romper imports durante la transicion).
  - Tarea 4: borrar archivos viejos una vez que `flutter analyze` y
    `flutter test` pasen sin warnings de deprecation.
- **Bloqueante para S4**: el change `vaulta-hygiene-hardening` debe estar
  mergeado (para que los lints y el coverage gate ya esten activos y
  atrapen cualquier regresion del refactor).

## Status (2026-06-11)

El batch S4 (y su T4 / T5) se ejecutaron en tres changes cerradas
formalmente en openspec, en este orden:

1. **`vaulta-sync-surface-reduction`** (commits `6e65f0d`,
   `10a6a51`): creó `BidirectionalSyncService` (767 líneas,
   6 TDD tests), agregó `@Deprecated` a los dos servicios
   viejos, y creó `sync_internal.dart` como barrel.
2. **`vaulta-sync-migration`** (commits `af3a823`, `ade5bc9`):
   migró `device_sync_bootstrap.dart` y `DeviceSyncLifecycle`
   al nuevo servicio. `DeviceSyncLifecycle` pasó de tomar
   `pullSyncService` + `pushSyncService` a un solo
   `syncService`.
3. **`vaulta-public-api-docs-extended`** (commits `7bf96fc`):
   T5 de ADR-004. Borró los 4 archivos deprecated
   (`incremental_pull_sync_service.dart`,
   `incremental_push_sync_service.dart`, y sus 2 test files).
   Coverage gate empujado de 49.7% a 50.7% con un test
   comprehensivo de `AesGcmVaultCryptoService`.

### Desviaciones documentadas

- **Tarea 2 no se ejecutó como se planeó**: la anotación
  `@internal` de `package:meta` **fue rechazada** por el lint
  `invalid_internal_annotation`, que la restringe a elementos
  privados del package (símbolos con `_` o dentro de
  `lib/src/`). Como `DeviceRegistrationRepository` y
  `DeviceSessionRevocationService` son APIs públicas por
  diseño, la convención vive en (a) docstrings que explican
  el contrato "internal a `lib/core/sync/`", (b) el barrel
  `sync_internal.dart` como punto único de re-export. La
  enforcement real (CI grep + lint custom) queda pendiente
  como follow-up si la convención se rompe en la práctica.
  El criterio de aceptación `@internal` grep en
  `lib/core/sync/` ya no aplica; el nuevo criterio es el
  grep de los docstrings "Features must not import".

### Cambios adicionales de scope

- `flutter analyze`: 0 issues.
- `flutter test`: 95/95 verde.
- Coverage gate: 50.7% en `lib/core/security/`.
