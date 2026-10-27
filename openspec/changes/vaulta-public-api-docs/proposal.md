# Proposal: vaulta-public-api-docs

> Implementación del follow-up de ADR-005 (Política de lints).
> Cierra la activación de `public_member_api_docs` para
> `lib/core/` con scope y docstrings consistentes.

## Intent

Activar la regla `public_member_api_docs` limitada a `lib/core/`
(mediante `analyzer.exclude` del resto del proyecto) y agregar
docstrings a todas las APIs públicas que la regla considere
subdocumentadas. Resultado: cualquier contribuidor que agregue
una API pública en `lib/core/` sin documentar rompe CI.

Referencia: `docs/adr/0005-repository-hygiene-lints-and-coverage.md` sección
"Política de lints".

## Scope

### In Scope

- Activar `public_member_api_docs` en `analysis_options.yaml`
  con `analyzer.exclude` que cubra todo lo que NO sea
  `lib/core/`.
- Docstrings consistentes (1-3 líneas, que digan **qué** y
  **por qué**, no solo el nombre reescrito) en las APIs
  públicas de:
  - `lib/core/security/` (13 archivos)
  - `lib/core/sync/` (16 archivos, incluye
    `bidirectional_sync_service.dart` y `sync_internal.dart`)
  - `lib/core/update/` (1 archivo, `update_service.dart`)
- Severidad final: `warning` (no `info`). Pasamos por `info`
  durante el rollout para dimensionar la deuda sin romper
  CI, y al final se restauró a `warning`.
- 4 commits independientes, uno por fase, para que cada uno
  sea reviewable.

### Out of Scope

- Docstrings en `lib/app/` o `lib/features/` (la regla solo
  aplica a `lib/core/` en este change; el follow-up
  `vaulta-public-api-docs-extended` la extiende).
- Refactor de APIs (no se cambian firmas, solo se documentan).
- Activación de otras reglas (`depend_on_referenced_packages`
  ya está manejada con `// ignore_for_file:` cuando aplica,
  mismo patrón que en `incremental_push_sync_service.dart`).

## Capabilities

### Modified Capabilities

- `lint-discipline` (de ADR-005): se agrega la regla
  `public_member_api_docs` con `analyzer.exclude` por scope.

## Approach

### Fase 1: activar la regla con scope

```yaml
# analysis_options.yaml
analyzer:
  errors:
    public_member_api_docs: warning
  exclude:
    - "**/*.g.dart"
    - "**/*.freezed.dart"
    - "lib/app/**"
    - "lib/features/**"
```

Esto deja la regla activa solo para `lib/core/**`.

### Fase 2: docstrings por subfolder

3 commits independientes, mismo patrón:

1. **Commit 1**: `docs(security): add public API docstrings`
   cubre los 13 archivos de `lib/core/security/`. Activación
   inicial con severidad `info` para dimensionar la deuda sin
   romper CI.
2. **Commit 2**: `docs(core): add public API docstrings to
   sync and update subtrees` cubre el grueso de
   `lib/core/sync/` y `lib/core/update/`.
3. **Commit 3**: `docs(sync): add public API docstrings to
   remaining sync files` cierra los últimos archivos de
   `lib/core/sync/` que quedaron sin documentar en Commit 2.

Estilo de docstrings (consistente en los 3 commits):

```dart
/// <Qué hace la API en una línea>.
///
/// <Detalles: parámetros notables, comportamiento, relaciones
/// con otras APIs, gotchas>. Usar bloques de código solo si
/// ayudan.
```

### Fase 3: restaurar `warning` y cerrar el change

Una vez que `flutter analyze` lista 0 issues con severidad
`info` en `lib/core/**`, se restaura la severidad a `warning`
en `analysis_options.yaml`. A partir de acá, cualquier nuevo
miembro público sin docstring rompe CI con exit code 1.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `analysis_options.yaml` | Modified | +`public_member_api_docs` +`analyzer.exclude` |
| `lib/core/security/*.dart` (13 files) | Modified | +docstrings |
| `lib/core/sync/*.dart` (16 files) | Modified | +docstrings |
| `lib/core/update/update_service.dart` | Modified | +docstrings |
| `openspec/changes/vaulta-public-api-docs/{tasks.md,proposal.md}` | Modified | Change artifacts |

## Risks

| Risk | Mitigation |
|------|------------|
| El baseline de violaciones es muy alto (>500) y el PR queda opaco | Split en 3 commits por subfolder. Activación inicial con `info` severity para no romper CI mientras se cierra la deuda. |
| Docstrings inconsistentes entre archivos | Plantilla fija: "qué hace" en una línea + detalles. |
| `analyzer.exclude` rompe algo por path matching | Probado con `flutter analyze` después de aplicar. |
| `public_member_api_docs` exige documentar miembros heredados | El lint no pide override de docs en overrides (verificado con dry-run). |
| Tests de servicios viejos fallen porque el cambio toca sus imports | Solo se agregan docstrings, no se cambia lógica. Tests verdes confirmados. |

## Rollback Plan

- Revert de los 4 commits (separados, fáciles de identificar).
- `analysis_options.yaml` vuelve a la versión sin la regla.

## Dependencies

- `flutter analyze` 3.x o superior (soportado, ya en uso).
- `package:meta` para `@immutable` (ya en uso).

## Success Criteria

- [x] `flutter analyze` retorna `No issues found!` con
      severidad `warning` activa y todos los docstrings en su
      lugar.
- [x] `flutter test` pasa con 92/92 tests verdes.
- [x] Coverage gate sigue en `OK: 52.4% >= 50%`.
- [x] `git diff --stat lib/core/` muestra cambios solo de
      docstrings (líneas que empiezan con `///`).
- [x] 4 commits en master (3 de docstrings + 1 de restore
      warning), mensajes conventional.
- [x] La regla se enforcea desde el próximo PR: cualquier API
      pública nueva en `lib/core/**` sin docstring rompe CI.

## Commits del change (en orden cronológico)

1. `69b4291` — `docs(security): add public API docstrings`:
   13 archivos de `lib/core/security/` + activación inicial
   de la regla con `info` severity.
2. `7312114` — `docs(core): add public API docstrings to
   sync and update subtrees`: grueso de `lib/core/sync/` y
   `lib/core/update/update_service.dart`.
3. `c3c2f8e` — `docs(adr): scaffold vaulta-public-api-docs
   change artifact`: scaffolding de los artifacts del change.
4. `1459f20` — `docs(adr): reflect partial state of
   vaulta-public-api-docs`: tasks.md refleja el estado
   parcial.
5. `fad7adc` — `docs(sync): add public API docstrings to
   remaining sync files`: últimos archivos de
   `lib/core/sync/`.
6. `2b32dd8` — `chore(lint): restore public_member_api_docs
   warning severity and mark change complete`: severidad
   vuelve a `warning` y tasks.md final.

## Trabajo downstream

- Considerar extender la regla a `lib/app/` y
  `lib/features/` en un follow-up aparte, con su propio
  scoping y plan gradual, dado que la deuda actual allí es
  mucho mayor que en `lib/core/`. Este follow-up es
  `vaulta-public-api-docs-extended`.
