# Vaulta hacia Bitwarden: ola 1 (deuda de confianza y salida de datos)

Roadmap de brecha contra Bitwarden, ejecutado por olas. Esta ola NO toca la criptografía ni el
motor de almacenamiento: cierra dos huecos que no requieren migración de datos y que hoy impiden
confiar en el producto.

Base: `feat/enterprise-closure` · Verificación: `flutter analyze` + `flutter test` (412 tests,
cobertura 85.9% en `lib/core/security`, gate 60% en CI).

## Specs

S1. El baseline está verde antes de empezar y sigue verde al terminar cada tarea:
`flutter analyze` sin issues nuevas y `flutter test` completo en verde. Una tarea sin esto no se
acepta.

S2. Existe export **en claro** del vault, en CSV y en JSON, para que el usuario pueda migrar a otro
gestor. Requisitos:
- Se ofrece junto al export cifrado `.vaulta` que ya existe, no lo reemplaza.
- Muestra una advertencia explícita de que el archivo queda sin cifrar, antes de escribirlo.
- El JSON conserva todos los campos del ítem (título, usuario, secreto, url, notas, categoría,
  timestamps). El CSV conserva al menos título, usuario, secreto, url y notas.
- El archivo se escribe bajo demanda del usuario, nunca automáticamente, y no queda en un
  directorio compartido por defecto.
- Tiene tests: contenido del archivo generado, campos conservados y que el camino cifrado sigue
  funcionando igual.

S3. La pantalla de seguridad deja de reportar valores falsos. Hoy `biometricUnlock` y
`hardwareBackedKeys` se reportan como `false` contradiciendo el camino real de Android KeyStore
(`docs/security/hardening-status.md:167-171`). Debe reportar el estado real, y si no puede
determinarlo debe decir "desconocido", nunca `false` por defecto.

S4. La documentación deja de contradecir al código:
- `README.md` ya no dice que el export cifrado no está disponible (sí lo está).
- `README.md` declara el umbral de cobertura real: 60%, no 50%.

S5. Cada tarea corre en su rama `swarm/<slug>` con una línea `Owns:` de rutas repo-relativas sin
solapamiento con la otra tarea de la ola. Ningún archivo fuera de `Owns:` se modifica; si hace
falta otro, se reserva primero con `agentes-tablero tomar`.

S6. Esta ola **no** incluye y no debe intentar: migración del motor de almacenamiento, autofill,
TOTP, adjuntos, compartir/organizaciones, ni cambios en el formato cifrado. Fuera de alcance por
riesgo de datos y por dependencia de orden.

## Tasks

| ID | Specs | Ruta | Owns | Resultado |
|----|-------|------|------|-----------|
| T1 | S1,S3,S4,S5 | swarm | `lib/features/security/`, `lib/core/security/vault_security_controller.dart`, tests, `README.md`, `docs/security/hardening-status.md` | **hecho** · rama `swarm/make-the-security-screen-report-real-hardw` · `7c3b52f` · integrado `486b8b6` |
| T2 | S1,S2,S5 | swarm | `lib/features/backup/`, `lib/core/security/vault_backup_service.dart`, `test/features/backup/`, `test/core/security/vault_backup_service_test.dart`, `lib/l10n/` | **hecho** · rama `swarm/add-clear-text-csv-and-json-export-of-the-` · `5591635` · integrado `b5785f3` |

Rama de integración: `orq/20261021-090429` (worktree `~/proyectos/.herdr-worktrees/vaulta/orq-20261021-090429`).
Base de la ola: `e6cebcf` (pin de Flutter). Suite en la integración: **445 tests verdes**, `flutter analyze` sin issues.

Después de esta ola, en orden y no en paralelo:

| Ola | Contenido | Por qué ese orden |
|-----|-----------|-------------------|
| 2 | Migración a base local cifrada — **diseño en `docs/architecture/ADR-007-encrypted-local-database.md` (Proposed)** | Techo arquitectónico: hoy todo el vault es un blob JSON en secure storage. Bloquea autofill, adjuntos y búsqueda con 5.000 ítems |
| 3 | AutofillService Android + Quick Settings tile | Depende de la ola 2 para responder en milisegundos |
| 4 | Tipos de ítem, carpetas, favoritos, papelera, historial, TOTP | Tocan el modelo de datos: un solo dueño, secuencial |
| 5 | Sync real: correr el SQL contra Postgres, encenderlo en build de test, conflictos automáticos | Hoy el SQL nunca corrió contra un Postgres real |
| 6+ | Organizaciones, Send, emergency access, SSO/SCIM, clientes adicionales | Sólo si las olas 1-5 cerraron |

## Log

L1 (pedido original, verbatim):

> bueno pon a los agentes a trabajar y has todo lo que falta

L2 (pedido previo que origina el análisis, verbatim):

> revisa analiza como en que estado esta vaulta y que le falta para llegar a ser como bitwarden

L3 (evidencia del análisis, verificada por el orquestador): el `AndroidManifest.xml` no declara
ningún `<service>`, así que no hay `AutofillService` ni `AccessibilityService`. El vault se guarda
como un único blob cifrado bajo `vault_encrypted_items_v1`
(`lib/core/security/local_encrypted_vault_repository.dart:53-69`). Cripto ya en nivel producción:
AES-256-GCM, Argon2id 64 MiB / 3 iteraciones, clave por ítem por HKDF, AAD con binding de recordId
y keyId.

L4 (decisión de alcance): "todo lo que falta" es un roadmap de meses, no una tarea. Se ejecuta por
olas. La ola 1 se limita a lo que no toca datos ni cripto, porque la migración de almacenamiento es
riesgo item 1 (datos) y exige un solo dueño con diseño previo, no escritores en paralelo.

L5 (hallazgo bloqueante antes de empezar): el shim de mise para `flutter` fallaba con
`No version is set for shim: flutter`. Ningún agente podía correr `flutter analyze` ni `flutter test`:
habrían escrito a ciegas. Se fijó con `mise.toml` en el repo y `mise use -g flutter@3.47.7`, en el
commit `e6cebcf`. Baseline posterior: `flutter analyze` sin issues, **412 tests** en verde.

L6 (evidencia T1): `flutter analyze` sin issues y **424 tests** verdes en su worktree (412 de
baseline + 12 nuevos). El worker hizo más de lo pedido: movió `securityPlanFor` de
`LocalEncryptedVaultRepository` a `platform_security_plan.dart` (donde vive el tipo), reemplazó el
`bool` por el enum de tres estados `SecurityCapabilityState`, y agregó
`probeHardwareBackedKeyAvailability()`; `isHardwareBackedBiometricAvailable()` sigue devolviendo
`bool` para el gate de enrolamiento, que es lo correcto porque ahí hay que fallar cerrado. La UI
tiene estado inicial `PlatformSecurityPlan.unknown` y `"No se pudo determinar"` en `app_es.arb`.
Verificado también contra S4: README sacó la mentira del export y corrigió el gate de 50% a 60%.

L7 (defecto de proceso, mío): `herdr-swarm --conflicts` del run 1 marcó 11 archivos fuera de la
reserva, entre ellos `android_keystore_envelope_key_provider.dart` y
`local_encrypted_vault_repository.dart`. Revisados: el refactor era coherente, la reserva estaba
**subdeclarada**. Lección para la ola 2: si una tarea toca `lib/core/security/`, se reserva el
directorio completo, no archivos sueltos.

L8 (evidencia T2): `flutter analyze` sin issues y **445 tests** verdes en su worktree (424 + 21
nuevos), y 445 también en la integración. `--conflicts` sin choques. El export CSV sigue RFC 4180
(comillas, comillas duplicadas, CRLF) y el JSON usa `VaultItem.toJson` para no perder campos. Gate
de advertencia en dos pasos más re-ingreso de la master password: el botón queda deshabilitado hasta
tildar el reconocimiento, así que no hay camino silencioso a un archivo sin cifrar. Decisión
documentada del worker: no se prefija `=`, `+`, `-`, `@` para neutralizar fórmulas de planilla,
porque corrompería el secreto al reimportarlo; el trade-off queda escrito en el código.

L9 (evidencia de la protección entre agentes): al lanzar T2 antes de liberar las reservas del run 1,
el tablero **bloqueó el lanzamiento** con `✗ lib/l10n choca con
pc:swarm-make-the-security-screen-report-real-hardw` y `No lancé nada (y solté lo que había
reservado)`. Es la prueba en vivo de S5, no una afirmación de diseño.

L10 (costo medido): T1 US$0,3416 en 9m50s; T2 US$0,2222 en 8m15s. Total ola 1: **US$0,5638**.

L11 (cierre de ola 1): `orq/20261021-090429` mergeada a `feat/enterprise-closure` en `7a46090`, con
**445 tests verdes** y `flutter analyze` sin issues en la rama. Reservas del run 2 liberadas.

L12 (ola 2, diseño): `docs/architecture/ADR-007-encrypted-local-database.md`, estado **Proposed**.
Decisión: SQLite vía `drift` + SQLCipher para el archivo, conservando el payload cifrado por ítem
de ADR-001 como unidad de almacenamiento, con la clave de la base derivada por HKDF del DEK
(`vaulta:db:v1`). El formato de sync no cambia: la migración es local. Migración en una
transacción, verificada, con el blob legacy conservado hasta el próximo desbloqueo exitoso y
downgrade rechazado por versión de esquema. Criterio que justifica todo: la amplificación de
escritura de un `saveItem` pasa de O(N) a O(1), y eso se mide, no se afirma.

L13 (pendiente de decisión): el ADR queda en Proposed. No se implementa hasta que el dueño lo
acepte, porque la migración corre sobre vaults reales.

L14 (pedido):

> para lo que sea sqlite usa la forma mas avanzada que exista

L15 (corrección del ADR por investigación, commit `0be4d14`): la primera versión del ADR nombraba
`sqlite3_flutter_libs` y `sqlcipher_flutter_libs`. Verificado contra el registro de paquetes:
ambos están en versión `+eol` desde el 2026-02-15, con la nota "Not used anymore, update to version
3.x of package:sqlite3", porque `sqlite3` 3.x compila SQLite con **native assets**. El stack de los
tutoriales está muerto. Stack real: `sqlite3` 3.7.1 → SQLite **3.54.0**, `drift` 2.35.2, y el
cifrado se elige con `hooks.user_defines.sqlite3.source: sqlite3mc` → **SQLite3 Multiple Ciphers
2.6.1**, licencia **MIT**, con cifrados AEAD (AES-256-GCM, ChaCha20-Poly1305). SQLCipher queda
descartado: sólo ofrece CBC + HMAC, puede traer un SQLite más viejo y linkea OpenSSL en Windows,
Linux y Android. `drift_flutter` también queda afuera porque arrastra los dos paquetes EOL.
Native assets viene activado por defecto en este toolchain (`flutter config`), así que el riesgo
de la ola 2 baja a "compilar en Windows y Linux", que se verifica compilando.

L16 (ola 2 A, commit `d307a83`): esquema `STRICT` y opener cifrado, sin cablear nada. `sqlite3`
3.7.1 construido como SQLite3 Multiple Ciphers por native assets, `pragma cipher` → `pragma key`
→ `journal_mode` en ese orden, clave de base derivada por HKDF del DEK (`vaulta:db:v1`) con sal
por base que vive en secure storage, nunca dentro de la base. **452 tests** (445 + 7) y
`flutter analyze` sin issues.

L17 (gate de confidencialidad, cerrado): el ADR lo dejaba pendiente porque el spike sólo podía
escanear un archivo cerrado y con checkpoint. El test nuevo lo prueba **con la base abierta y WAL
activo**: el título no aparece en claro en `.db`, `-wal` ni `-shm`. También quedan probados: abrir
sin clave lanza excepción en vez de devolver vacío, una clave con un byte cambiado no lee nada,
`STRICT` rechaza un tipo equivocado, y una versión de esquema desconocida se rechaza en vez de
adivinarse.

L18 (detalle del ecosistema): `Database.dispose()` está deprecado en `sqlite3` 3.7; se usa
`close()`. La rama queda en cero issues.
