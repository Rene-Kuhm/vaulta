# Feature: Land Claude Code's security branches and close the remaining gaps

Integrate the three completed-but-unmerged agent branches in
`/home/tecnodespegue/proyectos/vaulta`, then close the security gaps from
the repo review that none of them covered. Every merge is gated on a
green `flutter test` run.

## Specs

- **S1** — User verbatim: *"revisa claude code esta trabajando en vaulta
  continua su trabajo"*. Claude Code's agents left three branches with
  finished commits and idle worktrees. Continuing their work means
  landing those commits on `master`, verified, not redoing them.
- **S2** — User verbatim: *"yo quiero que vaulta quede terminado hoy y que
  sea una app potente"*. "Terminado" is scoped to integrating and
  finishing what is already built; inventing a new feature roadmap is
  out of scope until the landed work is verified.
- **S3** — `feat/crypto-aad-binding` (3 commits, 25 files) binds item
  ciphertexts to record id and key id (payload v3) and reports platform
  security and autofill status truthfully. Lands first: it is the
  highest-severity item of the review (GCM replay between records).
- **S4** — `feat/encrypted-export` (4 commits, 27 files) adds the
  encrypted `.vaulta` backup format with coordinator, export and restore
  in Settings, ADR-006, and closes every route above the SecurityGate on
  lock.
- **S5** — `feat/release-engineering` (5 commits, 21 files) verifies
  in-app updates by SHA-256 and signing certificate, pins CI actions to
  SHAs, adds Dependabot, SECURITY.md and a raised coverage gate.
- **S6** — The dead `rsaDecryptAuthorized` path must leave
  `KeystoreChannel.kt` and `BiometricChannel.kt`. It inits a private-key
  cipher with no `CryptoObject` authorization, which cannot succeed under
  `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`. It is
  unreachable, and it compiles.
- **S7** — Each merge runs `flutter test` on `master` first and after.
  A merge that turns tests red is reverted, not fixed forward.
- **S8** — Work lands in Conventional Commits on `master` by merge
  commit. No push, no PR: those stay the user's decision.

## Tasks

| # | Task | Specs | Route | Commit |
|---|------|-------|-------|--------|
| T1 | Establish green `flutter test` baseline on `master` | S7 | inline | — |
| T2 | Merge `feat/crypto-aad-binding`, verify tests | S3,S7 | inline | merge commit |
| T3 | Merge `feat/encrypted-export`, verify tests | S4,S7 | inline | merge commit |
| T4 | Merge `feat/release-engineering`, verify tests | S5,S7 | inline | merge commit |
| T5 | Delete dead `rsaDecryptAuthorized` path + cover with test | S6 | inline | `fix(security)` |
| T6 | Remove the three stale agent worktrees | S1 | inline | — |
| T7 | Re-run full suite and `flutter analyze`, report residual gaps | S7 | inline | — |

Deferred, reported but not started without a new decision: HKDF split of
verifier/KEK (one Argon2id run instead of two), Unicode NFC + NIST-aligned
password policy, per-item `itemKey` derivation, local attempt-rate limiting
(landed on master as PR #3).

## Log

### L7 — T4 y T5: cierre

`feat/release-engineering` mergeado (limpio, sin conflictos). Dos
incidentes mios que quedaron registrados:

- **Falsa alarma de cuelgue.** Interpreté lentitud como deadlock y maté
  tres corridas que iban bien. Causa real: un `flutter_tester` zombie de
  54 minutos del worktree de Claude Code (`agent-ab9671da039b62202`)
  consumiendo CPU. La suite completa tarda ~10s en verde; con el zombie,
  minutos. `pkill -f flutter_tester` se auto-mata a uno mismo porque el
  patrón matchea la propia linea de comando: usar `pkill -f "flutter[_]tester"`.
- **Regresión propia.** Para silenciar `unawaited_futures` puse `await`
  sobre `showModalBottomSheet`, que queda abierto a proposito hasta que el
  lock lo cierra. `await` lo deja esperando para siempre. Fix correcto:
  `unawaited(...)`.

T5: `rsaDecryptAuthorized` eliminado junto con las tres clases de
excepcion que solo el lanzaba, KDoc de `BiometricChannel` corregido (describia
un round trip que nunca existio), y test de regresion que fija la superficie
alcanzable del canal. Verificado con `flutter build apk --debug`: **APK
compilado**.

### L8 — Trabajo WIP recuperado (NO mergeado)

El worktree `agent-ab9671da039b62202` tenia **7 archivos sin commitear** de
Claude Code: `UpdateVerification.kt` (nuevo), `UpdateVerificationTest.kt`
(nuevo), `UpdateChannel.kt` reescrito (+229), `update_service.dart`,
`build.gradle.kts` y `flutter-ci.yml`. Nada de eso estaba en `master` y
estaba a un `git worktree prune` de perderse.

Preservado como `f202485` en `feat/release-engineering` mas copia en
`odd/update-verification-wip.patch`. **No mergeado y no verificado por esta
sesion**: requiere correr los unit tests de Android
(`./gradlew test`) y una decision del usuario.

### L9 — Estado final

`master` 18 commits adelante de `origin/master`. **280 tests verdes**,
`flutter analyze` sin issues, `flutter build apk --debug` OK.

Corte de slice: 2493 lineas autorales en 7 commits sobre
`feat/release-engineering` desde `origin/master`, por encima del corte de
~400. El trabajo quedo separado en commits por unidad revisable; el WIP
recuperado queda aislado en su propio commit sin verificar.

Trabajo diferido, reportado sin arrancar: HKDF partiendo verifier/KEK (una
corrida de Argon2id en vez de dos), NFC + politica alineada a NIST + chequeo
de passwords comprometidos, `itemKey` por item, y **cobertura real del
envelope biometrico** (ver L10).

### L10 — Hallazgo de cobertura

`test/core/security/android_keystore_envelope_key_provider_test.dart` tiene
8 tests y **todos hacen `if (!Platform.isAndroid) return`**. CI corre
`flutter test` en `ubuntu-latest`, donde `Platform.isAndroid` es `false`: el
archivo entero no ejecuta ni una aserción. El camino del envelope
biometrico — la parte mas sensible de la app — tiene **cobertura automatica
cero en CI**. El test de regresion agregado en T5 sigue el mismo patron
por consistencia, y por lo tanto tambien es vacuo fuera de Android.
Resolverlo requiere `integration_test` sobre un emulador, no `flutter test`
en host.

### L1 — 2026-10-17

> yo quiero que vaulta quede terminado hoy y que sea una app potente

### L2 — 2026-10-17

> revisa claude code esta trabajando en vaulta continua su trabajo

### L3 — Estado encontrado al arrancar

`master` en `c506c48`. Claude Code ya mergeó tres PRs que cubren parte de
la review: `#2` docs/README honestos, `#3` lockout exponencial de intentos
de master password, `#4` bloqueo de captura de pantalla + clipboard
endurecido. Las tres ramas restantes quedaron commiteadas en worktrees
inactivos bajo `.claude/worktrees/`, sin mergear.

### L4 — T2: `feat/crypto-aad-binding` mergeado

191 tests verdes (+33 sobre la línea base de 158), `flutter analyze` sin
issues. El AAD quedó mejor que la propuesta original: domain separation
`vaulta:item:v3|<recordId>|<keyId>`, `VaultPayloadRejectedError` tipado en
lugar de `StateError`, el `recordId` viaja en el payload como `rid` para
poder verificarlo al descifrar, y 18 tests dedicados en
`test/core/security/item_payload_v3_test.dart`.

### L5 — T3: `feat/encrypted-export` mergeado, con un incidente

259 tests verdes. La resolución de l10n necesitó dos intentos:

1. **Primer intento, incorrecto.** Ante los 4 conflictos-marked tomé el
   `.arb` del branch entrante completo y reinserté solo las 3 claves
   ausentes. Resultado: 3 tests sin compilar y 8 valores de `access*`
   revueltos a la copy de marketing vieja del branch de backup.
2. **Diagnóstico.** Los `.dart` de l10n son generados; la fuente de verdad
   son los `.arb`. La regla correcta es **unión con prioridad de HEAD en
   todo conflicto**, no "entrante + claves faltantes".
3. **Segundo intento, correcto.** `merged = {**entrante_solo_nuevas,
   **HEAD}``: +55 claves nuevas (backup, setup, platform) en `en` y +49 en
   `es`, 8 valores de HEAD restaurados. Regenerado con `flutter gen-l10n`.

Los `.dart` de l10n no se resuelven a mano: se resuelven los `.arb` y se
regeneran.

### L6 — Nota de toolchain

`mise activate` no alcanza: el shim de `flutter` exige `mise use -g`.
Invocar el binario directo:
`/home/tecnodespegue/.local/share/mise/installs/flutter/3.47.7/bin/flutter`.

Método: los 8 items de la review →
`FLAG_SECURE` (#4, hecho), `securityPlan` honesto (rama, hecho), AAD
(S3, hecho), rate limit (#3, hecho), código muerto (S6, pendiente),
HKDF verifier/KEK (pendiente), NFC+NIST (pendiente), itemKey (pendiente).