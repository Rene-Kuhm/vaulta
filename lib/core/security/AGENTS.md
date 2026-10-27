# AGENTS.md — `lib/core/security`

The security core: the master password and its key derivation, the vault key
and its envelope, AES-256-GCM, the biometric gate, the secure storage, the
clipboard, the password policy and the encrypted-blob repository. Its edge is
the vault key: the DEK exists only in the in-memory `VaultSession`, and the
record on disk holds the KDF parameters, the wrapped DEK and the verifier —
never the DEK.

The map of this module: `mise run repo-map --module lib/core/security`.

## Invariants

- The key derivation is fixed: Argon2id with 64 MiB, 3 iterations and
  parallelism 1, whose 64-byte output is split with HKDF-SHA256 into a
  verifier and a KEK (ADR-0001). The parameters live in the record, so a
  future build can read an older vault without re-deriving it wrongly.
- The master-password record is written in the current format only (version
  3, an HKDF split, NFC-normalized input); a record of an older format is
  migrated, never overwritten in place.
- Every item is encrypted with its own key, derived per item version and bound
  through the AAD to the record id, the key id and the item key version
  (`vaulta:item:v3` / `vaulta:item:v4`). An attacker holding the DEK cannot
  move an item between records or key versions.
- The vault is read only through `VaultRepository`. The repository never
  returns plaintext it did not decrypt, and it never writes an item without a
  session.
- A failed unlock is throttled by `UnlockAttemptLimiter`: every attempt is
  counted *before* the password is checked, so killing the process mid-KDF
  still costs an attempt, and a rollback of the device clock cannot unlock
  the vault earlier than the lockout period. The limiter never wipes the
  vault: an auto-wipe would be silent data loss for anyone without a recent
  encrypted backup (ADR-0006).
- A copied secret leaves through `SensitiveClipboardService`, which marks the
  clip as sensitive and clears it after 30 seconds or when the vault locks.
  Clearing is "clear if owned": a clip the user copied afterwards is not
  wiped.
- The master password is never stored, logged or recoverable. The verifier is
  a derived value, not the password.

## How it is tested

- `test/core/security/master_password_service_v3_test.dart` — the KDF
  parameters, the HKDF split, the record lifecycle and the rekey.
- `test/core/security/aes_gcm_vault_crypto_service_test.dart` — the AEAD:
  the per-item key derivation, the AAD binding and the rejected payloads.
- `test/core/security/item_payload_v3_test.dart` and
  `test/core/security/item_payload_v4_test.dart` — the payload format
  versions and their domain separation.
- `test/core/security/vault_security_controller_test.dart` — the unlock flow:
  the stage machine, the failed attempts and the lifecycle hooks.
- `test/core/security/unlock_attempt_limiter_test.dart` — the lockout
  schedule and the clock-jump handling.
- `test/core/security/biometric_unlock_service_test.dart` — the biometric
  outcomes and the envelope.
- `test/core/security/sensitive_clipboard_service_test.dart` — the copy, the
  timed wipe and the "clear if owned" rule.
- `test/core/security/password_policy_test.dart` — the policy verdict.
- `test/core/security/local_encrypted_vault_repository_test.dart` and
  `test/core/security/vault_backup_service_test.dart` — the blob repository
  and the backup format.
- `test/core/security/android_keystore_envelope_key_provider_test.dart` —
  the envelope key on the platform channel.
- The coverage gate is `bash scripts/check_coverage.sh coverage/lcov.info
  lib/core/security 60`: this module has a 60 % floor. Lowering it is not a
  fix.

## Do not touch

- The cryptographic parameters — Argon2id, the HKDF-SHA256 split, AES-256-GCM,
  the payload versions and their AAD binding. They are the contract in
  ADR-0001 and in `docs/reference/crypto-architecture.md`; changing one is a
  format change and needs an ADR.
- The `MethodChannel` names (`com.insyd.vaulta/keystore`,
  `com.insyd.vaulta/biometric`, `com.insyd.vaulta/clipboard`). Each name
  exists exactly once in Dart and once in Kotlin, so renaming one is a
  two-file change that has to land together.
- `VaultRepository` — it is the read/write port every layer speaks; adding a
  method to it changes a contract other modules already consume.
- The `// ignore_for_file:` suppressions. They are grandfathered debt: new
  code in a suppressed file must satisfy the rule, and a new suppression needs
  a justification in an adjacent comment.
- The coverage threshold. It is the CI floor for the security core.

## Boundaries

- Depends on: `lib/features/vault/domain` — the `VaultItem` and
  `VaultSummary` types only, never a screen.
- Never imports: `lib/features/*/presentation`, `lib/app` and
  `lib/core/storage`. `lib/core` never imports a screen, and the storage
  module depends on this one, not the other way round.
- Never imports: `lib/core/sync` for behavior. Only the sync *ports and
  value types* are imported — `RemoteSnapshotApplier`, `RemoteSnapshotEnvelope`,
  `RemoteVaultBlobChange`, `LocalVaultMutation`, `LocalVaultMutationSink` and
  `SyncItemPayloadCodec` — never the sync service or its Supabase
  implementations. The dependency runs the other way: the sync layer plugs
  into the repository through the ports declared here.
