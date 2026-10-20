# Crypto architecture (audit index)

> Entry point for an external crypto audit. Every claim in this
> file has a corresponding implementation, ADR, or test that the
> auditor can read directly.
>
> Snapshot of `master` at `618e5f1`. Line references point at that
> commit. Where this file and the code disagree, the code wins.

## What to read, in order

1. **`THREAT_MODEL.md`** (sibling) — what we defend against, what
   we explicitly do not, and the residual risks the user accepts.
2. **`ADR-001-crypto.md`** — derivation of keys + ciphertext blob
   format v2, amended twice: by item payload v3 (record-bound AAD,
   migration, downgrade defense, sync wire form) and, on 2026-10-20, by
   **master password record v3** (one Argon2id run split with
   HKDF-SHA256, NFC input, NIST-aligned policy) and **item payload v4**
   (one key per item). This is the cryptographic contract.
3. **`ADR-002-sync.md`** — sync CAS + idempotency + tombstones
   (server-side conflict resolution), and the 2026-10-20 amendment
   recording that **the current item format cannot travel over the sync
   wire**.
4. **`ADR-003-session-revocation.md`** — per-device revocation
   (server-side enforcement of "log out everywhere").
5. **`ADR-004-roadmap-sync.md`** — current sync surface decisions
   and the `vaulta-sync-surface-reduction` migration.
6. Source files (in `lib/core/security/` and `lib/core/sync/`):
   - `aes_gcm_vault_crypto_service.dart` — AES-256-GCM payload
     envelope: writes v4 (per-item key, version-bound AAD), still
     reads v1 + v2 + v3.
   - `master_password_service.dart` — Argon2id KDF, master
     password record, vault key derivation, DEK wrapping.
   - `master_password_record.dart` — the persisted record, its
     versions, and the `pw_norm` marker.
   - `password_policy.dart` — NIST SP 800-63B §3.1.1.2 policy:
     length bounds and the offline breach screen, no composition
     rules.
   - `common_password_blocklist.dart` — the curated breached-password
     list, its fold, and how to replace it with a real corpus.
   - `unlock_attempt_limiter.dart` — persisted exponential lockout
     around unlock and password change.
   - `biometric_key_envelope_service.dart` — biometric envelope
     (DEK wrapped with platform-protected key).
   - `android_keystore_envelope_key_provider.dart` — Android
     KeyStore RSA-2048 wrapping the AES-256 envelope key.
   - `local_encrypted_vault_repository.dart` — vault writer with
     rekey-in-progress (atomic swap), v1/v2 -> v3/v4 migration,
     min-version marker, snapshot apply, and the v4 sync refusal.
   - `sync_item_payload_codec.dart` (in `lib/core/sync/`) — v3 wire
     form of the sync `ciphertext` column (bound record id +
     ciphertext).
   - `bidirectional_sync_service.dart` — sync loop (single owner
     of cursor + push queue).
7. Tests (in `test/core/security/` and `test/core/sync/`):
   - `aes_gcm_vault_crypto_service_test.dart` — v4 round-trip, AAD
     canonical form, record swap / keyId relabel / missing record id
     rejected, legacy v1/v2/v3 decrypt, minimum-version refusal.
   - `item_payload_v4_test.dart` — the per-item key contract: not
     sealed under the DEK, two items never share a key, item key
     version rewrite rejected, a missing salt refused rather than
     guessed, v3/v2 still open.
   - `master_password_service_v3_test.dart` — record v3 shape, one
     salt for verifier and KEK, the HKDF split, NFC input, and the
     NIST policy.
   - `item_payload_v3_test.dart` — migration (all items, idempotent,
     failed live write, crash after staging, committed-but-reported
     failure), legacy envelope refused at rest after migration, id
     mismatch rejected, sync apply: v3 round-trip, payload moved to
     another record / key generation rejected, v1/v2 accepted before and
     rejected after migration.
   - `local_encrypted_vault_repository_test.dart` — round-trip,
     rekey, snapshot apply, error cases, per-platform security plan.
   - `android_keystore_envelope_key_provider_test.dart` — non-Android
     target behavior, key persistence. **Caveat as of `618e5f1`: all 8
     tests begin with `if (!Platform.isAndroid) return`, so on the Linux
     CI runner the file executes zero assertions.** The biometric
     envelope therefore has no automated coverage on `master`; it needs a
     device or emulator run to be exercised.
   - `bidirectional_sync_service_test.dart` — pull throttling,
     push retry, conflict registration, queue de-dup, v3 binding
     accepted only under the row it derives to (REQ-BS-AAD).
   - `device_session_revocation_service_test.dart` — revoke
     + heartbeat + retry semantics.
8. `tool/kdf_benchmark.dart` — the measurement behind the Argon2id
   parameter choices. `dart run tool/kdf_benchmark.dart`.
9. This file (you're reading it) is the index.

## Cryptographic contract (the "what")

- **Master password → master key → two halves**: Argon2id with
  `memory=64 MiB`, `iterations=3`, `parallelism=1`,
  `output=64 bytes` over a single 16-byte random salt. The 64-byte
  output is split with HKDF-SHA256 into a **verifier** half
  (`info="vaulta:v3:verifier"`) and a **KEK** half
  (`info="vaulta:v3:kek"`). One Argon2id run per unlock, not two; the
  `info` labels are domain separation between the halves. Records
  written by this build are `version: 3` and carry `pw_norm: "NFC"`.
  See `master_password_service.dart:59-68`, `:120-155`, `:237-250`,
  `master_password_record.dart`, and ADR-001.
  - **Cost, measured** (`tool/kdf_benchmark.dart`, development
    machine, median of 5): one run 389 ms, two runs 771 ms, and output
    length is free — 392 ms at 64 B against 389 ms at 32 B. That is why
    the 64-byte master key is affordable and the split is a pure win.
- **Password normalization**: NFC, via `unorm_dart`, applied before
  every KDF call (`password_policy.dart:104`). Records record it as
  `pw_norm: "NFC"`. **Legacy v1/v2 records are hashed raw and stay
  that way** — NFC changes the byte sequence of a decomposed password,
  so normalizing the legacy path would lock existing owners out.
- **Password policy**: NIST SP 800-63B §3.1.1.2. Minimum 12, maximum
  1024, plus an offline screen against a **curated** list of common
  breached passwords. The composition rule (upper + lower + digit +
  symbol) is gone, and so are rotation prompts, paste blocking and
  autofill blocking. Nothing is ever sent to a network service.
  - **Honest limitation**: the shipped list is a hand-curated subset
    (339 tokens / 319 distinct / 304 after folding, counted from
    `common_password_blocklist.dart:32-140`), **not** the Pwned
    Passwords corpus, which is not shippable in an APK. It catches the
    common cases, not the comprehensive ones. `common_password_blocklist.dart:20-26`
    documents how to swap in a compressed SHA-1 prefix corpus without
    touching a single call site.
- **KEK → DEK wrap**: AES-256-GCM, fresh 12-byte nonce per wrap.
  DEK is random 32 bytes per vault. The wrap envelope is
  persisted as `{alg, salt_b64, nonce_b64, ciphertext_b64,
  tag_b64}`. See `aes_gcm_vault_crypto_service.dart`.
- **DEK → item key → item payload (v4)**: every item gets its own key,
  `HKDF-SHA256(DEK, salt = 16 fresh random bytes,
  info = "vaulta:item:v4|<rid>|<kid>|<iv>")`
  (`aes_gcm_vault_crypto_service.dart:94-111`), and the payload is
  sealed with AES-256-GCM under **that key, never under the DEK**
  (`:280-315`). Two items never share a key.
  Envelope `{v:4, keyId, rid, iv, salt, [kdf, dek_wrap],
  payload:{alg, nonce_b64, ciphertext_b64, tag_b64}}`
  (`:303-314`). The AAD is
  `utf8("vaulta:item:v4|" + recordId + "|" + keyId + "|" + itemKeyVersion)`
  (`:67-82`), so the item key version is **bound, not just stored**:
  rewriting it breaks the GCM tag. Decrypt reads `salt` and `iv` from
  the payload and never guesses them; a payload with no salt is
  rejected as `malformed` (`:235-262`).
  v1/v2 (no AAD) and v3 (AAD without the version) still decrypt
  (`:150-180`).
- **Migration + downgrade defense**: after each successful unlock,
  `migrateItemsToCurrentVersion` rewrites items **below v3** in one
  staged swap (`local_encrypted_vault_repository.dart:282-323`) and the
  result is written as v4. It then sets
  `vault_item_payload_min_version = "3"`
  (`:607-615`). From then on v1/v2 payloads are refused at rest and
  from sync (`aes_gcm_vault_crypto_service.dart:164-169`). If the
  migration fails, the vault stays locked
  (`vault_security_controller.dart:521`).
  - **v3 items are not force-migrated.** A vault can hold v3 and v4
    items side by side; a v3 item becomes v4 when the user next edits
    it or when the master password changes. The v3 floor is deliberate,
    not an oversight (`local_encrypted_vault_repository.dart:72`).
- **Sync wire form (v3 and below only)**: `key_version = 3`. The
  `ciphertext` column holds `base64url_nopad(recordId) + "." +
  base64(ciphertext)` (`lib/core/sync/sync_item_payload_codec.dart:31-39`).
  The pull path accepts the bound id only when it derives to the row it
  arrived under (`lib/core/sync/bidirectional_sync_service.dart:257`).
  CAS and idempotency (ADR-002) are unchanged.
- **Sync does not carry v4, and says so by refusing**: the wire has no
  field for the item key salt, so a v4 snapshot would open with the
  wrong key on the receiving device. The repository therefore does not
  queue a v4 mutation at all
  (`local_encrypted_vault_repository.dart:405-407`, `:196-212`). Local
  writes and tombstones are unaffected. This is silent — no UI warning.
  See ADR-002's 2026-10-20 amendment. Nothing is lost today only
  because a release build has no sync backend configured at all
  (`lib/core/sync/device_sync_bootstrap.dart:46-51`; no workflow passes
  the required `--dart-define`s).
- **Biometric envelope** (Android): RSA-2048 in AndroidKeyStore
  with `setUserAuthenticationRequired(true)` and, on API 30+,
  `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`
  (`KeystoreChannel.kt:154-159`; API < 30 falls back to
  `setUserAuthenticationValidityDuration(0)`). Wraps a
  fresh AES-256 seed per enrollment. The seed is RSA-OAEP-encrypted
  with the public key, the ciphertext is persisted in secure
  storage, and the private key is used **only inside
  `MainActivity.authenticateAndDecrypt`, within a
  `BiometricPrompt.CryptoObject`**
  (`android/app/src/main/kotlin/com/insyd/gestor_contrasenas/MainActivity.kt:226`). The unauthenticated RSA decrypt
  path that used to sit on the Keystore channel was deleted, not merely
  left unused (`KeystoreChannel.kt:199-206`).
- **Unlock throttling**: 4 free failures, then a lockout starting at
  30 s and doubling per further failure to a 15 min cap. State is
  persisted in secure storage, merged rather than overwritten on
  re-read, and every attempt is counted **before** the KDF runs, so
  killing the app mid-derivation still costs an attempt
  (`unlock_attempt_limiter.dart:40-56`, `:102-149`).
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
  way. The brute-force throttle is persisted state, not an
  append-only record an auditor can read after the fact.
- **No forward secrecy of sync payloads.** The DEK is the same
  for all sync operations; compromising the DEK compromises all
  future and past ciphertexts that share it (until rekey). Per-item
  keys limit the blast radius of one *item key*, but every item key
  is derived from the DEK, so a compromised DEK still reaches all of
  them.
- **No coverage of the full breach corpus.** The password screen
  uses a curated list of ~300 common passwords, not the Pwned corpus.
  It catches `Password1!`-shaped choices; it does not catch a
  password that appeared in a breach corpus we did not copy.
- **No defense against a compromised device.** A rooted/jailbroken
  device with the master password in memory is a sandbox
  bypass; we do not attempt to detect that.

### Known gaps, stated where an auditor will hit them

- **Sync cannot carry the current item format.** Item payload v4
  needs the item key salt, the wire does not carry it, so the
  repository refuses to queue a v4 mutation
  (`local_encrypted_vault_repository.dart:405-407`). Sync is
  therefore **not working with the current format**, silently. See
  ADR-002 (2026-10-20) and ADR-001 G1. Carrying the salt through
  the wire and the Supabase schema is the required follow-up.
- **A v2 master-password record does not currently derive its DEK.**
  `deriveVaultKey` routes every record below version 3 through a
  PBKDF2 legacy path, so a vault still on the v2 record format
  verifies but does not open. See ADR-001 G2. This is a defect, not
  a design choice, and it is untested.
- **The biometric envelope has no automated coverage on `master`.**
  All 8 tests in `android_keystore_envelope_key_provider_test.dart` at
  `618e5f1` skip themselves when they are not running on Android, and CI
  runs on Linux, so the most sensitive path in the app is exercised only
  by hand.

See `THREAT_MODEL.md` for the full list of residual risks and the
trust assumptions.

## How to run the existing security-relevant tests

```bash
flutter test test/core/security/   # crypto, vault, biometric
flutter test test/core/sync/       # sync CAS, retry, conflict
flutter test test/features/security/  # SecurityGate widget
```

The full suite is **310 tests, all passing** on `master` at `618e5f1`
(verified with `flutter test`; `test/core/security/` alone is 176).
The crypto tests cover the contract behaviors: round-trip, rekey,
envelope persistence and CAS conflict registration. They also cover the
adversarial cases: record swap, keyId relabel, id mismatch, v1/v2
downgrade, item-key-version rewrite, per-item key isolation, and a v4
payload presented without a salt.

What the suite does **not** cover, so an auditor does not assume it does:

- the Android biometric envelope
  (`android_keystore_envelope_key_provider_test.dart` is inert
  off-device at `618e5f1`);
- the v2-record → DEK path (there is no test for it — see ADR-001 G2);
- sync round-tripping a v4 payload, because the code refuses to send one.

Wider adversarial analysis is still the auditor's job.

## What we want from the audit

1. Verification that the Argon2id parameters are appropriate for
   2026+ hardware (memory cost, iteration count, parallelism), now that
   the run count has halved and the output is 64 bytes instead of 32.
2. Verification that the HKDF-SHA256 split is sound: that
   `info="vaulta:v3:verifier"` and `info="vaulta:v3:kek"` cannot
   collide in any way that matters, and that deriving both halves from
   one 64-byte output is not weaker than two independent salts.
3. Verification that NFC-before-KDF is applied on every path that
   reaches the KDF, and that no v1/v2 path normalizes.
4. Review of the password policy as a control: is 12/1024 plus a
   curated blocklist a defensible position, or should the ceiling and
   the list strategy change?
5. Verification that the GCM nonce generation is collision-free
   under the expected concurrency.
6. Verification that the DEK is not exposed in memory dumps
   (cold-boot attack analysis), and whether the per-item key derivation
   changes that picture.
7. Verification that the Android KeyStore RSA-2048 wrapping
   actually leverages the secure element on the target device
   classes we ship for, and that deleting the unauthenticated decrypt
   path left no reachable gap in the enrollment or unlock flow.
8. Verification that the v1 → v2, v1/v2 → v4 and v3 → v4 migration
   paths are safe: no double-decryption, no data loss on interruption,
   and no downgrade once `vault_item_payload_min_version` is set. This
   includes whether a local attacker who deletes that secure-storage
   marker can re-open v1/v2.
9. Assessment of the v2-record defect (ADR-001 G2) and of the v4/sync
   gap (ADR-001 G1): what is the correct remediation, and what should
   the product do about users already on those versions?
10. Threat model review: is the trust model honest? Are the
    residual risks acceptable for the user's threat profile?

The deliverable from the audit should be a written report
classifying each finding by severity (Critical / High / Medium /
Low / Informational) and proposing concrete remediations.