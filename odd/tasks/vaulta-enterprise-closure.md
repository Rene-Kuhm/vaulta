# Vaulta — Enterprise closure

Cerrar los gaps de seguridad y de entrega que quedaron abiertos al terminar la
pasada enterprise del 2026-10-20. El objetivo declarado por el usuario: que
Vaulta "debe quedar enterprise". Base: `master` en `f2aa4a0` (25 commits
adelante de `origin/master`, nada pusheado).

## Specs

Las specs provienen de dos fuentes, citadas literalmente:

- **Del usuario, hoy (2026-10-21):** "ahye esta el smarphone conectado ahora
  usa agentes y haste cargo recuerda que vaulta debe quedar enterprice"
- **De la sesión anterior (obs 209), que él dejó como lista de pendientes
  para retomar:** "mañana seguimos".

- **S1 — Sync debe poder llevar un payload v4.** El gap G1 de
  `docs/architecture/ADR-001-crypto.md` dice: "add the item key salt to the
  wire (`ciphertext` column encoding or a new column) and to the Supabase
  schema, then lift the `>= 4` refusal". Hoy
  `_extractSyncPayload` devuelve `null` para todo payload v4+
  (`local_encrypted_vault_repository.dart:405-407`) y `saveItem` sólo encola
  si eso es no nulo, así que los cambios locales de items v4 no se propagan
  sin ningún error visible. Criterio de aceptación: un item v4 escrito en un
  dispositivo se abre en otro, con el salt viajar por el cable; la negativa
  fail-closed se levanta sólo después de que el receptor pueda derivar la
  misma clave.
- **S2 — Un item v3 preexistente debe poder migrarse a v4.** Gap G2b: los
  items v3 quedan sellados bajo el DEK hasta que el usuario los edite o
  cambie la contraseña maestra; "nothing schedules that work". Criterio de
  aceptación: existe una ruta de migración, invocable y con test, que
  re-sella un item v3 bajo su propia itemKey sin intervention manual.
- **S3 — El registro v2 y el hook de reescritura a v3.** G2 fue arreglado en
  `e12e71a`, pero el hook de migración sigue en `record.version < 2` en
  `vault_security_controller.dart:495`, `:967`, `:1091`: "a v2 record is never
  rewritten as v3, never acquires `pw_norm`, and never benefits from the HKDF
  split". Criterio de aceptación: un registro v2 que desbloquea queda
  reescrito como v3 por la misma ruta, con test que fije esa frontera.
- **S4 — API < 30 no debe aceptar PIN donde se pidió biometría.** Pendiente 3
  de obs 209: "sin `setUserAuthenticationParameters`, una clave con
  `setUserAuthenticationRequired(true)` también se autoriza por PIN.
  Quitar el decrypt del lado Dart cierra el alcance desde Dart, no el holes a
  nivel de proceso." Criterio de aceptación: la clave del envelope biométrico
  declara su tipo de autenticador, y hay un test que fija el parámetro y su
  ausencia en API < 30.
- **S5 — Un solo prompt biométrico, garantizado por tipos.** Pendiente 4 de
  obs 209: "la garantía de un solo BiometricPrompt vive en una rama de runtime
  en `password_manager_app.dart`, no en los tipos. `BiometricUnlockService` no
  puede saber si su authService es la variante pasiva."
- **S6 — El integration test de cancelación debe correr en hardware real.**
  Pendiente 1 de obs 209, único ítem bloqueado por el gate de MIUI/HyperOS
  (`INSTALL_FAILED_USER_RESTRICTED` en `install-commit`). El device POCO
  `2312DRA50G` (`f9d2fdd6`, API 36) está conectado de nuevo. El test es
  "cancelling the prompt leaves the envelope intact": necesita que el prompt
  se cancele, y la sesión anterior couldn't porque nadie lo hizo. Criterio de
  aceptación: los 7 tests de `integration_test/android_keystore_envelope_test.dart`
  pasan en el device, y el de cancelación pasa de verdad (el prompt se
  cancela, no se deja autenticar).
- **S7 — Docs que no contradigan el código.** Pendiente 5 de obs 209:
  `docs/architecture/ADR-006-encrypted-backup.md:45` afirma la regla de
  composición y `dk_len = 32` (ambos falsos);
  `docs/security/hardening-status.md` está congelado en `64b2260` con features
  ya shipeadas marcadas "Planned". Además G2 y G2b de ADR-001 describen como
  vigente un defecto ya corregido por `e12e71a`. Criterio de aceptación: cada
  afirmación de esas páginas se puede chequear contra el código en el commit
  que se cite.
- **S8 — El WIP de `feat/release-engineering` se verifica o se descarta.**
  Pendiente 6 de obs 209: commit `f202485`, 7 archivos, +684 líneas
  (`UpdateVerification.kt` nuevo, `UpdateChannel.kt` +229,
  `UpdateVerificationTest.kt` nuevo, `.github/workflows/flutter-ci.yml`).
  "Requiere `./gradlew test` y decisión del usuario. No mergeado, no
  verificado." Criterio de aceptación: `./gradlew test` en verde sobre el
  contenido de la rama, review de seguridad del canal de actualización, y una
  decisión explícita de integrar o descartar — no queda sin verificar.
- **S9 — El corpus de contraseñas filtradas es una decisión, no un accident.**
  Pendiente 7 de obs 209: hoy es NCSC top-100k (99 838 entradas),
  "no el corpus completo de Pwned Passwords (~800 MB). Documentado como gap
  explícito en ADR-001 G3." Criterio de aceptación: queda documentado como
  límite conocido con su número, su fecha y su fuente, o se amplía con una
  decisión explícita del usuario.

## Tasks

- **T1** (S6) — Verificar el gate de instalación por adb y correr los 7
  integration tests en el POCO, incluido el de cancelación. Route: inline
  (requiere hardware). Commit: ninguno hasta cerrar S1-S5.
- **T2** (S8) — Revisar `feat/release-engineering`: correctness, seguridad del
  canal de update, `./gradlew test`, y decidir. Route: subagente read-only +
  veredicto propio. Commit: `chore(release): ...` sólo si entra.
- **T3** (S1, S2) — Sync por cable + migración v3→v4 de items. Route:
  subagente escritor sobre `lib/core/sync/**`. Commit: `51517c2`.
- **T4** (S3) — Hook de reescritura de record v2→v3. Route: subagente escritor
  sobre `vault_security_controller.dart`, `biometric_unlock_service.dart` y
  `master_password_service.dart`. Commit: `5716334`.
- **T5** (S4, S5) — Tipo de autenticador del envelope en API < 30, y garantía
  de prompt único llevada a los tipos. Route: subagente escritor sobre el
  canal biométrico Kotlin + el lado Dart. Commit: `a4fc61b`.
- **T6** (S7, S9) — Poner ADR-001, ADR-006, CRYPTO.md, THREAT_MODEL.md y
  hardening-status.md al día contra el código, con SHA citado. Route:
  subagente escritor de docs, después de T3/T4/T5. Commit: `docs: ...`.
- **T7** (todas) — Verificación de cierre: `flutter test` completo, `flutter
  analyze`, ambos APKs, y re-correr el integration test de T1 sobre el código
  nuevo. Route: inline.

## Log

- **L1 (2026-10-21, verbatim):** "ahye esta el smarphone conectado ahora usa
  agentes y haste cargo recuerda que vaulta debe quedar enterprice"
- **L1b (2026-10-20, verbatim, el punto de reanudación):** "mañana seguimos".
  El contenido de los pendientes (obs 209) se-citó arriba en S1-S9 sin
  resumir los veredictos técnicos, que están enlazados a su fuente.
- **L2 (2026-10-21, estado verificado al abrir):** `master` en `f2aa4a0`, 25
  commits adelante de `origin/master`, árbol limpio salvo `odd/` sin trackear.
  357 tests verdes, analyze limpio. Device POCO `2312DRA50G` / API 36
  conectado, biométrico enrolado con `oemStrength 15`, `state 4`.
- **L3 (2026-10-21, decisión):** el trabajo sale de `master` a la rama
  `feat/enterprise-closure`; `master` no se toca. Nada se pushea, ningún PR,
  ningún merge a `master`: siguen siendo decisiones del usuario.
- **L5 (2026-10-21, T4 cerrado — la premisa de S3 era falsa).** El worker verificó contra el código que `e12e71a` ya reemplaza los tres sitios del controller por `_needsRecordMigration`, que discrimina con `MasterPasswordRecord.isCurrentFormat` y no con una constante de versión: un record v2 **ya** se reescribe como v3. Las lineas citadas por G2 (`:495`, `:967`, `:1091`) están stale. Un probe sobre un record v2 real en la base dio version=3, pwNorm=NFC, split=hkdf-sha256-v3, dkLen=64. Lo que S3 realmente打开 fue algo distinto: **tres holes fail-safe en esa misma reescritura**, que es una escritura de cuatro pasos (DEK nuevo → re-sella items → persiste record → re-envuelve envelope). Los tres RED fueron observados; los 3 fallos que arregla escapaban del API público. `biometric_unlock_service.dart:216` y `master_password_service.dart:187/:210/:226` quedaron **intactos a propósito**: no son hooks de migración, preguntan "se puede recuperar un DEK", y relajarlos a `< 3` rompería el desbloqueo biométrico de bóvedas v2 que hoy funcionan.

- **L6 (2026-10-21, decisión de diseño revisada por el orquestador):** la rama `deferred` de la reescritura **desbloquea en vez de fallar cerrado**. Revisado y aprobado: en todo instante intermedio el record en disco sigue siendo una clave que abre los items *anteriores*, así que el par legacy es consistente y abre la bóveda; una migración a medias sería ni una cosa ni la otra. Sólo el doble fallo (no se pudo escribir el record **y** no se pudo deshacer el rekey) bloquea, que es el único estado realmente irrecuperable. El staging del repository (`local_encrypted_vault_repository.dart:354-360`: `rekeyInProgressKey` + swap bajo try con `_didSwapCommit`) fue verificado por separado antes de aprobar: es lo que hace vrai la rama "el throw del rekey significa que los items vivos siguen siendo los viejos".

- **L7 (2026-10-21, gap pre-existente reportado por el worker de T4, NO arreglado):** un record con `dekWrap` corrupto o ausente lanza excepción fuera de `deriveVaultKey` antes de que se alcance `_needsRecordMigration`, así que ese throw escapa de `unlockWithPassword` **para todas las versiones**. Ampliar el catch cambiaría caminos no relacionados, por eso se reporta en vez de tocarlo. Pendiente de decisión: hoy el usuario ve una excepción cruda en vez de un mensaje de bóveda no abrible.

- **L8 (2026-10-21, T3 cerrado):** el salt del itemKey ya viaja por el cable:
  `vault_blobs.item_key_salt` + `item_key_version`, migración
  `20261021120000_add_vault_item_key_salt.sql`, RPC drop+recreated (los dos
  parámetros nuevos son trailing defaults), y la lectura gatea esas columnas
  por `key_version >= 4` en vez de confiar en su presencia — un cliente viejo
  nunca las nombra en su UPDATE, así que su presencia no prueba nada.
  `migrateItemsToItemKeyed()` cierra G2b. Cierra G1 y G2b. Commit `51517c2`.

- **L9 (2026-10-21, T4 cerrado):** los tres holes fail-safe de la reescritura
  v2→v3 están arreglados y verificados contra un record v2 real. El
  discriminador `isCurrentFormat` de `e12e71a` ya existía: lo que S3 pedía
  estaba hecho, y lo que faltaba era otra cosa. Commit `5716334`. Ver L5.

- **L10 (2026-10-21, T5 cerrado, con un límite que S4 no contemplaba):** la
  mitad Dart de S4 sí tiene tests (6 del gate + 3 del pairing, en
  `android_keystore_envelope_key_provider_test.dart:623-745`), incluido el
  caso RED-able "credential-only device does not open the biometric gate" que
  falla contra el código anterior. La mitad **Kotlin no tiene test y no puede
  tenerlo acá**: verificar que API < 30 rechaza la clave exige un device o
  emulador con API < 30, y este repo no tiene ninguno. Un test JUnit sobre
  `sdkInt >= 30` sería tautológico; un Robolectric agregaría una dependencia
  y un job de CI que colisiona con el de `feat/release-engineering` (S8, sin
  decidir). Se documenta como límite conocido en vez de fingir cobertura.
  Commit `a4fc61b`.

- **L11 (2026-10-21, estado verificado al retomar):** los tres work units de
  T3, T4 y T5 estavam **en el working tree sin commitear** (2242 líneas
  insertions) al retomar la sesión — verificado por `git status` contra
  `f2aa4a0`. Commiteados como tres unidades separadas antes de seguir.
  Estado: 411 tests verdes (54 nuevos sobre los 357 de la sesión anterior),
  analyze limpio, `assembleDebug` verde con el Kotlin recompilado.

- **L4 (2026-10-21, observación al abrir G2):** `e12e71a` ya corrigió el
  lockout de v2, pero ADR-001 G2 lo sigue describiendo como defecto vigente.
  El texto del gap y su línea de código no coinciden; hay que verificar contra
  el código antes de reescribirlo, no copiarse del documento.