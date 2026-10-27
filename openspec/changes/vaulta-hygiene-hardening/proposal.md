# Proposal: Vaulta hygiene hardening

> Cierra 6 brechas de hygiene del repositorio Vaulta: ignores de
> artefactos de build, coherencia del README con LICENSE, lints
> adicionales, coverage gate en CI, decisión de roadmap para
> `lib/core/sync/`, y widget tests para 3 pantallas presentation-level.

## Intent

Endurecer el repositorio en dimensiones concretas y medibles:

1. **Repo hygiene**: los artefactos de build locales (APK de 57 MB,
   EXE, DMG) no pueden entrar al repo vía `git add` accidental.
2. **Documentación coherente**: el `README.md` no contradice al
   `LICENSE` real (MIT, Copyright 2026 Rene Kuhm).
3. **Lints activos**: `analysis_options.yaml` va más allá de
   `flutter_lints` por defecto, adecuado a una app de seguridad.
4. **Coverage gate**: CI mide cobertura en `lib/core/security/` con
   umbral mínimo exigible.
5. **Roadmap sync**: ADR-004 documenta la decisión binaria sobre
   `lib/core/sync/` (reducir superficie, no promover ni congelar).
6. **Widget test coverage**: las 3 pantallas presentation-level sin
   test dedicado tienen al menos un testWidgets que ejercita el
   path más común.

## Scope

### In Scope

- `.gitignore` raíz: patrones para `*.apk`, `*.exe`, `*.dmg`.
- `README.md` sección Licencia: reescrita para apuntar a MIT.
- `analysis_options.yaml`: 4 reglas adicionales
  (`prefer_const_constructors`, `prefer_const_declarations`,
  `unawaited_futures`, `avoid_dynamic_calls`).
- `// ignore_for_file: <rule>` con justificación en 14 archivos
  donde las reglas nuevas generan violaciones legítimas.
- `.github/workflows/flutter-ci.yml`: step de coverage.
- `scripts/check_coverage.sh`: script bash que valida
  `coverage/lcov.info` contra umbral sobre `lib/core/security/`.
- `docs/adr/0004-sync-layer-roadmap.md`: decisión de roadmap.
- `docs/adr/0005-repository-hygiene-lints-and-coverage.md`: política de lints.
- 3 tests de widget siguiendo el patrón de
  `vault_dashboard_screen_test.dart`.

### Out of Scope

- Cambios en la lógica de cifrado o de unlock.
- Cambios en el vault format (v2 sigue intacto).
- Refactor de la capa sync (eso es
  `vaulta-sync-surface-reduction`, un change aparte basado en la
  decisión de ADR-004).
- Docstrings en APIs públicas de `lib/app/` o `lib/features/`
  (eso es `vaulta-public-api-docs` y su follow-up
  `vaulta-public-api-docs-extended`).
- iOS / macOS / web (siguen en master-password only).

## Capabilities

### New Capabilities

- `repo-hygiene`: ignores, README, disciplina de no commitear
  artefactos de build locales.
- `test-coverage-gate`: cobertura medida en CI con umbral
  configurable (default 50% sobre `lib/core/security/`, plan
  trimestral para expandir).
- `lint-discipline`: 4 reglas adicionales activas en
  `analysis_options.yaml` con estrategia gradual documentada
  (ADR-005).
- `widget-test-coverage`: cobertura de widget tests para
  `AccessScreen`, `AppShell`, `SyncConflictsSheet`.

### Modified Capabilities

- `ci-pipeline` (implícita en `flutter-ci.yml`): agrega step de
  coverage con validación de umbral.

## Approach

### Fase 1: repo hygiene (T1 + T2 + T6)

- T1: `.gitignore` cubre `*.apk`, `*.exe`, `*.dmg`. El APK de 57 MB
  preexistente queda ignorado retroactivamente.
- T2: README sección Licencia reescrita. Frase obsoleta sobre
  "definir licencia formal" eliminada.
- T6: ADR-005 (`docs/adr/0005-repository-hygiene-lints-and-coverage.md`)
  documenta la política de lints gradual con
  `// ignore_for_file:` y la estrategia de coverage gate.

### Fase 2: lint discipline (T3)

- 4 reglas agregadas a `analysis_options.yaml`.
- 14 archivos reciben `// ignore_for_file: <rule>` con comentario
  breve que justifica la deuda (las reglas son obligatorias
  hacia adelante; las violaciones existentes se cierran
  gradualmente en cambios posteriores).
- `public_member_api_docs` (739 violaciones en 50+ archivos)
  retirado de este change y diferido a
  `vaulta-public-api-docs` por magnitud.

### Fase 3: coverage gate (T4)

- `flutter test --coverage` produce `coverage/lcov.info`.
- `scripts/check_coverage.sh` valida el archivo contra umbral
  sobre `lib/core/security/`.
- Baseline medido: 52.4% (532/1015 líneas en 13 archivos).
- Umbral conservador: 50% inicial, plan trimestral para
  expandir.

### Fase 4: roadmap sync (T5)

- ADR-004 creado con decisión **(b) Reducir superficie**.
- Alternativas (a) promover y (c) congelar documentadas con
  motivos de descarte.
- Tareas downstream (consolidación de pull/push en
  `BidirectionalSyncService`, marcado de `device_registration_*`
  como internal) listadas como follow-up, no como trabajo de
  este change.

### Fase 5: widget tests (T7 + T8 + T9)

- 3 tests siguiendo el patrón de
  `test/features/vault/presentation/vault_dashboard_screen_test.dart`
  (fakes + in-memory services, sin platform channels reales).
- Viewport 1080x4000 necesario para AccessScreen (el CTA "Lock
  vault now" está debajo del fold por default).
- `_SyncConflictsSheet` es privada; el test dispara la API
  pública `showSyncConflictsSheet` con un fake resolver.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `.gitignore` | Modified | +11 patrones de ignore |
| `README.md` | Modified | Sección Licencia reescrita |
| `analysis_options.yaml` | Modified | +4 reglas de lint |
| 14 archivos en `lib/**` y `test/**` | Modified | `// ignore_for_file: <rule>` con justificación |
| `.github/workflows/flutter-ci.yml` | Modified | +1 step de coverage |
| `scripts/check_coverage.sh` | New | 58 líneas, valida `lcov.info` con awk |
| `docs/adr/0004-sync-layer-roadmap.md` | New | 110 líneas, decisión de roadmap sync |
| `docs/adr/0005-repository-hygiene-lints-and-coverage.md` | New | 154 líneas, política de hygiene |
| `test/features/access/presentation/access_screen_test.dart` | New | 108 líneas, widget test |
| `test/features/home/presentation/app_shell_test.dart` | New | 118 líneas, widget test |
| `test/features/sync/presentation/sync_conflicts_sheet_test.dart` | New | 61 líneas, widget test |

## Risks

| Risk | Mitigation aplicada |
|------|---------------------|
| Lints nuevos rompen CI con muchas violaciones | Rollout gradual con `// ignore_for_file:` por archivo. Las reglas quedan activas inmediatamente. |
| Umbral de coverage mal calibrado | Baseline real medido (52.4%). Umbral conservador 50% inicial. Plan trimestral en ADR-005. |
| Tests nuevos flaky por async / platform channels | Patrón de fakes ya usado en `widget_test.dart`. Sin platform channels reales. |
| El APK en root se commitea entre el merge y el próximo `git pull` | Push inmediato del `.gitignore` actualizado. |
| `// ignore_for_file:` se relaja en un commit futuro | ADR-005 prohíbe explícitamente relajar la supresión para código nuevo sin documentar. |

## Rollback Plan

- `.gitignore`, `README.md`, `analysis_options.yaml`,
  `.github/workflows/flutter-ci.yml`: revert del commit del change.
- `scripts/check_coverage.sh`, `docs/architecture/ADR-004*.md`,
  `docs/architecture/ADR-005*.md`: borrar archivos (no rompen
  nada).
- Tests nuevos: borrar archivos (no rompen nada; el resto del
  coverage se mantiene).

## Success Criteria

- [x] `git check-ignore vaulta.apk` retorna el path con patrón
      matched.
- [x] `flutter analyze` retorna `No issues found!` con las 4
      reglas nuevas activas.
- [x] CI corre `flutter test --coverage` y valida umbral sobre
      `lib/core/security/`.
- [x] README sección Licencia referencia MIT correctamente.
- [x] ADR-004-roadmap-sync.md existe con decisión binaria
      documentada.
- [x] 3 tests de widget nuevos pasan con `flutter test`.
- [x] 86 tests verdes (eran 83, +3 nuevos).
- [x] Coverage gate en `OK: 52.4% >= 50% umbral`.

## Commits del change

1. `58fc984` — `chore(repo): ignore build artifacts, fix license
   section, scaffold hygiene ADRs` (T1, T2, T5, T6)
2. `1f9a52d` — `chore(lint): enable stricter rules with gradual
   ignore_for_file rollout` (T3)
3. `e6ac2c3` — `ci(coverage): add threshold gate on
   lib/core/security with quarterly plan` (T4)
4. `8d63eee` — `test(widget): cover access, shell, and sync
   conflicts screens` (T7, T8, T9)

## Trabajo downstream (posterior, en otros changes)

- Cerrar las 739 violaciones de `public_member_api_docs` por
  subfolder → `vaulta-public-api-docs` →
  `vaulta-public-api-docs-extended`.
- Reducir la superficie de `lib/core/sync/` →
  `vaulta-sync-surface-reduction` (T1, T2, T3 de ADR-004).
- Migrar los consumers de los servicios viejos de sync al
  `BidirectionalSyncService` → `vaulta-sync-migration` (T4 de
  ADR-004).
- Borrar los servicios viejos de sync → T5 de ADR-004 (parte de
  `vaulta-public-api-docs-extended` o change aparte).
