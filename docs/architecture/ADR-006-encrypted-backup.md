# ADR-006: Encrypted backup format (`.vaulta`) and export/restore flow

- Status: Accepted
- Date: 2026-10-19
- Supersedes: none. Builds on ADR-001 (KDF + AES-GCM contract).

## Context

Before this change Vaulta had no way to get data out. The vault lives
in device secure storage, wrapped under a DEK that is itself wrapped by
a KEK derived from the master password (ADR-001). Lose the device, or
lose its secure storage (factory reset, Keystore wipe), and the vault
is gone. Sync is opt-in and off by default (THREAT_MODEL.md, "Residual
risk acceptance" item 4), so most users have no second copy at all.
That is also why `UnlockAttemptLimiter` refuses to auto-wipe after
repeated failures: a wipe would be unrecoverable data loss.

We need a backup that:

1. restores on a **new device**, with nothing left of the old secure
   storage;
2. is safe to keep in places we do not control (cloud drive, USB
   stick, e-mail to self);
3. cannot be weakened or altered without detection;
4. can only be produced by someone who can prove they know the master
   password *now*, under the same brute-force throttle as unlock.

## Decision

### 1. Key: a separate backup password, never the vault DEK

The backup key is derived with **Argon2id from a backup password** the
user picks at export time. The vault DEK is not reused, and the backup
is not wrapped by the master-password KEK either.

- Reusing the DEK fails requirement 1: the DEK only exists wrapped in
  the old device's secure storage.
- Deriving from the master password would work on a new device, but it
  ties the backup to a password the user may later change; a separate
  password keeps old backups openable after a master-password change
  and lets the user choose how to store that secret.
- The backup password follows the master-password policy exactly: the
  check delegates to `MasterPasswordService.validate`
  (`VaultBackupCoordinator.validateBackupPassword`), so the 12-character
  minimum and the four character classes cannot drift apart. The UI
  requires a confirmation field and warns that the password cannot be
  recovered.

### 2. KDF parameters: never weaker than the vault

- **Export** uses the ADR-001 vault parameters: `memory_kib = 65536`,
  `iterations = 3`, `parallelism = 1`, `dk_len = 32`, 16-byte random
  salt. `VaultBackupService` throws `ArgumentError` if constructed with
  anything weaker, so a future refactor cannot silently produce cheaper
  backups.
- **Import floor (downgrade defense):** an envelope with
  `memory_kib < 19456` (19 MiB, the OWASP Argon2id minimum) or
  `iterations < 2` is refused with `VaultBackupFailure.insecureKdf`
  **before any derivation runs**. Without this, an attacker who can
  replace a user's backup file could hand them a cheap-to-crack
  envelope (for example to harvest a reused password via a phishing
  "restore").
  The floor is deliberately below the export parameters so that a
  future version may tune the export cost down on low-end hardware
  without stranding old files, while never accepting trivially weak
  ones.
- **Import ceiling (resource-exhaustion defense):** `memory_kib` above
  1 GiB, `iterations` above 20, `parallelism` above 16, `dk_len != 32`,
  or files over 32 MiB are refused as `malformed`, so a crafted file
  cannot make the app allocate unbounded memory or spin for minutes.

### 3. Format `.vaulta`, version 1

UTF-8 JSON. Every field is required; unknown fields are rejected.

```json
{
  "format": "vaulta-backup",
  "v": 1,
  "created_at": "2026-10-19T09:30:00.000Z",
  "app_version": "1.0.21+22",
  "kdf": {
    "name": "argon2id",
    "salt_b64": "<16 random bytes>",
    "memory_kib": 65536,
    "iterations": 3,
    "parallelism": 1,
    "dk_len": 32
  },
  "cipher": { "alg": "AES-256-GCM", "nonce_b64": "<12 random bytes>" },
  "ciphertext_b64": "...",
  "tag_b64": "<16 bytes>"
}
```

The plaintext sealed inside is:

```json
{ "items": [ VaultItem.toJson(), ... ], "exported_at": "...", "item_count": N }
```

`item_count` must equal `items.length` after decryption; a mismatch is
treated as `malformed`.

### 4. The header is authenticated (AAD)

The **header** is the envelope minus `ciphertext_b64` and `tag_b64`.
Its canonical encoding is passed to AES-256-GCM as additional
authenticated data. Canonical encoding
(`VaultBackupService.canonicalHeaderBytes`): object keys sorted by code
unit at every nesting level, no insignificant whitespace, standard JSON
string escaping as produced by `dart:convert`, UTF-8 bytes. Header
values are restricted to strings, integers and nested objects, so the
encoding is unambiguous.

On import the AAD is rebuilt from the header **as read from the file**,
so changing any header field (version, timestamps, app version, any
KDF parameter, the nonce, an added field) makes the GCM tag check fail.
Validation runs first (structure, version, floor, ceiling) and only a
structurally valid header reaches the KDF; a tampered-but-valid header
then fails decryption.

### 5. Errors: one generic message, one actionable exception

`VaultBackupFailure` distinguishes `malformed`, `unsupportedVersion`,
`insecureKdf` and `decryptionFailed` internally (tests assert on each).
The UI collapses everything except `unsupportedVersion` into **one
localized message** ("could not be opened; check the password; the file
may be damaged or modified"), so the screen is not an oracle telling an
attacker which check failed. `unsupportedVersion` gets its own text
because the user can act on it (update the app). Exception messages
never include payload content.

### 6. Export flow: throttled re-authentication, single-use grant

Settings → *Encrypted backup* → *Export backup* opens a two-step dialog
(`VaultBackupExportDialog`):

1. **Re-enter the master password.**
   `VaultBackupCoordinator.authorizeExport` calls
   `VaultSecurityController.reauthenticateWithPassword`, which goes
   through the existing private `_verifyThrottled` →
   `UnlockAttemptLimiter.runAttempt` path. There is no unthrottled
   verifier: failures count against the same persisted counter as
   unlock and change-password, a lockout rejects the attempt without
   running the KDF, and an unwritable counter fails closed. On success
   it returns a `VaultBackupExportGrant`.
2. **Choose the backup password** (+ confirmation). The dialog shows
   the item count and the "cannot be recovered" warning.
   `createBackup` requires the grant, which is:
   - single-use (consumed when sealing starts);
   - bound to the exact `VaultSession` object that was active at
     re-authentication (locking and unlocking again invalidates it);
   - valid for 5 minutes (`VaultBackupCoordinator.grantLifetime`).

The sealed bytes are then handed to the platform save dialog
(`FilePickerVaultBackupFileGateway`): on Android this is the Storage
Access Framework (`ACTION_CREATE_DOCUMENT`), so the app writes only to
the document the user created and needs no storage permission; on
Windows it is the native save dialog. While that dialog has the
foreground the background auto-lock is paused with
`beginLongRunningFlow` / `endLongRunningFlow`, the same mechanism the
CSV import uses. If the user cancels the save, the already-sealed
envelope (ciphertext only) is kept in memory so they can retry without
re-entering passwords; closing the dialog drops it.

### 7. Restore flow: preview, then merge through the normal save path

Settings → *Encrypted backup* → *Restore backup* opens
`VaultBackupRestoreScreen`:

1. pick a file (unauthenticated header check to reject obviously wrong
   files early);
2. enter the backup password; the file is decrypted in memory;
3. preview: authenticated `created_at`, total, new, kept-both and
   duplicate counts, computed by `VaultBackupMerger.plan` against the
   current vault using `VaultDuplicateDetector`. Nothing is written yet;
4. on confirm, `VaultBackupMerger.apply` re-plans against a fresh
   `fetchItems()` and writes each item with `VaultRepository.saveItem`.

Merge rules:

- **Exact duplicate** (same normalized title, username, website and
  notes, same category, identical secret) → skipped.
- **Conflict** (flagged by `VaultDuplicateDetector` but not identical)
  → both kept; the restored copy's title gets a localized suffix
  (" (restored)" / " (restaurada)").
- Anything else → added.
- Every written item gets a **fresh UUID**. A restore can therefore
  never overwrite an existing entry that happens to share an id, nor
  resurrect an id the sync layer holds a tombstone for.

Going through `saveItem` means each item is re-encrypted under the
current vault DEK and emits the usual `LocalVaultMutation.upsert`, so
sync behaves exactly as for a manual edit. `saveItem` stamps
`updatedAt` with the restore time; the original timestamps are not
preserved.

Restore is a separate entry point rather than another source in
`VaultImportScreen`: the CSV/JSON importers parse plaintext
synchronously, while a backup needs a password field and an
asynchronous, authenticated decryption step with its own error model.
Folding both into one screen would have meant restructuring the import
screen for little gain.

### 8. Memory hygiene

- Plaintext never touches disk: `VaultBackupService.export` builds the
  payload in memory and returns only the envelope; the file gateway
  only ever receives ciphertext.
- Buffers the service owns (the encoded plaintext before encryption,
  the decrypted bytes after parsing) are zero-filled, and derived keys
  are destroyed via `SecretKeyData.destroy()` when the `cryptography`
  package returns one. This is best effort: Dart `String`s (item
  secrets, typed passwords) are immutable and cannot be wiped, and the
  GC may have copied buffers. That limitation is the same one the
  vault itself already accepts (THREAT_MODEL.md, "compromised device
  with the master password in memory").
- No log line contains backup content, passwords or item fields; the
  backup code does not log at all.
- Password fields disable autocorrect, suggestions and IME
  personalized learning, and are cleared once used.

### 9. Test KDF

`VaultBackupService.test()` mirrors `MasterPasswordService.test()`: it
writes the production parameters into the header (so the import floor
checks behave as in production) but derives with HKDF-SHA256 over the
password, salt and parameters. It **throws** (not just asserts) outside
`flutter_test`, so the shortcut cannot ship. One test also round-trips
with the real Argon2id parameters (about 1 s on a desktop VM).

## Alternatives considered

- **Wrap the vault DEK with a backup KEK** (export the wrapped DEK plus
  the existing per-item ciphertexts). Smaller code, but the backup would
  carry the live DEK: compromising one backup password would expose
  every future sync payload until the next rekey. Re-encrypting under a
  backup-only key keeps the blast radius to the backup itself.
- **Plaintext CSV export.** Out of scope for this change, and the one
  export we explicitly do not want to make easy.
- **ChaCha20-Poly1305 / XChaCha.** Equally sound; AES-256-GCM is kept
  for consistency with ADR-001. A single random 96-bit nonce per file
  under a fresh random salt (hence a fresh key) has no practical
  collision risk.
- **Zip container with a manifest.** Adds a parser and attack surface
  for no benefit at vault sizes (a few MB at most).

## Consequences

- Users can recover from device loss. The backup password becomes a
  second secret the user must keep; we say so in the UI.
- A stolen backup file is an offline brute-force target protected by
  Argon2id at vault cost. That is the same exposure as a leaked vault
  blob (THREAT_MODEL.md, "Replay of a leaked ciphertext"), but now it
  is a file the user deliberately moves around.
- Restore does not delete or overwrite, so restoring the same file
  twice is idempotent (second run skips everything as duplicates).
- Format evolution: any change to the header shape or payload is a new
  `v`. This build refuses `v != 1` with an actionable message.

## Verifiable acceptance criteria

All in `test/`:

- Round trip with the test KDF and with production Argon2id; wrong
  password fails (`core/security/vault_backup_service_test.dart`).
- Each header field tampered individually fails: `created_at`,
  `app_version`, salt, every KDF cost field, nonce → `decryptionFailed`;
  `format`, `kdf.name`, `dk_len`, `cipher.alg`, extra or missing
  fields, bad lengths → `malformed` (same file).
- Ciphertext bit flip, truncation and tag bit flip fail (same file).
- `memory_kib = 19455` or `iterations = 1` → `insecureKdf`; `v = 2` →
  `unsupportedVersion` (same file).
- Merge: exact duplicates skipped, conflicts kept with suffix, fresh
  ids, existing entries untouched, second restore is a no-op
  (`features/vault/application/vault_backup_merger_test.dart`).
- Export needs a fresh throttled re-auth; a locked-out limiter blocks
  it without running the verifier; grants are single-use, expire and
  die with the session
  (`features/backup/application/vault_backup_coordinator_test.dart`).
- Export dialog validation, lockout feedback, save/cancel/retry; restore
  screen generic error, version error, preview and merge
  (`features/backup/presentation/`).
