# Proposal: vaulta-public-api-docs-extended

> Extiende `public_member_api_docs` de `lib/core/`
> (cerrado en `vaulta-public-api-docs`) a `lib/app/` y
> `lib/features/`, y cierra la deuda de 276 docstrings asociada.

## Intent

Cerrar la deuda de documentación que sigue afuera de `lib/core/`.
La regla `public_member_api_docs` ya está activa y funcional con
scope `lib/core/` (warning). Este change:

1. Cierra las **276 violaciones** que existen en `lib/app/` y
   `lib/features/` con docstrings consistentes.
2. Reactiva la regla para todo `lib/**` con severidad `warning`.
3. Justifica per-file las **dos** supresiones que sobreviven (los
   design tokens, que por ADR-005 usan `// ignore_for_file:` con
   justificación en lugar de 65 docstrings redundantes).

Resultado esperado: cualquier contribuidor que agregue una API
pública en `lib/` sin documentar rompe CI, en cualquier subfolder.

## Scope

### In Scope

- 276 docstrings en 20 archivos de `lib/app/` y `lib/features/`,
  distribuidos en commits atómicos por subárbol.
- Modificar `analysis_options.yaml` para remover las exclusiones
  de `lib/app/**` y `lib/features/**` y mantener la severidad
  `warning`.
- Aplicar `// ignore_for_file: public_member_api_docs` con
  justificación ADR-005 a `lib/app/theme/app_colors.dart` (42
  violaciones) y `lib/app/theme/app_spacing.dart` (23 violaciones).
- Incrementar la cobertura de `lib/core/security/` para que el
  coverage gate no quede en el filo del 50% tras la expansión
  del scope de la regla.

### Out of Scope

- Cambios en la lógica de la app o de las features.
- Extender la regla a `test/` (los tests son privados al paquete
  de test, no necesitan docstrings públicos).
- Activar otras reglas lint (`document_ignores`,
  `comment_references` se dejan para cambios futuros).
- Renombrar APIs o refactorizar firmas (solo se documenta lo que
  ya existe).

## Capabilities

### Modified Capabilities

- `lint-discipline` (de ADR-005): la regla
  `public_member_api_docs` ahora cubre todo `lib/**`. Las dos
  excepciones legítimas son los archivos de design tokens
  (`app_colors.dart`, `app_spacing.dart`) y se documentan como
  supresión intencional en el spec.

## Approach

### Fase 1: cerrar la deuda por subárbol

Cuatro commits independientes, mismo patrón (edits surgicales,
solo `///` lines, sin tocar lógica):

1. **`docs(features): add public API docstrings to vault subtree`**
   — cierra `lib/features/vault/` (8 archivos, 91 violaciones).
2. **`docs(features): add public API docstrings to security +
   access + settings + home + sync subtrees`** — cierra el resto
   de `lib/features/` (6 archivos, 33 violaciones).
3. **`chore(lint): reactivate public_member_api_docs for all lib`**
   — quita las exclusiones de `lib/app/**` y `lib/features/**` y
   documenta las 2 supresiones intencionales.
4. **`docs(app): add public API docstrings to design_system +
   theme + bootstrap + localization`** — cierra `lib/app/` (8
   archivos, 152 violaciones) usando `// ignore_for_file:` con
   justificación para los 2 archivos de design tokens.

### Fase 2: subir el coverage gate

El último commit (320ad09) del change
`vaulta-public-api-docs-extended` agrega un test comprehensivo
para `AesGcmVaultCryptoService` y `VaultSession` que cubre las
11 branches que dejaban al coverage gate en 49.7% — debajo del
umbral del 50% — en algunas corridas de CI.

### Fase 3: verificar

- `flutter analyze` retorna `No issues found!` con exit code 0.
- `flutter test` pasa con 95/95 tests verdes.
- Coverage gate retorna `OK: 50.7% >= 50% umbral` consistentemente
  en al menos 3 corridas locales y en CI.
- El commit `chore(lint): reactivate public_member_api_docs for
  all lib` deja `analyzer.exclude` con solo `**/*.g.dart` y
  `**/*.freezed.dart` (sin exclusiones por subfolder de
  aplicación).

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `analysis_options.yaml` | Modified | Quitar exclusiones de `lib/app/**` y `lib/features/**` |
| `lib/app/**` (8 archivos) | Modified | +152 docstrings o supresiones justificadas |
| `lib/features/**` (14 archivos) | Modified | +124 docstrings |
| `test/core/security/aes_gcm_vault_crypto_service_test.dart` | Created | +9 tests, +11 líneas de cobertura |
| ADR-005 (`docs/adr/0005-repository-hygiene-lints-and-coverage.md`) | Unchanged | La política de suppressions per-file ya estaba documentada |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Docstrings inconsistentes entre archivos | Medium | Plantilla fija: "qué hace" en una línea + detalles (parámetros, comportamiento, gotchas) en líneas siguientes. |
| Algún docstring rompe el build con referencias rotas (`[Foo]` apuntando a tipos inexistentes) | Low | Verificar con `flutter analyze` después de cada subárbol. |
| El `// ignore_for_file:` en design tokens se relaja en un commit futuro y reintroduce ruido | Low | ADR-005 prohíbe explícitamente relajar la supresión para nuevos tokens. Se verifica con `flutter analyze` en CI. |
| Coverage gate queda flaky en el 50% | Medium | Test comprehensivo de crypto service empuja el coverage a 50.7% y se verifica en 3 corridas. |

## Rollback Plan

- Revertir el commit `chore(lint): reactivate public_member_api_docs
  for all lib` reintroduce las exclusiones en
  `analysis_options.yaml`. Los 276 docstrings pueden quedarse
  (son útiles per se) o revertirse junto con el commit de
  `docs(features): vault subtree`, en orden inverso.
- No hay data corruption posible: los docstrings son
  comentarios y las supresiones son explícitas.

## Success Criteria

- [x] `flutter analyze` retorna `No issues found!` con exit code
      0 tras aplicar los 4 commits del change.
- [x] `flutter test` pasa con 95/95 tests verdes.
- [x] Coverage gate retorna `OK: 50.7% >= 50% umbral`
      consistentemente.
- [x] Los 2 archivos de design tokens tienen
      `// ignore_for_file: public_member_api_docs` con justificación
      ADR-005 explícita.
- [x] `analyzer.exclude` queda con solo `**/*.g.dart` y
      `**/*.freezed.dart` (sin exclusiones por subfolder de
      aplicación).
- [x] CI workflow `Flutter CI` retorna success en el push del
      último commit.
- [x] Cuatro commits en master, en orden: docs-features-vault,
      docs-features-rest, chore-lint-reactivate, docs-app.

## Estimación de la deuda (medida en dry-run)

Baseline medido durante la ventana de activación abortada del
2026-06-11 (commit `fb52b98` revertido en `7d5a268`):

| Subfolder | Archivos | Violaciones |
|-----------|----------|-------------|
| `lib/app/design_system/` | 4 | 58 |
| `lib/app/theme/` | 2 | 65 |
| `lib/app/localization/` | 2 | 8 |
| `lib/app/bootstrap/` | 1 | 8 |
| `lib/features/access/` | 1 | 3 |
| `lib/features/home/` | 1 | 14 |
| `lib/features/security/` | 1 | 4 |
| `lib/features/settings/` | 2 | 10 |
| `lib/features/sync/` | 1 | 1 |
| `lib/features/vault/` | 8 | 91 |
| **Total** | **20** | **276** |

Las 65 violaciones de los dos archivos de design tokens se
cierran vía `// ignore_for_file:` con justificación, no vía
docstrings individuales. Las 211 violaciones restantes se
cierran con docstrings en 4 commits.
