# Crypto architecture (audit index)

> Entry point for an external crypto audit. Every claim in this
> file has a corresponding implementation, ADR, or test that the
> auditor can read directly.

## What to read, in order

1. **`THREAT_MODEL.md`** (sibling) — what we defend against, what
   we explicitly do not, and the residual risks the user accepts.
2. **`ADR-001-crypto.md`** — derivation of keys + ciphertext blob
   format v2, amended by item payload v3 (record-bound AAD,
   migration, downgrade defense, sync wire form). This is the
   cryptographic contract.
3. **`ADR-002-sync.md`** — sync CAS + idempotency + tombstones
   (server-side conflict resolution).
4. **`ADR-003-session-revocation.md`** — per-device revocation
   (server-side enforcement of "log out everywhere").
5. **`ADR-004-roadmap-sync.md`** — current sync surface decisions
   and the `vaulta-sync-surface-reduction` migration.
6. Source files (in `lib/core/security/` and `lib/core/sync/`):
   - `aes_gcm_vault_crypto_service.dart` — AES-256-GCM payload
     envelope: writes v3 (record-bound AAD), still reads v1 + v2.
   - `master_password_service.dart` — Argon2id KDF, master
     password record, vault key derivation, DEK wrapping.
   - `biometric_key_envelope_service.dart` — biometric envelope
     (DEK wrapped with platform-protected key).
   - `android_keystore_envelope_key_provider.dart` — Android
     KeyStore RSA-2048 wrapping the AES-256 envelope key.
   - `local_encrypted_vault_repository.dart` — vault writer with
     rekey-in-progress (atomic swap), v1/v2 -> v3 migration,
     min-version marker and snapshot apply.
   - `sync_item_payload_codec.dart` (in `lib/core/sync/`) — v3 wire
     form of the sync `ciphertext` column (bound record id +
     ciphertext).
   - `bidirectional_sync_service.dart` — sync loop (single owner
     of cursor + push queue).
7. Tests (in `test/core/security/` and `test/core/sync/`):
   - `aes_gcm_vault_crypto_service_test.dart` — v3 round-trip, AAD
     canonical form, record swap / keyId relabel / missing record id
     rejected, legacy v1/v2 decrypt, minimum-version refusal.
   - `item_payload_v3_test.dart` — migration (all items, idempotent,
     failed live write, crash after staging, committed-but-reported
     failure), legacy envelope refused at rest after migration, id
     mismatch rejected, sync apply: v3 round-trip, payload moved to
     another record / key generation rejected, v1/v2 accepted before and
     rejected after migration.
   - `local_encrypted_vault_repository_test.dart` — round-trip,
     rekey, snapshot apply, error cases, per-platform security plan.
   - `android_keystore_envelope_key_provider_test.dart` — non-Android
     target behavior, key persistence.
   - `bidirectional_sync_service_test.dart` — pull throttling,
     push retry, conflict registration, queue de-dup, v3 binding
     accepted only under the row it derives to (REQ-BS-AAD).
   - `device_session_revocation_service_test.dart` — revoke
     + heartbeat + retry semantics.
8. This file (you're reading it) is the index.

## Cryptographic contract (the "what")

- **Master password → KEK**: Argon2id with `memory=64 MiB`,
  `iterations=3`, `parallelism=1`, `output=32 bytes`. Salt is
  16 random bytes per user. See
  `master_password_service.dart` (`_defaultArgon2MemoryKiB`,
  `_defaultIterations`, etc.) and ADR-001.
- **KEK → DEK wrap**: AES-256-GCM, fresh 12-byte nonce per wrap.
  DEK is random 32 bytes per vault. The wrap envelope is
  persisted as `{alg, salt_b64, nonce_b64, ciphertext_b64,
  tag_b64}`. See `aes_gcm_vault_crypto_service.dart`.
- **DEK → item payload (v3)**: AES-256-GCM, fresh 12-byte nonce per
  item-version, associated data
  `utf8("vaulta:item:v3|" + recordId + "|" + keyId)`
  (`aes_gcm_vault_crypto_service.dart:37`). Envelope
  `{v:3, keyId, rid, [kdf, dek_wrap], payload:{alg, nonce_b64,
  ciphertext_b64, tag_b64}}` (`aes_gcm_vault_crypto_service.dart:134`).
  Decrypt refuses a record id other than the bound one (`:107`), and
  the repository refuses a decrypted item whose `id` differs from it
  (`local_encrypted_vault_repository.dart:573`). v1/v2 (no AAD) are
  read only until the vault has migrated.
- **Migration + downgrade defense**: after each successful unlock,
  `migrateItemsToCurrentVersion` rewrites legacy items in one staged
  swap (`local_encrypted_vault_repository.dart:281`). It then sets
  `vault_item_payload_min_version = "3"` in secure storage (`:67`).
  From then on, v1/v2 payloads are refused at rest and from sync
  (`aes_gcm_vault_crypto_service.dart:91`). If the migration fails,
  the vault stays locked
  (`vault_security_controller.dart:1174`).
- **Sync wire form (v3)**: `key_version = 3`. The `ciphertext` column
  holds `base64url_nopad(recordId) + "." + base64(ciphertext)`
  (`lib/core/sync/sync_item_payload_codec.dart:31`). The pull path
  accepts the bound id only when it derives to the row it arrived
  under (`lib/core/sync/bidirectional_sync_service.dart:257`). CAS and
  idempotency (ADR-002) are unchanged.
- **Biometric envelope** (Android): RSA-2048 in AndroidKeyStore
  with `setUserAuthenticationRequired(true)`. Wraps a fresh
  AES-256 seed per enrollment. The seed is RSA-OAEP-encrypted
  with the public key, the ciphertext is persisted in secure
  storage, the private key unlocks only after a fresh
  `BiometricPrompt`. See
  `android_keystore_envelope_key_provider.dart` and
  `biometric_key_envelope_service.dart`.
- **Storage backend**: `flutter_secure_storage` → Android
  EncryptedSharedPreferences (Keystore-wrapped) on Android, iOS
  Keychain on iOS, Windows Credential Manager on Windows.

## What the auditor should NOT expect to find

This codebase has not had a third-party crypto review. The
following are explicit non-goals for the current release:

- **No post-quantum primitives.** AES-256-GCM + Argon2id are
  classical; switching to PQ primitives is a future change.
- **No HSM / hardware root of trust on desktop.** Windows
  Credential Manager is OS-provided but not hardware-bound;
  Linux uses libsecret (best-effort); macOS uses Keychain.
- **No audit log of local unlocks.** A user with filesystem access
  to the encrypted blob cannot decrypt without the master
  password, but we do not log unlock attempts in a tamper-evident
  way.
- **No forward secrecy of sync payloads.** The DEK is the same
  for all sync operations; compromising the DEK compromises all
  future and past ciphertexts that share it (until rekey).
- **No defense against a compromised device.** A rooted/jailbroken
  device with the master password in memory is a sandbox
  bypass; we do not attempt to detect that.

See `THREAT_MODEL.md` for the full list of residual risks and the
trust assumptions.

## How to run the existing security-relevant tests

```bash
flutter test test/core/security/   # crypto, vault, biometric
flutter test test/core/sync/       # sync CAS, retry, conflict
flutter test test/features/security/  # SecurityGate widget
```

The full suite (`flutter test`, 191 tests at the time of the v3
amendment) passes on a clean checkout. The crypto tests cover the
contract behaviors: round-trip, rekey, envelope persistence and CAS
conflict registration. They also cover the adversarial cases that v3
closes: record swap, keyId relabel, id mismatch and v1/v2 downgrade.
Wider adversarial analysis is still the auditor's job.

## What we want from the audit

1. Verification that the Argon2id parameters are appropriate for
   2026+ hardware (memory cost, iteration count, parallelism).
2. Verification that the GCM nonce generation is collision-free
   under the expected concurrency.
3. Verification that the DEK is not exposed in memory dumps
   (cold-boot attack analysis).
4. Verification that the Android KeyStore RSA-2048 wrapping
   actually leverages the secure element on the target device
   classes we ship for.
5. Verification that the v1 → v2 and v1/v2 → v3 migration paths are
   safe: no double-decryption, no data loss on interruption, and no
   downgrade once `vault_item_payload_min_version` is set. This
   includes whether a local attacker who deletes that secure-storage
   marker can re-open v1/v2.
6. Threat model review: is the trust model honest? Are the
   residual risks acceptable for the user's threat profile?

The deliverable from the audit should be a written report
classifying each finding by severity (Critical / High / Medium /
Low / Informational) and proposing concrete remediations.