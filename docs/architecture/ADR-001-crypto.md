# ADR-001: Derivacion de claves y formato de blob cifrado v2

- Estado: Aprobado
- Fecha: 2026-03-23

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
   vault is migrated. All writes, including rekey output, are v3
   (`local_encrypted_vault_repository.dart:236`, `:346`).
6. **Migration.** After every successful unlock (password, biometric,
   vault creation) the controller calls
   `migrateItemsToCurrentVersion` once the new session is active
   (`lib/core/security/vault_security_controller.dart:1174`, wired at
   `lib/app/bootstrap/password_manager_app.dart:64`). The migration
   decrypts every item, re-encrypts each legacy item as v3, and writes
   the whole list in one staged swap. This is the same
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
