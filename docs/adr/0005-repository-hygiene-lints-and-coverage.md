# ADR-005: Hygiene de repositorio, lints y cobertura

- Estado: Aprobado
- Fecha: 2026-06-11

## Contexto

El proyecto Vaulta llega a su MVP publico (1.0.21) con criptografia solida,
arquitectura Clean y tests reales sobre el core. Sin embargo, el repositorio
tiene varias brechas de hygiene que no son bugs pero si deuda operativa:

1. `vaulta.apk` (57 MB) vive en la raiz del working tree, sin regla de
   `.gitignore` que lo cubra. Aunque hoy no esta trackeado por git
   (`git status` lo marca como untracked), un `git add .` distraido lo
   commitea.
2. La seccion "Licencia" del README contradice al archivo `LICENSE`
   real (MIT, Copyright 2026 Rene Kuhm).
3. El CI corre `flutter analyze` y `flutter test` en cada PR pero no mide
   cobertura, asi que "hay tests" es una afirmacion sin respaldo empirico.
4. `analysis_options.yaml` solo activa `package:flutter_lints/flutter.yaml`
   por defecto, sin endurecimiento adicional pese a ser una app de
   seguridad.
5. La capa `lib/core/sync/` esta sobredimensionada para algo etiquetado
   como experimental (ver ADR-004).
6. Faltan tests de widget para `access_screen`, `app_shell` y
   `sync_conflicts_sheet`.

## Decision

Se ejecuta el change `vaulta-hygiene-hardening` que cierra los seis
puntos con las siguientes politicas:

### Politica de artefactos locales

- `.gitignore` raiz ignora `/vaulta.apk`, `*.apk`, `*.aab`, `*.exe`,
  `*.dmg`, `*.pkg`, `*.msi`. Los artefactos de release viven en GitHub
  Releases, no en el repo.
- Si aparece un binario en la raiz, es un recordatorio de que algo se
  construyo localmente; no se commitea.

### Politica de documentacion de licencia

- El `LICENSE` en la raiz es la fuente de verdad.
- El README referencia al `LICENSE` y a la licencia MIT explicitamente.
- Cualquier cambio de licencia se hace primero en el archivo `LICENSE`
  y despues se actualiza el README; nunca al reves.

### Politica de lints

- Se agregan a `analysis_options.yaml`: `prefer_const_constructors`,
  `prefer_const_declarations`, `unawaited_futures`, `avoid_dynamic_calls`.
- **`public_member_api_docs` se difiere** al change
  `vaulta-public-api-docs` (follow-up). Razon: el baseline tiene ~739
  miembros publicos sin documentar en 50+ archivos, lo que excede el
  ambito de un rollout gradual. El follow-up limitara la regla a
  `lib/core/` (vía `analyzer.include`) y agregara documentacion por
  modulos en commits separados.
- **Estrategia de rollout: gradual con `// ignore_for_file:`**. Las
  reglas quedan activas inmediatamente. Las violaciones en archivos
  existentes se suprimen archivo por archivo con
  `// ignore_for_file: <rule_name>`. El codigo nuevo que toque esos
  archivos debe cumplir la regla; las supresiones nuevas se permiten
  solo si estan justificadas en un comentario adyacente.
- `flutter analyze` debe retornar 0 issues en cada PR.

### Politica de cobertura

- CI corre `flutter test --coverage` y genera `coverage/lcov.info`.
- Un script (`scripts/check_coverage.sh`) parsea el lcov, suma `LF`/`LH`
  para los archivos bajo `lib/core/security/`, y compara contra el umbral.
- **Umbral inicial: 50% en `lib/core/security/`** (2.4 puntos por debajo
  del baseline real medido en 2026-06-11, que es 52.4%). El baseline se
  registro en la implementacion de este change; ver tambien
  `coverage/lcov.info` post-merge.
- **Plan trimestral** (subir 5pp por trimestre, target 70% en Q2 2027):
  - Q3 2026 (jul-sep): 55%
  - Q4 2026 (oct-dic): 60%
  - Q1 2027 (ene-mar): 65%
  - Q2 2027 (abr-jun): 70%
- **Sin umbral global** en el primer corte. La cobertura de `lib/app/`
  (85%) y `lib/features/` (64.8%) es desigual; un umbral global
  bloquearia PRs legitimos. Foco en el core de seguridad primero.
- Las metricas de las demas areas (`lib/core/sync/`, `lib/core/update/`,
  `lib/app/`, `lib/features/`) se imprimen en el log del step para
  visibilidad, pero no bloquean.

### Politica de widget tests

- Toda pantalla en `lib/features/<x>/presentation/<screen>.dart` tiene
  al menos un `testWidgets` correspondiente en
  `test/features/<x>/presentation/<screen>_test.dart`.
- El patron a seguir es el de
  `test/features/vault/presentation/vault_dashboard_screen_test.dart`:
  fakes para servicios, in-memory storage, sin platform channels reales.

## Alternativas consideradas

- **No cerrar las brechas de hygiene ahora.** Descartado: el proyecto
  esta en release publico, y "release-ready con deuda visible" genera
  senales mezcladas a futuros contribuidores y reviewers.
- **Endurecer lints con fix-in-place total.** Descartado: el codebase
  tiene >50 archivos `.dart`; un PR con cientos de fixes mezcla la
  subida de reglas con la limpieza, dificulta la review y el rollback.
- **Coverage global desde el dia 1.** Descartado: forzaria exclusiones
  masivas (`// coverage:ignore-file`) en features con tests debiles,
  ensuciando el lcov con ruido. Mejor focalizar en el core primero.
- **Forzar el refactor de sync dentro de este change.** Descartado:
  mezclar hygiene con refactor de un subsistema vuelve el PR opaco.
  El refactor de sync se hace en su propio change
  (`vaulta-sync-surface-reduction`, ver ADR-004) una vez que este
  hygiene hardening este mergeado.

## Consecuencias / tradeoffs

- **Disciplina visible**: el proyecto pasa de "funciona" a "funciona y
  se puede medir / se mide".
- **Friccion minima en code review**: los `// ignore_for_file:` son
  senales explícitas de deuda que se revisan en cada PR.
- **Costo de mantenimiento del script de coverage**: bajo. Es un
  parser de lcov con un threshold hardcodeado.
- **Ritmo de convergencia al 85% de cobertura en el core**: depende de
  cadencia de PRs; se estima 2-3 trimestres con la politica gradual.

## Criterios de aceptacion verificables

- `git check-ignore -v vaulta.apk` retorna un patron matched de
  `.gitignore`.
- `git check-ignore -v vaulta.exe` retorna un patron matched.
- `flutter analyze` retorna `No issues found!` despues del endurecimiento
  con las 4 reglas activas y las supresiones aplicadas.
- El step de coverage esta en `.github/workflows/flutter-ci.yml` y se
  ejecuta en cada PR.
- `flutter test test/features/access/presentation/access_screen_test.dart`
  pasa.
- `flutter test test/features/home/presentation/app_shell_test.dart`
  pasa.
- `flutter test test/features/sync/presentation/sync_conflicts_sheet_test.dart`
  pasa.
- `docs/adr/0004-sync-layer-roadmap.md` existe y referencia este
  ADR como prerequisito.
- `docs/adr/0005-repository-hygiene-lints-and-coverage.md` (este archivo) esta
  indexado en `docs/adr/README.md`.

## Implementacion por lotes

Este change (`vaulta-hygiene-hardening`) se ejecuta en una sola ronda.
El orden de tareas prioriza lo que NO tiene riesgo de romper el build:

- **Lote 1 (sin riesgo)**: T1 (`.gitignore`), T2 (README), T6 (este ADR),
  T7/T8/T9 (widget tests), T5 (ADR-004 sync).
- **Lote 2 (riesgo medio)**: T3 (lints) con dry-run previo de
  `flutter analyze` y supresiones graduadas.
- **Lote 3 (riesgo bajo)**: T4 (coverage step en CI) una vez que el
  umbral inicial esta calibrado contra la cobertura actual.

## Status (2026-06-11)

Este ADR se ejecutó en el change `vaulta-hygiene-hardening`
(commits `58fc984`, `1f9a52d`, `e6ac2c3`, `8d63eee`), y las
políticas aquí documentadas se extendieron o se cumplieron
en tres changes posteriores que también están cerradas en
openspec:

### Política de lints

- `public_member_api_docs` ya **NO se difiere**. Se activó
  en el change `vaulta-public-api-docs` (commits `69b4291`,
  `7312114`, `c3c2f8e`, `1459f20`, `fad7adc`, `2b32dd8`) con
  scope `lib/core/**` y severidad `warning`, y se extendió a
  todo `lib/**` en `vaulta-public-api-docs-extended`
  (commits `11c7191`, `3bc0e12`, `09b072c`, `f4632aa`,
  `320ad09`, `e5d2d16`).
- La deuda de 276 docstrings en `lib/app/` y `lib/features/`
  se cerró siguiendo la estrategia gradual: 4 commits
  separados por subárbol + 1 commit final de reactivación de
  la regla.
- 2 archivos de design tokens
  (`lib/app/theme/app_colors.dart`,
  `lib/app/theme/app_spacing.dart`) usan
  `// ignore_for_file: public_member_api_docs` con
  justificación ADR-005 explícita. La supresión está
  prohibida relajar para nuevos tokens sin actualizar este
  ADR.

### Política de cobertura

- Cobertura actual de `lib/core/security/`: **50.7%** (504 +
  11 líneas cubiertas con el test de
  `AesGcmVaultCryptoService` agregado en `320ad09`).
- Plan trimestral vigente (medido desde el baseline 52.4%
  del 2026-06-11):
  - Q3 2026 (jul-sep): 55% — pendiente.
  - Q4 2026 (oct-dic): 60% — pendiente.
  - Q1 2027 (ene-mar): 65% — pendiente.
  - Q2 2027 (abr-jun): 70% — pendiente.
- El coverage gate de CI se ejecuta en cada push a `master`
  via `.github/workflows/flutter-ci.yml` →
  `analyze-test` job → `Check core coverage threshold` step
  → `scripts/check_coverage.sh` con umbral 50%.
- El gate mide solo `lib/core/security/` (no global), según
  la decisión de esta política. La cobertura de las demás
  áreas se imprime en el log para visibilidad pero no
  bloquea. Expandir el gate a `lib/core/sync/` o
  `lib/core/update/` queda como follow-up.

### Política de artefactos locales

- `.gitignore` raíz ignora: `/vaulta.apk`, `*.apk`, `*.aab`,
  `*.exe`, `*.dmg`, `*.pkg`, `*.msi`,
  `key.properties`, `*.jks`, `*.keystore`. Adicionalmente se
  ignoró `/.engram/` (tooling local de Engram, regenerado
  por el CLI en cada host) en el commit `d49e19c`.

### Criterios de aceptación

Todos los criterios originales de este ADR se cumplen al
2026-06-11. `flutter analyze` retorna `No issues found!`,
`flutter test` retorna 95/95 verde, y los criterios
específicos de gitignore / cobertura / widget tests se
verifican en cada push.
