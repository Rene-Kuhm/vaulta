# ADR-001: Derivacion de claves y formato de blob cifrado v2

> El cuerpo de este ADR esta escrito en el idioma del paquete original y
> queda congelado como esta. Las amendments (2026-10-19 y 2026-10-20) estan
> en ingles y son las que describen lo que el codigo construye hoy. Donde
> el cuerpo y una amendment discrepan, **manda la amendment**: el cuerpo
> describe el formato v2 historico, no el actual.

- Estado: Aprobado
- Fecha: 2026-03-23
- Ultima actualizacion: 2026-10-21 (cierre de gaps G1, G2 y G2b; G3 sigue
  abierto). Amendment "master password record v3 and item payload v4":
  2026-10-20.

## Contexto

La app necesita un esquema de cifrado estable para secretos locales y sincronizados, con parametros versionables para migraciones futuras y validacion criptografica fuerte.

## Decision

Se congela el esquema criptografico v2 con estas reglas:

1. Derivacion de clave maestra (KEK): Argon2id sobre la master password, con salt aleatoria de 16 bytes por usuario.
2. Parametros iniciales Argon2id v2: `memory=64 MiB`, `iterations=3`, `parallelism=1`, `output=32 bytes`.
3. Clave de datos (DEK): aleatoria de 32 bytes por vault de usuario.
4. Envoltorio de DEK: la DEK se cifra con la KEK usando AES-256-GCM.
5. Cifrado de entradas: cada item se cifra con la DEK usando AES-256-GCM y nonce unica de 12 bytes por registro/version.
6. Formato blob cifrado v2: contenedor JSON con version explicita y metadatos de KDF/nonce/tag para permitir migraciones.

Ejemplo de forma del blob v2 (referencial):

```json
{
  "v": 2,
  "kdf": {
    "name": "argon2id",
    "salt_b64": "...",
    "memory_kib": 65536,
    "iterations": 3,
    "parallelism": 1,
    "dk_len": 32
  },
  "dek_wrap": {
    "alg": "AES-256-GCM",
    "nonce_b64": "...",
    "ciphertext_b64": "...",
    "tag_b64": "..."
  },
  "payload": {
    "alg": "AES-256-GCM",
    "nonce_b64": "...",
    "ciphertext_b64": "...",
    "tag_b64": "..."
  }
}
```

## Alternativas consideradas

- PBKDF2-HMAC-SHA256: mayor compatibilidad, menor resistencia GPU frente a Argon2id.
- Scrypt: valida, pero Argon2id tiene adopcion mas clara en recomendaciones modernas para password hashing.
- ChaCha20-Poly1305 para todo: mejor en dispositivos sin AES acceleration, pero se prioriza estandarizacion AES-GCM para este batch.

## Consecuencias / tradeoffs

- Seguridad: mejora frente a KDFs legacy, con costo computacional superior en login/desbloqueo.
- UX: posible latencia perceptible al derivar KEK en dispositivos gama baja.
- Operacion: formato v2 versionado facilita migraciones sin romper blobs existentes.
- Complejidad: requiere manejo estricto de nonces unicas y metadatos criptograficos.

## Criterios de aceptacion verificables

- Todo blob nuevo persiste `v=2` y bloque `kdf` completo.
- No se reutiliza nonce para una misma clave (test de colision en lote de muestras).
- La derivacion con password incorrecta nunca produce descifrado valido.
- Se puede parsear y validar estructura minima del blob v2 sin acceder a secretos en claro.

## Implementacion por lotes

- Batch C1: agregar modelos y serializacion de blob v2 sin activar migracion.
- Batch C2: integrar KDF Argon2id + cifrado AES-GCM en flujo de alta/edicion.
- Batch C3: migrador controlado v1->v2 con telemetria de errores y rollback logico.

## Amendment 2026-10-19: item payload v3 (record-bound AAD)

> **Read with the 2026-10-20 amendment below.** This section records the
> decision as taken on 2026-10-19. Its `file:line` pointers were written
> against the tree at that date and have drifted since; re-verify any line
> number here before relying on it. Anything about *what gets written* is
> superseded: writes are v4, not v3. Everything about v3's AAD, its
> downgrade defense and its sync wire form still holds.

- Status: Accepted
- Supersedes: the item-payload part of the v2 format above. KDF, DEK
  and DEK-wrap rules are unchanged.

### Problem

Up to v2, every item payload was AES-256-GCM with **no associated
data**. GCM only authenticated the ciphertext itself, so a valid
ciphertext for record A could be copied into record B, or replayed
under another record id, and it would still decrypt. `THREAT_MODEL.md`
lists this for a malicious sync backend and for another device that
holds the DEK.

### Decision

1. **AAD.** Every item is encrypted with the associated data
   `utf8("vaulta:item:v3|" + recordId + "|" + keyId)`
   (`lib/core/security/aes_gcm_vault_crypto_service.dart:37`). Both
   fields must be non-empty and must not contain `|`, which is what
   makes the encoding unambiguous. `keyId` is the vault key generation
   (`master_password_service.dart:134`, base64url, so it never contains
   `|`). `recordId` is the `VaultItem.id`.
2. **Envelope.** `{"v":3,"keyId":…,"rid":recordId,["kdf","dek_wrap"],
   "payload":{alg,nonce_b64,ciphertext_b64,tag_b64}}`
   (`aes_gcm_vault_crypto_service.dart:134`). The clear-text `rid` is
   only a hint: decrypt refuses a `rid` that differs from the record id
   the caller asks for (`:107`), and GCM authenticates the real value
   (`:119`).
3. **API.** `VaultCryptoService.encrypt` takes `recordId`; `decrypt`
   takes `recordId` (required for v3, `null` allowed only for v1/v2)
   and `minimumVersion`; `inspect` reads the header without key
   material (`lib/core/security/vault_crypto_service.dart:46`).
   Rejections throw `VaultPayloadRejectedError` (a `StateError`) with a
   `VaultPayloadRejection` reason and a message that never contains
   plaintext (`vault_crypto_service.dart:71`, `:93`).
4. **Identity check.** After decrypting, the item's `id` must equal the
   bound record id, otherwise the payload is rejected
   (`lib/core/security/local_encrypted_vault_repository.dart:573`).
   This catches a device that holds the DEK and encrypts item `X`
   bound to record `Y`, where the AAD verifies.
5. **Legacy reads.** v1/v2 payloads still decrypt with no AAD until the
   vault is migrated. All writes, including rekey output, were v3 at the
   time of this amendment and are **v4** as of the 2026-10-20 amendment
   below (`local_encrypted_vault_repository.dart:237-270`, `:347-368`).
6. **Migration.** After every successful unlock (password, biometric,
   vault creation) the controller calls
   `migrateItemsToCurrentVersion` once the new session is active
   (`lib/core/security/vault_security_controller.dart:1174`, wired at
   `lib/app/bootstrap/password_manager_app.dart:64`). The migration
   decrypts every item, re-encrypts each legacy item (as v3 at the time of
   this amendment, as v4 today), and writes the whole list in one staged
   swap. This is the same
   rekey-in-progress pattern as the rekey: in-progress flag, then
   staging, then the live key (`local_encrypted_vault_repository.dart:281`,
   `:329`). Only after the swap commits does it write the marker
   `vault_item_payload_min_version = "3"` to secure storage (`:67`,
   `:596`). Crash and failure behavior:
   - Failure before the live write: the legacy blob is untouched, the
     artifacts are cleared, and the error propagates. The controller
     then drops the session and the vault stays locked, so it fails
     closed. The next unlock retries.
   - Crash after staging: `_recoverFromInterruptedRekey` clears the
     artifacts on the next access (`:607`). The live blob is still the
     intact legacy one.
   - Crash after the live write but before the marker: the next run
     finds only v3 items and writes the marker. The migration is
     idempotent and returns `0` when there is nothing to do.
7. **Downgrade defense.** While the marker is `3`, `decrypt` rejects any
   payload below v3 without decrypting it
   (`aes_gcm_vault_crypto_service.dart:91`). The rule covers payloads
   at rest (a rolled-back local blob makes `fetchItems` throw) and
   payloads from sync (skipped and reported). A marker that exists but
   cannot be parsed counts as `3`, so it fails closed (`:586`).

### Sync wire contract

- The backend `key_version` column carries the **item payload
  version**. v3 payloads ship `key_version = 3`
  (`local_encrypted_vault_repository.dart:369`).
- A receiver must know the record id *before* it decrypts. For local
  ids that are not UUIDs, the remote row id is a one-way,
  userId-salted derivation (`lib/core/sync/bidirectional_sync_service.dart:825`),
  so the receiver cannot recover the id from the row. For v3, the
  `ciphertext` column therefore carries
  `base64url_nopad(utf8(recordId)) + "." + base64(ciphertext)`
  (`lib/core/sync/sync_item_payload_codec.dart:31`). The backend stores
  this column as opaque text. The schema and RPCs are unchanged.
- On pull, `_resolveSnapshotIds` accepts the bound id only if
  `_remoteRecordIdFor(userId, boundId)` equals the row the change
  arrived under. It also persists the remote-to-local mapping, so later
  tombstones for that row resolve correctly
  (`bidirectional_sync_service.dart:236`, `:257`, `:264`). A change
  that fails this check is dropped and reported as
  `SyncStatusCodes.payloadRejected`
  (`lib/core/sync/sync_runtime_hardening.dart:103`).
- The vault then rebuilds the v3 envelope with its own session `keyId`
  (`local_encrypted_vault_repository.dart:479`), so GCM fails if the
  sender used another key generation. `applyRemoteSnapshots` skips and
  returns the ids of every snapshot that is invalid, bound to another
  record or key, downgraded, or that fails GCM (`:434`). The sync
  service reports these ids as diagnostics instead of aborting the
  batch.
- ADR-002 is unchanged. Push still uses `expected_version` CAS and
  idempotency keys, and the snapshot bookkeeping that feeds
  `expected_version` still records every pulled row. Rejecting a
  payload only keeps it out of the local vault.

### Consequences

- Moving a ciphertext between records, relabelling its `rid`, or
  replaying it under another key generation now fails authentication.
  Each case has a test (see CRYPTO.md).
- The local record id is visible to the backend in the v3 wire
  ciphertext. It is authenticated but not secret. Editor-created ids
  have the form `entry-<microseconds>`, which shows when the entry was
  created.
- Builds from before v3 cannot read v3 payloads. Once a device has
  migrated, it ignores v1/v2 pushes from devices that have not been
  updated. Those changes show up as `payload_rejected` diagnostics and
  are not merged. The remote row is not rewritten until a migrated
  device saves the item.
- Out of scope: AAD does not stop a device holding the DEK from
  pushing a *fresh*, correctly bound ciphertext with plaintext it
  chose. Its record id and version still go through CAS.

## Amendment 2026-10-20: master password record v3 and item payload v4

- Status: Accepted
- Supersedes: decision items 1, 2 and 5 of the base v2 scheme for any
  record or item this build writes, and the "all writes are v3" clause of
  the 2026-10-19 item payload amendment. **Legacy reads are unchanged**:
  v1/v2 records still verify and v1/v2/v3 item payloads still decrypt.
- Commits: `b6e6236` (record v3, NFC, policy), `4533a94` (item key, payload v4).

### Problem

Three things the 2026-10-19 amendment did not touch.

1. **Every unlock paid for Argon2id twice.** A v2 record stored two
   independent 16-byte salts (`verifierSalt`, `encryptionSalt`) and ran
   Argon2id over each: 64 MiB x 3 iterations, twice, on every unlock and
   on every master-password change. Two independent runs meant recovering
   one half did not reveal the other — but the defender paid double on
   every unlock to buy that, which is the wrong side of the trade for a
   device that is unlocked dozens of times a day.
2. **Normalization was undefined.** The same logical password could be
   typed two ways (`café` as U+00E9 or as `e` + U+0301), producing
   different byte sequences and therefore different keys, with nothing in
   the record saying which form was hashed.
3. **Every item shared one key.** Through v3 an item payload was sealed
   directly under the DEK. The DEK is the vault, so every item was the
   vault: any exposure of one item's plaintext handling was the whole
   vault.

### Decision

#### 1. Record v3 — one Argon2id run, split with HKDF-SHA256

A v3 record derives **one** 64-byte master key from **one** 16-byte
salt and splits it:

```
masterKey = Argon2id(password = NFC(pw), salt, m=64 MiB, t=3, p=1, dkLen=64)
verifier  = HKDF-SHA256(masterKey, info="vaulta:v3:verifier", 32 bytes)
kek       = HKDF-SHA256(masterKey, info="vaulta:v3:kek",      32 bytes)
dek       = AES-256-GCM-decrypt(kek, record.dek_wrap)
```

- Argon2id parameters are **unchanged**: `memory = 65536 KiB`,
  `iterations = 3`, `parallelism = 1`
  (`master_password_service.dart:67-68`, `:54`). The halving is paid for
  by spending less, not by weakening the KDF.
- The two HKDF `info` labels are domain separation, not decoration: the
  verifier half and the KEK half cannot be confused for each other even
  though they come from one run (`master_password_service.dart:62`, `:65`,
  split at `:237`).
- `verifierSalt`, `encryptionSalt` and `kdf.salt_b64` all carry the **same**
  salt. That equality is the structural proof the run happens once
  (`master_password_service.dart:120-160`;
  `test/core/security/master_password_service_v3_test.dart:73-81`).
- `kdf.dk_len` is `64`, not `32` (`master_password_service.dart:59`). A
  record still carrying `dk_len: 32` is a v2 record.

A v3 record, as persisted (`master_password_record.dart:78-92`; written at
`master_password_service.dart:135-156`):

```json
{
  "version": 3,
  "verifierIterations": 3,
  "verifierSalt":  "<16 random bytes, base64>",
  "verifier":      "<HKDF half, base64>",
  "encryptionIterations": 3,
  "encryptionSalt": "<the same salt as verifierSalt>",
  "keyId": "<base64url, 12 random bytes>",
  "createdAt": "2026-10-20T00:00:00.000Z",
  "kdf": {
    "name": "argon2id",
    "salt_b64": "<the same salt>",
    "memory_kib": 65536,
    "iterations": 3,
    "parallelism": 1,
    "dk_len": 64,
    "split": "hkdf-sha256-v3"
  },
  "dek_wrap": {
    "alg": "AES-256-GCM",
    "nonce_b64": "...",
    "ciphertext_b64": "...",
    "tag_b64": "..."
  },
  "pw_norm": "NFC"
}
```

The base ADR's reference blob above still shows `dk_len: 32`. That is the
**v2** shape and stays correct as history; a v3 record is the shape here.

#### 2. NFC before the KDF, and why legacy records must not do it

Every KDF entry point normalizes its input with
`PasswordPolicy.normalize` (`password_policy.dart:104`), which is real
Unicode NFC via `unorm_dart` (`pubspec.yaml`, `unorm_dart: ^0.3.3`), not
a partial approximation. `createRecord`, `verify` (v3 branch) and
`deriveVaultKey` all go through it
(`master_password_service.dart:121`, `:170`, `:219`).

A v3 record stores `pw_norm: "NFC"`
(`master_password_record.dart:40`, serialized at `:90`, written at
`master_password_service.dart:154`).
A v1/v2 record has no `pw_norm`, and this is load-bearing:

> NFC changes the **byte sequence** of a decomposed password.
> `café` typed as `e`+U+0301 is 5 bytes; as U+00E9 it is 4. If a v2
> record were verified against normalized bytes, every existing owner with
> a non-ASCII master password would be locked out of their own vault —
> irreversibly, because the record stores the hash of the raw bytes and
> nothing can recover the original form. So `verify` normalizes **only**
> when `record.version >= 3` and hashes the raw bytes otherwise
> (`master_password_service.dart:169-199`). Pinned by
> `master_password_service_v3_test.dart:184-232`.

Consequence for the user: in a vault created on the v3 record format,
the two ways of typing `café` are interchangeable. In a vault still on
a v1/v2 record they are **not** — the original composition is the only
one that works. This is stated here because it is exactly the kind of
thing an auditor would otherwise read as an inconsistency. Note also
that no v2 record is ever rewritten as v3 today (see G2), so "already
migrated" means "created on v3", not "upgraded to v3".

#### 3. Password policy — NIST SP 800-63B §3.1.1.2, honestly bounded

The composition rule (upper + lower + digit + symbol) is **removed**.
`MasterPasswordService.validate` now delegates to `PasswordPolicy.evaluate`
(`master_password_service.dart:105-107`,
`password_policy.dart:89-101`) and enforces exactly three things:

| Rule | Value | Why | Code |
|---|---|---|---|
| Minimum length | 12 | Above the NIST minimum of 8; the vault is the only thing between a stolen blob and every credential the owner holds | `password_policy.dart:53` |
| Maximum length | 1024 | Bounds Argon2id's input preprocessing, so a multi-megabyte paste cannot turn unlock into a local denial of service against the device's own user | `password_policy.dart:57` |
| Breached-password screening | shipped list, checked offline | NIST requires screening against commonly used / compromised passwords | `password_policy.dart:71-86` |

What is deliberately **not** enforced, per the same NIST section:
periodic rotation, blocking paste, blocking password-manager autofill, and
any character-class rule. Composition rules push users toward predictable
patterns (`Password1!`) that are weaker than a long passphrase while
rejecting non-Latin scripts for no security gain.

The screening is **local**. Vaulta never sends a password, a prefix, or a
hash of a password to a network service (`password_policy.dart`; the only
callers are `vault_security_controller.dart:407` for onboarding, `:746`
for master-password change, and
`lib/features/backup/application/vault_backup_coordinator.dart:130` for
the backup password).

**How the screening reaches past its length** (`common_password_blocklist.dart`):
the lookup is `fold(input)` against `fold(list)`, where `fold` maps
character-class substitutions onto letters (`0→o`, `1→i`, `3→e`, `4→a`,
`5→s`, `7→t`, `@→a`, `$→s`, `!→i`, `|→i`) and trims trailing symbol runs
(`:142`), and a second lookup strips trailing digits
(`stripTrailingDigits`, `:172`). Folding the *list* with the *same*
function as the input is the part that matters — folding only the input
would silently drop every mutation case (`:178-186`). Concretely:
`P@ssw0rd` and `p4ssword` both fold onto the listed `password`, and
`p@ssw0rd1234` folds onto the listed `password1234` (the digits become
`i2ea` on both sides, and the digit-stripped forms are checked too, which
is what catches `letmein12345`). Folding is lossy and is used **only**
for the lookup, never for the KDF input.

#### 4. Item payload v4 — one key per item

Each item gets its own key, derived from the DEK:

```
itemKey = HKDF-SHA256(DEK, salt = 16 random bytes per item version,
                      info = "vaulta:item:v4|<rid>|<kid>|<iv>", 32 bytes)
```

and the payload is sealed with AES-256-GCM under `itemKey`, never under
the DEK (`aes_gcm_vault_crypto_service.dart:94-111`, `:280-315`). Two
items never share a key, and compromising one item key does not reach the
DEK or any other item.

The AAD moves from `vaulta:item:v3|<rid>|<kid>` to
`vaulta:item:v4|<rid>|<kid>|<iv>` (`:67-82`), which binds the item key
version **cryptographically** rather than merely storing it: relabelling
an item under a different key version breaks the GCM tag instead of
silently rotating (pinned by `item_payload_v4_test.dart:196`).

The envelope (`aes_gcm_vault_crypto_service.dart:303-312`):

```json
{
  "v": 4,
  "keyId": "<session keyId>",
  "rid": "<recordId>",
  "iv": 1,
  "salt": "<16 random bytes, base64>",
  "kdf":       { "...only when the session is a v2+ VaultSession..." },
  "dek_wrap":  { "...ditto..." },
  "payload": {
    "alg": "AES-256-GCM",
    "nonce_b64": "...",
    "ciphertext_b64": "...",
    "tag_b64": "..."
  }
}
```

`salt` and `iv` are **read from the payload on decrypt, never assumed**
(`:235-262`), so a payload written under an older item key version keeps
opening after the DEK rotates. A v4 payload with no salt is rejected as
`malformed` rather than opened with a guessed salt
(`item_payload_v4_test.dart:358`).

The item key salt is not secret. It is stored in clear in the payload
because the item has to be reopenable; its job is domain separation across
item versions, not entropy (`aes_gcm_vault_crypto_service.dart:90-93`).

v1, v2 and v3 payloads all still decrypt (`aes_gcm_vault_crypto_service.dart:150-180`,
`item_payload_v4_test.dart:284-323`).

#### 5. What migration actually does, and what it does not

This matters for an auditor, because "items migrate to v4" is only
partly true.

> **Updated 2026-10-21 (`51517c2`).** Before that commit this section
> said `migrateItemsToCurrentVersion` rewrote only items below v3 and left
> v3 items sealed under the DEK. Both statements were correct then and
> are not now.

- `migrateItemsToCurrentVersion` is now an alias for
  `migrateItemsToItemKeyed` (`local_encrypted_vault_repository.dart:347`),
  and the function it delegates to rewrites items whose payload version is
  **below 4** — `payloadVersionV4`, not the `currentItemPayloadVersion = 3`
  constant at `:73` (`:293-335`, threshold at `:301-307`). **A v3 item is
  no longer left as v3**; this is the change that closes G2b, made in
  `51517c2`.
- A legacy item that *is* rewritten comes out as **v4**, because `encrypt`
  only ever writes the current version. So the vault goes v1/v2 → v4
  directly, never through v3 at rest.
- A v3 item also upgrades to v4 when the user next **edits** it
  (`_saveEncryptedItems` → `encrypt`), or when the master password changes
  (`rekeyEntries` re-encrypts the whole list). After `51517c2` those two
  user-driven paths are no longer the only ones.
- `vault_item_payload_min_version` is written as `3`, not `4`
  (`currentItemPayloadVersion`, `:73`; `_markMigratedToCurrentVersion`,
  `:696-703`). v3 remains an accepted floor. The downgrade defense is
  therefore unchanged from the 2026-10-19 amendment: v1/v2 are refused,
  v3 is not.
- `currentItemPayloadVersion = 3` is also the threshold for "this payload
  carries a record binding" in `_decryptStoredItem` (`:652`) and, on the
  sync path, `SyncItemPayloadCodec.boundPayloadVersion` separates "bound"
  from "item-keyed". Moving the constant to 4 would be defensible on the
  binding path — a v4 payload *is* record-bound — but it would change
  reject/retry behavior on paths that currently work. **Still undecided**
  as of 2026-10-21: no code comment and no ADR records a decision either
  way, so treat this constant as undecided rather than as a reviewed
  choice. Note this is a *different* threshold from the one that closed
  G2b, which compares against `payloadVersionV4`.

### Known gaps in this amendment

These are **not decisions**. They are things this document must not
paper over. Each needs a code change and an owner.

**Status as of 2026-10-21.** G1, G2 and G2b are **closed**; each entry
below says so and names the commit that closed it. G3 is **still open**
and is restated as a bounded, dated limit. The closed entries are kept
rather than deleted, because the earlier text described a real defect at
the time and an auditor diffing this document needs to see what changed
and when.

#### G1. CLOSED by `51517c2` — sync now carries the v4 item key salt

**Status: closed 2026-10-20 in `51517c2`** ("feat(sync): carry the v4 item
key salt across the wire"). The text below describes the gap as it stood
before that commit; the closing paragraph states what replaced it.

**ADR-002's wire did not carry the item key salt.** The `vault_blobs`
table had `ciphertext`, `nonce`, `gcm_tag` and `key_version` and nothing
else (`supabase/migrations/20260323100000_initial_vault_schema.sql:35-39`).
A v4 snapshot without its salt would make the receiving device derive a
different item key and fail to open the payload.

So the repository **declined to queue the mutation at all** rather than
queueing a broken one: `_extractSyncPayload` returned `null` for any
payload at version 4 or above, and `saveItem` only emitted the mutation
when that returned non-null. The local write still happened; only the
sync queueing was skipped. Tombstones were unaffected — they carry no
ciphertext.

Nothing was lost because **a stock build has no sync at all**: the
sync bootstrap returns `null` unless the APK was compiled with
`--dart-define=SUPABASE_URL=...` and `SUPABASE_ANON_KEY=...`
(`lib/core/sync/device_sync_bootstrap.dart:46-51`), and no release
workflow passes them (`.github/workflows/dev-apk-release.yml`).

**What replaced it (`51517c2`).** `vault_blobs` gains
`item_key_salt` and `item_key_version`, and the upsert RPC is
drop-and-recreated because `CREATE OR REPLACE FUNCTION` cannot add
parameters; the two new ones are trailing defaults, so an existing
9-argument call still resolves. The Supabase migration is
`supabase/migrations/20261021120000_add_vault_item_key_salt.sql`.

- **The refusal is gone, not merely widened.** `_extractSyncPayload` now
  refuses a payload only when it claims v4 (>= `SyncItemPayloadCodec.
  itemKeyPayloadVersion`, `= 4`, `sync_item_payload_codec.dart:42`) and
  the salt is missing, empty, not a positive integer item-key version, or
  **not valid base64** (`local_encrypted_vault_repository.dart:429-439`).
  The base64 check is what keeps a malformed salt from throwing out of
  `_decryptV4` inside `applyRemoteSnapshots` and aborting a whole pull
  batch; `_isBase64` (`:485-491`) is a try/`base64Decode`/`FormatException`
  probe.
- **The reader gates on the version, not on the columns' presence**
  (`:568-579`). An older client never names `item_key_salt` or
  `item_key_version` in its UPDATE, so their presence on a row proves
  nothing about who wrote it. The same gate and the same base64 check are
  applied on read, and an item-keyed snapshot that arrives without them is
  refused rather than decrypted against a wrong key.

**Limit on this closure.** The SQL migration
`supabase/migrations/20261021120000_add_vault_item_key_salt.sql` has
**never been executed against a real Postgres**. No workflow in
`.github/workflows/` applies it (`dev-apk-release.yml`, `flutter-ci.yml`,
`release.yml` — none reference the migration), and there is no local
Postgres in this repo. The Dart side of the wire is covered by tests
(`test/core/security/local_encrypted_vault_repository_test.dart`,
`test/core/sync/bidirectional_sync_service_test.dart`,
`test/core/sync/local_remote_vault_store_test.dart`, all added in
`51517c2`); the SQL itself is unverified against a running database.

#### G2. CLOSED by `e12e71a`; made fail-safe by `5716334`

**Status: this entry described a defect that was already fixed when it
was written, and the fix is older than the base of this branch.**
`e12e71a` ("fix(security): v2 master-password records could not derive
their DEK") corrected the derivation path and the rewrite hook on
2026-10-20, and it is an ancestor of `f2aa4a0`. Both halves of the old
text below were therefore false at `f2aa4a0`; they are kept so the diff
against the previous version of this ADR is legible.

**What the old text got wrong, checked against the code at `e0de33c`:**

- *"A v2 record therefore falls into `_deriveLegacyVaultKey`, which is
  PBKDF2."* **False.** `deriveVaultKey` sends only `record.version < 2`
  to the legacy PBKDF2 path (`master_password_service.dart:209-211`). A
  v2 record has its own Argon2id branch at `:225-235`, deriving the KEK
  from the record's own `salt_b64` / `iterations` / `memory_kib` /
  `parallelism` / `dk_len` with the **raw** password, because a v2 record
  hashed the raw bytes. The comment there says exactly this and names the
  failure mode the old text described. The old claim was a real defect
  from `b6e6236` until `e12e71a`; it is not one now.
- *"nothing migrates a v2 record to v3 ... a v2 record is never rewritten
  as v3, never acquires `pw_norm`."* **False.** The three call sites the
  old text cited — `vault_security_controller.dart:495`, `:967`, `:1091`
  — do not contain the comparison the entry quotes. They all call
  `_needsRecordMigration` (`:496`, `:971`, `:1095`), which discriminates
  on `!record.isCurrentFormat || record.kdf == null || record.dekWrap ==
  null` (`:1505-1508`), and `isCurrentFormat` is
  `version == 3 && pwNorm == "NFC"`
  (`master_password_record.dart:126`). A v2 record has `pwNorm == null`,
  so it is rewritten as v3 on the next `unlockWithPassword` and on both
  enrollment guards. The helper's own comment says this check is
  deliberately not `record.version < 2`.
- *"there is no test for v2 `deriveVaultKey`, which is why this is not
  caught."* **False now.** `e12e71a` added that coverage; see
  `test/core/security/master_password_service_v3_test.dart` and the v2
  record tests in `test/core/security/vault_security_controller_test.dart`
  (both green at `e0de33c`, 411 tests).

**What `5716334` changed, and why it is not what S3 asked for.** The
hook S3 wanted did not exist to be extended — it was already correct. What
`5716334` ("fix(security): make the v2->v3 record rewrite fail-safe")
fixed is that the rewrite is a four-step write (new DEK → re-seal entries →
persist record → re-wrap the biometric envelope) and **all three of its
failure paths could leave a half-migrated vault**:

- `unlockWithPassword` had no `try`/`catch`, so a throwing rewrite escaped
  the public API as an unhandled async error from a button while every
  sibling path returns a `bool` plus a message;
- a record-write failure left the entries already rekeyed under a DEK that
  then existed nowhere on disk;
- the envelope was re-wrapped **before** `_vaultSession` was set, so the
  unwrap found no DEK and skipped, the stale envelope kept wrapping the
  **old** DEK, `isEnrolled()` stayed true so the retry never fired, and
  the next biometric unlock reported success with a key that opens nothing.

The guarantee now is **ordering**, not a lock:

> At every instant the record on disk is a key that opens the PREVIOUS
> entries.

So a rekey or save failure **unlocks on the legacy pair and defers to the
next attempt** — it does not fail closed. Only a failure to *undo* the
rekey (`_RecordWrite.rollbackFailed`) fails closed, because that is the
single state nothing can recover. That is a deliberate design decision,
not an oversight: a half-migrated vault is neither the old vault nor the
new one, whereas the legacy pair is consistent and opens.

`_rewriteLegacyRecordOnUnlock` (`:1241-1279`) and the shared
`_rekeyThenPersistRecord` (`:1298+`, also used by `changeMasterPassword`)
never throw; every outcome is a `_RecordWrite` the caller maps to
"keep the old key" or "fail closed".

**Deliberately untouched.** `biometric_unlock_service.dart:216` and
`master_password_service.dart:187` / `:210` / `:226` still test
`record.version < 2`. They are **not** migration hooks — they ask "can a
DEK be recovered from this record" — and relaxing them to `< 3` would break
biometric unlock of v2 vaults that work today.

#### G2b. CLOSED by `51517c2` — v3 items are re-sealed to v4

**Status: closed 2026-10-20 in `51517c2`**, same commit as G1.

The old text: a pre-existing v3 item stays sealed directly under the DEK
until the user edits it or changes the master password, and "nothing
schedules that work". The scheduling was the gap, and it now exists.

`migrateItemsToItemKeyed()` (`local_encrypted_vault_repository.dart:293-335`)
is the path. It selects every stored item whose inspected payload version
is below `AesGcmVaultCryptoService.payloadVersionV4` (`:301-307`), decrypts
and re-seals each one through `encrypt` — which only ever writes the
current version — and commits the whole list in one staged swap before
writing the migration marker. `migrateItemsToCurrentVersion()` is now a
delegating alias for it (`:347`), so the unlock path that already called
the old name gets the stronger behavior with no new call site.

It is called after every successful unlock, needs no user action, and is
idempotent. It is also safe to interrupt: the repository stages the new
blob behind the rekey-in-progress marker and swaps it in only once the
rewrite completes, so a crash leaves either the intact pre-migration vault
(the next unlock retries) or a complete v4 vault.

**What is still true.** The `vault_item_payload_min_version` floor is
still written as **`3`**, not `4` (`currentItemPayloadVersion = 3`,
`:73`; `_markMigratedToCurrentVersion`, `:696-703`). v3 remains an
accepted floor at rest and from sync. After this migration a v3 item
should not survive in a vault that has been unlocked on this build, but
the floor is not raised, so a v3 payload arriving over the wire is still
decrypted rather than refused.

#### G3. OPEN — the blocklist is a real corpus, still not the Pwned corpus

**Status: still open as of 2026-10-21 (`e0de33c`).** This is a bounded,
dated limit, not a defect. Recorded here so no reader mistakes the
control for corpus coverage.

**What is actually shipped, stated as a limit an auditor can check:**

| | |
|---|---|
| Source | UK NCSC **top-100k most-used/breached passwords**, fetched as `Passwords/Common-Credentials/100k-most-used-passwords-NCSC.txt` from the `danielmiessler/SecLists` mirror (a mirror of the NCSC list, not ncsc.gov.uk directly) |
| Upstream file | 835 538 bytes, sha256 `c2e5696882c603b76bb67a47ee970897e5a76fc4c3f5547abe3d0ca340c576e0` |
| After filtering | **99 838** entries (blank, control-byte, whitespace-bearing and over-64-char lines dropped; deduplicated) |
| Shipped artifact | **161 426** truncated SHA-256 digests — first 8 bytes, 16 lowercase hex chars — in `assets/security/breached_password_sha256.txt`, 2 744 242 bytes |
| Date | corpus generated and shipped in `7590912`, 2026-10-20. **The retrieval date is not recorded anywhere in the repo** — only the commit date of the asset is; the SecLists mirror is a `refs/heads/master` path, so the upstream file can change under the same URL. |
| Source, filter and generator steps | `lib/core/security/common_password_blocklist.dart:78-121` |

**This is not "the Pwned Passwords corpus"** and must never be described
as such. It is the NCSC top-100k, roughly a tenth of the frequently-used
space that a full corpus would cover. A password outside these 99 838
entries that appears in some other breach corpus **will still be
accepted**. That is the known limit, and enlarging the corpus is a
deliberate decision about APK size and generation cost, not a bug to fix.

The 161 426 figure is not 161 426 distinct passwords: each entry is
indexed in four pre-folded forms — `lower`, `fold(lower)`,
`stripDigits(lower)`, `stripDigits(fold(lower))` — computed at build time
with the *same* `foldForBlocklist` / `stripTrailingDigits` the runtime
uses, because folding a digest set in Dart is impossible. The four forms
collapse into one digest set, which is why 99 838 entries produce 161 426
digests.

**Digests, never plaintext.** Shipping 100k passwords in clear inside the
APK would hand anyone who unpacks it a ready-made wordlist. A truncated
SHA-256 is no more invertible than a full one, so the 4.8 MB saved buys an
attacker nothing. A 64-bit prefix collision can only make an innocent
password share a prefix with a listed one — a **false rejection, never a
false acceptance** — and the expected number of colliding pairs across
161 426 digests is ~7e-10.

The corpus is loaded once at startup (`loadBreachCorpus()`, called
fire-and-forget after `runApp`). Before it lands, screening falls back to
the curated list: **degraded but correct, never a wrong rejection.** A
password typed in the first moments after launch is screened against the
short list. That trade is deliberate and is the reason `validate()` stays
synchronous.

The count is pinned by a test
(`test/core/security/password_policy_test.dart`, `expect(lines.length,
161426)`), so a regeneration must update the constant or fail loudly.

The original finding is preserved below.

#### G3 (superseded). The blocklist was curated, not the Pwned corpus

The shipped list was a **hand-curated subset** of passwords that appear at
the top of public breach corpora. It is **not** the full Pwned Passwords
list, which is roughly 800 MB even as truncated SHA-1 hashes and is not
shippable inside an APK. As of `b6e6236` the literal holds 339
whitespace-separated tokens, 319 distinct, 304 distinct after folding
(`lib/core/security/common_password_blocklist.dart:32-140`; counted, not
asserted by a test).

Consequence, stated plainly: **the screening catches the common cases, not
the comprehensive ones.** A password outside this list that appeared in
some breach corpus will be accepted. Do not read this control as coverage
of the corpus.

It also has a shape you can walk straight past: the fold maps ten
characters and the digit-strip only removes a **trailing** run. A password
that is leet-spelled *and* ends in digits with a different fold, e.g.
`P4ssw0rd!2024` or `Tr0ub4dor&3`, is **not** rejected — verified against
the shipped list, not inferred. That is what a curated list buys: high
recall on the shapes people actually reach for, and no claim about the
rest.

**How to replace it:** generate a sorted list of SHA-1 prefixes of a
corpus, ship it as a compressed asset, and replace the lookup in
`common_password_blocklist.dart` with a prefix lookup. The call sites do
not change — they only call `PasswordPolicy.isCommon`. The same file
documents this path (`common_password_blocklist.dart:20-26`).

### Measured cost

`tool/kdf_benchmark.dart`, on the development machine, median of 5 after a
warm-up:

| | median |
|---|---|
| 1 Argon2id run, 32 B output | 389 ms |
| 1 Argon2id run, 64 B output (what v3 actually uses) | 392 ms |
| 2 Argon2id runs, 32 B output (what v2 did) | 771 ms |

Output length is free: 392 ms at 64 B against 389 ms at 32 B is inside
the noise, which is what makes the 64-byte master key affordable. A
re-run on the same machine reproduces these within a few percent
(387 / 381 / 775 ms). These are wall-clock numbers on one development
machine at 64 MiB x 3, p=1; they are not a claim about any user's device.

### Consequences

- Unlock cost per attempt roughly halves at equal KDF strength. The
  throttle is unaffected: `UnlockAttemptLimiter` allows 4 free failures
  and then imposes a lockout starting at 30 s, doubling per further
  failure up to a 15 min cap, and it counts every attempt **before** the
  KDF runs (`unlock_attempt_limiter.dart:102-149`), so a cheaper unlock
  does not make online guessing cheaper relative to it.
- One item's key is not another's. The blast radius of a plaintext
  exposure in one item drops from the whole vault to one item.
- **Records and items upgrade at different rates and by different paths.**
  A vault can hold v3 records and v3 items and v4 items simultaneously.
  Since `51517c2` the item upgrade is no longer user-driven only:
  `migrateItemsToItemKeyed` re-seals every item below v4 on each unlock,
  so a vault unlocked on this build converges to all-v4 items without the
  user editing anything. What is still true is that the *floor* stayed at
  v3 — a v3 payload that arrives from another device is still decrypted,
  not refused — so "v3 items exist" remains possible, just no longer the
  default outcome of an ordinary unlock.
- **The legacy record rewrite is a migration, not a transaction.** The
  invariant "the record on disk always opens the previous entries"
  (`5716334`) means a failed v2 → v3 rewrite leaves a working vault, not
  a lost one, but it also means the upgrade is **deferred, not
  completed**: a user whose rewrite keeps failing stays on the v2 record
  indefinitely and will be told so on every unlock, with no count of how
  many attempts have failed.
- **The item key version is now part of the authenticated data.** Any
  future change to `currentItemKeyVersion` is a format change, not a
  config tweak: old payloads keep their own `iv` and stay readable
  (`aes_gcm_vault_crypto_service.dart:235-262`), which is the intended
  behavior, but the *new* label cannot be applied retroactively to an
  existing ciphertext.
- Password quality now depends on a corpus this project downloads,
  filters and hashes (G3). That is a maintenance obligation with a
  generator step, not a solved problem, and it is still not the full
  Pwned corpus — it is the NCSC top-100k, 99 838 entries, shipped in
  `7590912` on 2026-10-20.
- **Sync carries v4 again (`51517c2`), with one unverified piece.** The
  item key salt and item key version travel as `item_key_salt` /
  `item_key_version`, and the Dart side is tested. The Supabase migration
  `20261021120000_add_vault_item_key_salt.sql` has never been run against
  a real Postgres, so "a v4 item written on one device opens on another"
  is verified in Dart and **not** verified against a live backend.
  ADR-002 records the wire.
