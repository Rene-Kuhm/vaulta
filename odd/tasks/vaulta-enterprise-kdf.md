# Feature: Enterprise KDF, password policy, per-item keys and toolchain

Close the four gaps left by the security review, with migrations for every
persisted format change. Each unit is gated on `flutter test`,
`flutter analyze` and, for the Android unit, `flutter build apk --debug`.

## Specs

- **S1** — Argon2id must run **once** per unlock instead of twice. The
  record derives a 64-byte master key with a single salt and splits it
  with HKDF-SHA256 into the verifier (`info="vaulta:v3:verifier"`) and the
  KEK (`info="vaulta:v3:kek"`). KDF strength must not regress: memory stays
  64 MiB and iterations stay 3, so unlock cost halves at equal strength.
- **S2** — Persisted record gains `version: 3` and `pw_norm: "NFC"`.
  v1/v2 records keep their existing derivation and verify byte-for-byte as
  before; the controller's existing `record.version < 2` migration hook is
  extended to `record.version < 3` so an upgrade rewrites the record and
  re-keys entries on the next successful unlock.
- **S3** — Passwords are NFC-normalized before any KDF call. A legacy v2
  record must still verify with the raw bytes, because NFC changes the byte
  sequence for NFD input and would otherwise lock the owner out. Migration
  to NFC happens only on the v2 to v3 rewrite.
- **S4** — The composition rule (upper + lower + digit + symbol) is
  removed. NIST SP 800-63B §3.1.1.2 recommends against composition rules
  and the existing doc comment already cites that document. Replaced by:
  minimum length 12, a maximum of 1024 to bound Argon2id input cost, and a
  check against a locally shipped list of common breached passwords. The
  check runs offline; Vaulta never sends a password prefix to a network
  service.
- **S5** — Each item gets its own `itemKey`, derived with
  `HKDF-SHA256(DEK, salt=<16 random bytes>, info="vaulta:item:v4|<rid>|<kid>|<iv>")`.
  The item ciphertext is sealed with AES-256-GCM under `itemKey`, never
  under the DEK directly. Item payload gains `version: 4` carrying `iv`
  (item key version) and `salt`.
- **S6** — v4 AAD is `vaulta:item:v4|<recordId>|<keyId>|<itemKeyVersion>`,
  extending the existing v3 `vaulta:item:v3|<recordId>|<keyId>` binding.
  Decryption rejects a payload whose `rid` or `iv` disagrees with the
  session, with a typed rejection, never a silent fallback.
- **S7** — v3 item payloads decrypt correctly under the new service;
  migration to v4 re-encrypts every entry through the existing
  `rekeyEntries` staging-and-swap path so an interrupted upgrade leaves the
  v3 vault intact.
- **S8** — Android Gradle Plugin moves from 8.11.1 to at least 9.0.1 and
  Kotlin from 2.2.20 to at least 2.3.20, because Flutter drops support for
  the current versions. Verified by a real `flutter build apk --debug`.
- **S9** — Every behavior change is pinned by a test that fails before the
  change and passes after. No test asserts only that "no exception thrown".
- **S10** — `docs/adr/0001-crypto-key-derivation-and-encrypted-blob.md` and `CRYPTO.md` are
  updated in the same commit as the code they describe. Documentation that
  describes a format the code does not implement is the failure mode this
  project already hit once (the nonexistent `AutofillService.kt`).
- **S11** — Work lands in Conventional Commits on `master`, one commit per
  unit. No push, no PR: that stays a human decision.

## Tasks

| # | Task | Specs | Route | Commit |
|---|------|-------|-------|--------|
| T1 | Feature document + baseline re-confirmed | S9 | inline | — |
| T2 | Single Argon2id run with HKDF split, record v3 | S1,S2 | inline | `feat(security)` |
| T3 | NFC normalization with safe legacy verify | S3 | inline | `feat(security)` |
| T4 | NIST-aligned policy + local breached list | S4 | inline | `feat(security)` |
| T5 | Per-item `itemKey`, payload v4 + AAD | S5,S6 | delegated | `feat(security)` |
| T6 | Item v3 to v4 migration via rekey staging | S7 | delegated | `feat(security)` |
| T7 | AGP 9 + Kotlin 2.3 toolchain, APK verified | S8 | delegated, own worktree | `build(android)` |
| T8 | ADR-001 + CRYPTO.md + THREAT_MODEL refresh | S10 | inline | `docs(security)` |
| T9 | Full verification: tests, analyze, APK | S9 | inline | — |

## Log

### L1 — 2026-10-20

User verbatim: *"soluciona esto de manera enterprice  Lo que falta de la review original
 HKDF partiendo verifier/KEK (hoy corrés Argon2id dos veces por desbloqueo: 128 MiB),
 normalización NFC +  política alineada a NIST + chequeo de contraseñas comprometidas, y
 itemKey por item. También: AGP 8.11.1 y Kotlin 2.2.20 están a punto de perder soporte de
 Flutter.  No hago push ni PR — eso es tuyo."*

### L2 — Estado de partida

`master` en `a3ce91a`, 18 commits adelante de `origin/master`, 280 tests
verdes, `flutter analyze` sin issues, `flutter build apk --debug` OK.

Ancla de migración ya existente: `vault_security_controller.dart`
`unlockWithPassword` migraciona cuando `record.version < 2`, derivando un
record nuevo con `createRecord` y re-cifrando entries con `_rekeyEntries`.
T2/T3/T4 reutilizan ese mismo hook extendido a `version < 3`.

Deuda known que NO entra en esta feature (ya reportada):
`android_keystore_envelope_key_provider_test.dart` tiene cobertura CI cero
porque todos sus tests hacen `if (!Platform.isAndroid) return`.

### L3 — T2+T3+T4 (un commit, no tres)

Se kardaron juntas a proposito. El record v3 lleva el split HKDF **y** el
marcador `pw_norm`; separarlos deja un estado transitorio
(`version: 3` sin normalizacion) que no existe en ningun despliegue y que
habria que migrar igual. Un commit honesto que cubre S1-S4.

Commiteado. 295 tests.

Medicion real (`tool/kdf_benchmark.dart`, committed como herramienta):

| | tiempo |
|---|---|
| 1 corrida Argon2id 64 MiB x3, salida 32 B | 389 ms |
| 1 corrida Argon2id 64 MiB x3, salida 64 B | 392 ms |
| 2 corridas (esquema v2) | 771 ms |

La longitud de salida es gratis; por eso partir con HKDF compra un
desbloqueo mas barato sin debilitar el KDF.

**Primer benchmark mal medido**: mezclaba los dos esquemas en el mismo
loop y la primera muestra absorbia el warm-up, dando 386 ms para v2 (imposible,
una sola corrida sola da 395 ms). La version aislada dio el numero correcto.

Dos bugs reales que encontraron los tests nuevos:

- El fold de leet se aplicaba a la entrada pero **no a la lista**, asi que
  `p@ssw0rd1234` no coincidia con `password1234`. Ahora la lista se pliega
  con la misma funcion y se compara plegado contra plegado.
- `letmein12345` no lo agarraba nada: quitar digitos finales es la forma
  mas comun de "reforzar" una palabra que uno ya sabe mala. Agregado.

### L4 — T5+T6: itemKey por item

Commiteado `4533a94`. 310 tests.

`itemKey = HKDF-SHA256(DEK, salt=<16 bytes>, info=vaulta:item:v4|rid|kid|iv)`,
AAD pasa de `vaulta:item:v3|rid|kid` a `vaulta:item:v4|rid|kid|iv`.

**T6 se resolvio como limite fail-closed, no como migracion completa.** El
salt del itemKey no viaja por el cable de sync: mandarlo exigiria tocar las
9 capas del sync mas el esquema de Supabase. Como el cable no lo lleva, el
repository **declina encolar** una mutacion v4 en vez de encolar una que el
receptor no puede abrir. Sync esta apagado por defecto, asi que hoy no se
pierde nada.

El test lo cazó solo: `applyRemoteSnapshots` rechazaba el payload porque al
reconstruir el sobre desde los fragmentos (ciphertext/nonce/tag) perdia el
salt. Esa es la falla de diseno que la decision fail-closed evita.

Seguimiento requerido: llevar el salt por el cable y por el esquema de
Supabase (ADR-002). Es un cambio de protocolo, no de crypto.

### L5 — T7: toolchain

Delegado a `gentle-ai-worker` (task mvg49onm-1-2xga). Commiteado
`618e5f1` tras verificacion propia del APK.

AGP 8.11.1 → **9.2.1**, Kotlin 2.2.20 → **2.4.21**, Gradle 8.14 → **9.4.1**:
la terna mas nueva que sigue dentro de la matriz conocida de Flutter 3.47.7.

Tres roturas de AGP 9, todas leidas de fallos reales de build:

- `android.kotlinOptions` es error de deprecacion en AGP 9.
- AGP 9 exige la version **minor** del AAR metadata, asi que
  `androidx.biometric 1.4.0-alpha07` fuerza `compileSdkMinor = 1`.
- AGP 9 built-in Kotlin rechaza el plugin externo, pero
  `package_info_plus` y `shared_preferences_android` todavia lo aplican
  mientras `file_picker` lo saltea. El puente en `subprojects` de
  `android/build.gradle.kts` reaplica Kotlin a modulos de libreria con
  fuentes Kotlin que no lo tengan.

**El puente es un workaround temporal documentado, no una solucion.** Se va
cuando `package_info_plus` llegue a 9.x y se pueda poner
`android.builtInKotlin=true`.

Efectos colaterales que el worker reporto y hay que tener presentes:

- AGP instalo `platforms;android-36.1` en `$HOME/Android/Sdk` por
  `compileSdkMinor=1`. CI necesita esa plataforma disponible.
- Quedan 2 warnings de Flutter por el plugin externo de Kotlin. Son
  dependencia, no configuracion.
- `flutter build apk --release` no se ejercito: no estaba en el comando de
  verificacion autorizado. El bloque de signing no se toco.
- Se agrego `android/build/` a `android/.gitignore`: Gradle 9 lo escribe en
  cada build y la regla `/build/` de la raiz no lo cubria.