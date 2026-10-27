# Tasks: vaulta-hygiene-hardening

> Change cerrado. Los 4 commits del plan se aplicaron en orden.
> CI retorna success, 86 tests verdes, coverage gate en
> `OK: 52.4% >= 50%`.

## Estado: COMPLETO (2026-06-11)

## Commits del change (en orden cronológico)

| # | Commit | Mensaje | Cubre |
|---|--------|---------|-------|
| 1 | `58fc984` | `chore(repo): ignore build artifacts, fix license section, scaffold hygiene ADRs` | T1, T2, T5, T6 |
| 2 | `1f9a52d` | `chore(lint): enable stricter rules with gradual ignore_for_file rollout` | T3 |
| 3 | `e6ac2c3` | `ci(coverage): add threshold gate on lib/core/security with quarterly plan` | T4 |
| 4 | `8d63eee` | `test(widget): cover access, shell, and sync conflicts screens` | T7, T8, T9 |

## Tasks por spec

### T1 — Ignorar artefactos de build en `.gitignore`

- **Spec**: REQ-HYG-001
- **Scenarios**:
  - "vaulta.apk queda ignorado"
  - "ignorar otros binarios comunes"
- **File**: `.gitignore` (root)
- **Change**: +11 patrones de ignore. Cubre `/vaulta.apk`,
  `*.apk`, `*.exe`, `*.dmg`, y otros artefactos de Flutter.
- **Verify**: `git check-ignore -v vaulta.apk` retorna patrón
  matched.
- **Estado**: COMPLETO en `58fc984`.

### T2 — Corregir sección Licencia del README

- **Spec**: REQ-HYG-002
- **Scenario**: "Sección Licencia del README referencia MIT"
- **File**: `README.md` (líneas 204-206)
- **Change**: reescrita para referenciar MIT (Copyright 2026
  Rene Kuhm). Frase obsoleta "Definir una licencia formal antes
  de aceptar contribuciones externas" eliminada.
- **Verify**: `Select-String -Path README.md -Pattern
  "Definir una licencia formal"` retorna vacío.
- **Estado**: COMPLETO en `58fc984`.

### T3 — Endurecer `analysis_options.yaml`

- **Spec**: REQ-LINT-001
- **Scenario**: "analyze sigue limpio después del endurecimiento"
- **File**: `analysis_options.yaml`
- **Change**: agregadas 4 reglas — `prefer_const_constructors`,
  `prefer_const_declarations`, `unawaited_futures`,
  `avoid_dynamic_calls`. `public_member_api_docs` (739
  violaciones) retirado y diferido a
  `vaulta-public-api-docs`.
- **Rollout**: gradual con `// ignore_for_file: <rule>` en 14
  archivos donde las reglas generan violaciones legítimas.
  Cada supresión tiene un comentario breve que justifica la
  deuda.
- **Verify**: `flutter analyze` retorna `No issues found!` con
  exit code 0.
- **Estado**: COMPLETO en `1f9a52d`.

### T4 — Step de coverage en CI con umbral

- **Spec**: REQ-COV-001, REQ-COV-002
- **Scenarios**:
  - "PR con cobertura suficiente pasa"
  - "PR que baja la cobertura del core falla"
- **Files**:
  - `.github/workflows/flutter-ci.yml` (modified, +8 líneas)
  - `scripts/check_coverage.sh` (new, 58 líneas)
- **Change**: agregar step `flutter test --coverage` + script
  bash que valida `coverage/lcov.info` con awk sobre
  `lib/core/security/`.
- **Baseline real**: 52.4% (532/1015 líneas en 13 archivos).
- **Umbral inicial**: 50% (conservador). Plan trimestral en
  ADR-005 para expandir.
- **Bug encontrado y corregido durante implementación**: el
  script awk usaba `$2 + 0` cuando el formato `lcov.info` es
  `LF:N` con `:` no espacio. Fixed a `substr($0, 4) + 0`.
- **Verify**: script retorna exit 0 con 50% (cubre baseline),
  exit 1 con 55% (atraparía regresión).
- **Estado**: COMPLETO en `e6ac2c3`.

### T5 — ADR-004: decisión de roadmap para la capa sync

- **File**: `docs/adr/0004-sync-layer-roadmap.md` (new,
  110 líneas)
- **Decisión del usuario**: **(b) Reducir superficie**.
- **Alternativas documentadas**:
  - (a) Promover: descartada por magnitud (15 archivos,
    falta de testing de integración end-to-end).
  - (c) Congelar: descartada por riesgo de deuda técnica
    acumulada.
- **Tareas downstream listadas en el ADR** (no ejecutadas
  acá):
  - T1: `BidirectionalSyncService` consolidando pull + push.
  - T2: `@internal` + export `sync_internal.dart`.
  - T3: deprecation notices en servicios viejos.
  - T4: migrar consumers (DeviceSyncLifecycle, bootstrap).
  - T5: borrar servicios viejos.
- **Verify**: el ADR existe, tiene fecha, estado "Aprobado",
  alternativas descartadas con motivo, referencia a T1-T5.
- **Estado**: COMPLETO en `58fc984`.

### T6 — ADR menor: registrar este change

- **File**: `docs/adr/0005-repository-hygiene-lints-and-coverage.md` (new,
  154 líneas)
- **Purpose**: dejar registro de por qué se decidió el rollout
  de lints gradual, el umbral de coverage conservador y la
  regla de gitignore. Política de hygiene explícita.
- **Estado**: COMPLETO en `58fc984`.

### T7 — Widget test: AccessScreen

- **Spec**: REQ-WT-001
- **Scenario**: "AccessScreen testea el estado inicial"
- **File**: `test/features/access/presentation/access_screen_test.dart`
  (new, 108 líneas)
- **TDD**: Red → Green → Refactor.
- **Gotcha**: viewport 1080x4000 necesario para que el CTA
  "Lock vault now" sea visible (debajo del fold por default).
  `AppSectionHeader` aplica `.toUpperCase()` al eyebrow
  (`"Autofill & access"` se renderiza como
  `"AUTOFILL & ACCESS"`).
- **Estado**: COMPLETO en `8d63eee`.

### T8 — Widget test: AppShell

- **Spec**: REQ-WT-001
- **Scenario**: "AppShell testea la navegación"
- **File**: `test/features/home/presentation/app_shell_test.dart`
  (new, 118 líneas)
- **Verify**: `flutter test test/features/home/presentation/app_shell_test.dart`
  pasa.
- **Estado**: COMPLETO en `8d63eee`.

### T9 — Widget test: SyncConflictsSheet

- **Spec**: REQ-WT-001
- **Scenario**: "SyncConflictsSheet testea la lista vacía"
- **File**: `test/features/sync/presentation/sync_conflicts_sheet_test.dart`
  (new, 61 líneas)
- **Gotcha**: `_SyncConflictsSheet` es privada; el test dispara
  la API pública `showSyncConflictsSheet` con un fake resolver
  que retorna lista vacía. Verifica el empty state localizado.
- **Estado**: COMPLETO en `8d63eee`.

## Verificación final

- `flutter analyze`: `No issues found!` con exit code 0.
- `flutter test`: 86/86 tests verdes.
- Coverage gate: `OK: 52.4% >= 50% umbral` sobre
  `lib/core/security/`.
- CI workflow `Flutter CI`: success.
- 4 commits en master con mensajes conventional.

## Lecciones aprendidas

- **Coverage script gotcha**: `lcov` formato es `LF:N`
  (colon-separated), no space-separated. awk requiere
  `substr($0, 4) + 0`, no `$2 + 0`. Documentado en el script.
- **Gradual lint rollout funciona**: `// ignore_for_file:`
  con justificación corta es suficiente para mantener CI
  verde mientras se cierra la deuda en cambios futuros.
- **`public_member_api_docs` se difiere por magnitud**:
  739 violaciones en 50+ archivos no es gradual. Se abrió
  un change aparte (`vaulta-public-api-docs`) con plan
  incremental por subfolder.
- **Test de widget con viewport custom**: el test
  `AccessScreen` necesita 1080x4000 para ver el CTA inferior.
  Patrón a documentar para tests de pantallas largas.
- **Specs de capabilities múltiples en un solo archivo**:
  `spec.md` agrupa los 4 capabilities del change
  (repo-hygiene, lint-discipline, test-coverage-gate,
  widget-test-coverage) con secciones separadas, en lugar
  de un archivo por capability.
