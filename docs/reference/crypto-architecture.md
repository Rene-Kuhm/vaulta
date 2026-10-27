# Crypto architecture (audit index)

> Entry point for an external crypto audit. Every claim in this
> file has a corresponding implementation, ADR, or test that the
> auditor can read directly.
>
> Snapshot of `feat/enterprise-closure` at `e0de33c` (2026-10-21).
> Line references point at that commit. The previous snapshot was
> `master` at `618e5f1`, which predates `7590912`, `e12e71a`, `51517c2`,
> `5716334` and `a4fc61b` — every gap and every biometric-envelope claim
> below has been re-checked against the current tree. Where this file and
> the code disagree, the code wins.

## What to read, in order

1. **[`../explanation/threat-model.md`](../explanation/threat-model.md)** —
   what we defend against, what
   we explicitly do not, and the residual risks the user accepts.
2. **[`../adr/0001-crypto-key-derivation-and-encrypted-blob.md`](../adr/0001-crypto-key-derivation-and-encrypted-blob.md)**
   — derivation of keys + ciphertext blob
   format v2, amended twice: by item payload v3 (record-bound AAD,
   migration, downgrade defense, sync wire form) and, on 2026-10-20, by
   **master password record v3** (one Argon2id run split with
   HKDF-SHA256, NFC input, NIST-aligned policy) and **item payload v4**
   (one key per item). This is the cryptographic contract.
3. **[`../adr/0002-sync-versioning-cas-idempotency-tombstones.md`](../adr/0002-sync-versioning-cas-idempotency-tombstones.md)**
   — sync CAS + idempotency + tombstones
   (server-side conflict resolution), and the 2026-10-20 amendment
   recording that **the current item format cannot travel over the sync
   wire**.
4. **[`../adr/0003-session-policy-and-revocation.md`](../adr/0003-session-policy-and-revocation.md)**
   — per-device revocation
   (server-side enforcement of "log out everywhere").
5. **[`../adr/0004-sync-layer-roadmap.md`](../adr/0004-sync-layer-roadmap.md)**
   — current sync surface decisions
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
  See `master_password_service.dart:54-68` (constants), `:120-142`
  (`createRecord`), `:239-250` (`deriveVaultKey`), `:256`
  (`_splitMasterKey`), `master_password_record.dart:126-133`, and
  ADR-001. Re-verified at `e0de33c`, 2026-10-21.
  - **Cost, measured** (`tool/kdf_benchmark.dart`, development
    machine, median of 5): one run 389 ms, two runs 771 ms, and output
    length is free — 392 ms at 64 B against 389 ms at 32 B. That is why
    the 64-byte master key is affordable and the split is a pure win.
- **Password normalization**: NFC, via `unorm_dart`, applied before
  the KDF on the current path (`password_policy.dart:131`). Records
  record it as `pw_norm: "NFC"`. **Legacy v1/v2 records are hashed raw
  and stay that way** — NFC changes the byte sequence of a decomposed
  password, so normalizing the legacy path would lock existing owners
  out. The v2 branch passes `password` unnormalized on purpose
  (`master_password_service.dart:227-234`), so "NFC before every KDF
  call" is true of record v3 and false of v1/v2 by design.
- **Password policy**: NIST SP 800-63B §3.1.1.2. Minimum 12, maximum
  1024, plus an offline screen against a breach corpus. The composition
  rule (upper + lower + digit + symbol) is gone, and so are rotation
  prompts, paste blocking and autofill blocking. Nothing is ever sent to
  a network service.
  - **Honest limitation (unchanged, and the reason this bullet is not a
    strength claim)**: the corpus is the UK NCSC **top-100k**
    most-used/breached passwords — 99 838 entries after filtering, shipped
    as 161 426 truncated SHA-256 digests in
    `assets/security/breached_password_sha256.txt` (2 744 242 bytes),
    generated in `7590912` on 2026-10-20 from the SecLists mirror
    `Passwords/Common-Credentials/100k-most-used-passwords-NCSC.txt`.
    **It is not the Pwned Passwords corpus**, which is not shippable in
    an APK. A password outside those 99 838 entries that appears in some
    other breach corpus will still be accepted. Shipped as **SHA-256
    digests, never plaintext** — 16 lowercase hex chars of each digest,
    because a truncated SHA-256 is no more invertible than a full one and
    a 64-bit prefix collision can only cause a false *rejection*, never a
    false acceptance. Count pinned by
    `test/core/security/password_policy_test.dart`.
    Each entry is indexed under four pre-folded forms (`lower`,
    `fold(lower)`, `stripDigits(lower)`, `stripDigits(fold(lower))`) by
    the *same* `foldForBlocklist` / `stripTrailingDigits` the runtime
    uses, which is why 99 838 entries become 161 426 digests.
  - A curated in-source list is still shipped and is what screens a
    password in the frames before the corpus finishes loading — degraded
    but never a wrong rejection. Full recipe and reasoning:
    `common_password_blocklist.dart:78-121`.
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
  `migrateItemsToCurrentVersion` — now an alias for
  `migrateItemsToItemKeyed` — rewrites every item whose payload version
  is **below v4** in one staged swap
  (`local_encrypted_vault_repository.dart:293-335`, threshold at
  `:301-307`; alias at `:347`), and the result is written as v4. It then
  sets `vault_item_payload_min_version = "3"`
  (`currentItemPayloadVersion = 3`, `:73`). From then on v1/v2 payloads
  are refused at rest and from sync
  (`aes_gcm_vault_crypto_service.dart:150-180`). If the migration fails,
  the vault stays locked.
  - **v3 items ARE force-migrated (`51517c2`, 2026-10-20).** This
    sub-bullet previously read "v3 items are not force-migrated … a v3
    item becomes v4 when the user next edits it". That was true of
    `618e5f1` and is no longer. The migration is automatic, runs on every
    unlock, needs no user action, is idempotent, and is safe to interrupt:
    the new blob is staged behind the rekey-in-progress marker and swapped
    in only once the rewrite completes, so a crash leaves either the
    intact pre-migration vault (retried next unlock) or a complete v4
    vault.
  - **What did NOT change: the floor is still 3.** A v3 payload arriving
    from another device is still decrypted, not refused. G2b closed the
    scheduling gap, not the downgrade defense.
- **Sync wire form (v3 and below only)**: `key_version = 3`. The
  `ciphertext` column holds `base64url_nopad(recordId) + "." +
  base64(ciphertext)` (`lib/core/sync/sync_item_payload_codec.dart:31-39`).
  The pull path accepts the bound id only when it derives to the row it
  arrived under (`lib/core/sync/bidirectional_sync_service.dart:257`).
  CAS and idempotency (ADR-002) are unchanged.
- **Sync carries v4 (`51517c2`, 2026-10-21).** The item key salt and item
  key version travel as their own columns, `item_key_salt` and
  `item_key_version`, so a v4 snapshot opened on a second device derives
  the same item key. The write path refuses only a payload that claims v4
  *and* lacks a usable salt/version or carries a non-base64 salt
  (`local_encrypted_vault_repository.dart:429-439`) — the base64 check
  keeps a malformed salt from throwing out of `_decryptV4` inside
  `applyRemoteSnapshots` and aborting a whole pull batch. The read path
  gates on `keyVersion >= 4` rather than on the columns' presence
  (`:568-579`): an older client never names them in its UPDATE, so
  presence proves nothing. Migration:
  `supabase/migrations/20261021120000_add_vault_item_key_salt.sql`.
  **Unverified:** that SQL has never been executed against a real
  Postgres, and no workflow in `.github/workflows/` applies it. The Dart
  side is covered by tests added in the same commit.
- **Biometric envelope** (Android, **API 30+ only**): RSA-2048 in
  AndroidKeyStore with `setUserAuthenticationRequired(true)` and
  `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`
  (`KeystoreChannel.kt:275`, `:278-281`). Wraps a
  fresh AES-256 seed per enrollment. The seed is RSA-OAEP-encrypted
  with the public key, the ciphertext is persisted in secure
  storage, and the private key is used **only inside
  `MainActivity.authenticateAndDecrypt`, within a
  `BiometricPrompt.CryptoObject`**
  (`android/app/src/main/kotlin/com/insyd/gestor_contrasenas/MainActivity.kt:226`,
  prompt at `:344`). The unauthenticated RSA decrypt
  path that used to sit on the Keystore channel was deleted, not merely
  left unused.
  - **Below API 30 there is no biometric unlock at all (`a4fc61b`).** An
    earlier version of this file said API < 30 "falls back to
    `setUserAuthenticationValidityDuration(0)`". **That is no longer what
    the code does and the fallback is gone.**
    `setUserAuthenticationParameters` and `AUTH_BIOMETRIC_STRONG` were
    introduced in API 30 (`KeystoreChannel.kt:195-196`); below it a key
    that requires user auth is equally authorized by the device
    PIN/pattern/password, so there is no keystore-level way to say
    "biometric only". The channel therefore **refuses**: `isAvailable()`
    answers false (`:129-138`) and `ensureKey` throws
    `UnsupportedOperationException` (`:229-239`) — before the alias
    check, so a leftover key cannot keep unlocking through the PIN. The
    app installs from API 23 (`android/app/build.gradle.kts:52`), so this
    means **Android 6-10 users have master-password-only unlock**. Raising
    `minSdk` to 30 was the alternative and was not taken; it would drop
    those users entirely for a feature they still would not get.
  - **One prompt, by type, not by branch (`a4fc61b`).** `BiometricStack`
    is a sealed class (`lib/app/bootstrap/password_manager_app.dart:127`)
    with one final case per platform, and the prompt-owning half is a
    type (`PromptingBiometricAuthService` vs
    `NonPromptingBiometricAuthService`,
    `lib/core/security/biometric_auth_service.dart:83`, `:95`), so pairing
    a self-prompting gate with the prompting provider is unrepresentable.
    The gate also asks `canUseStrong`, not
    `canUseStrongOrCredential`
    (`lib/core/security/native_biometric_auth_service.dart:256`), which
    matches what the key actually requires.
  - **No automated coverage of the API < 30 refusal.** It needs an
    API < 30 device or emulator and this repository has neither. The Dart
    half of the gate is tested; the Kotlin refusal is verified by reading
    the code only.
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
- **No coverage of the full breach corpus.** The password screen uses
  the NCSC top-100k (99 838 entries, `7590912`), not the Pwned corpus.
  It catches `Password1!`-shaped choices; it does not catch a password
  that appeared in a breach corpus we did not copy.
- **No biometric unlock below Android 11.** API 30+ only, by choice
  (`a4fc61b`): below it the KeyStore cannot declare biometric-only
  authentication, and the alternative — a key the device PIN also
  authorizes — is the hole the API 30 declaration exists to close. The app
  still installs from API 23, so this is a missing feature on Android
  6-10, not a missing install. The refusal itself is not test-covered.
- **No defense against a compromised device.** A rooted/jailbroken
  device with the master password in memory is a sandbox
  bypass; we do not attempt to detect that.

### Known gaps, stated where an auditor will hit them

**As of 2026-10-21 (`e0de33c`).** Three of the four gaps this section
listed at `618e5f1` are closed; they are kept below with the commit that
closed them. The fourth — the biometric envelope's test coverage — was
closed for the Dart half and remains open for the Kotlin half.

- **CLOSED by `51517c2` — sync cannot carry the current item format.**
  Item payload v4 needs the item key salt; the wire had nowhere to put
  it, so the repository refused to queue a v4 mutation
  (`local_encrypted_vault_repository.dart:405-407` at `618e5f1`). The salt
  and the item key version now travel as `item_key_salt` /
  `item_key_version`, gated on read by `keyVersion >= 4`. See the
  contract above and ADR-001 G1. **Residual limit:** the Supabase
  migration `20261021120000_add_vault_item_key_salt.sql` has never been
  run against a real Postgres.
- **CLOSED by `e12e71a` — a v2 master-password record does not derive its
  DEK.** `deriveVaultKey` used to route every record below version 3
  through a PBKDF2 legacy path, so a vault still on the v2 record format
  verified but did not open (ADR-001 G2). v2 records now have their own
  Argon2id branch (`master_password_service.dart:225-235`), and
  `_needsRecordMigration` (`vault_security_controller.dart:1505-1508`)
  rewrites a v2 record as v3 on the next `unlockWithPassword`. Both
  halves of that gap entry were already false when it was written;
  `5716334` additionally made the rewrite fail-safe (a failed record
  write rolls the rekey back rather than stranding the entries).
- **CLOSED for the Dart half by `7590912`, still open for the Kotlin
  half — the biometric envelope's test coverage.** At `618e5f1` all 8
  tests in `android_keystore_envelope_key_provider_test.dart` skipped
  themselves off Android, and CI runs on Linux. The file no longer skips:
  it takes an `isAndroid` seam and runs on the host, and now holds **33
  tests, all green** at `e0de33c`. What remains uncovered is the Kotlin
  API < 30 refusal, which needs an API < 30 device or emulator that this
  repository does not have.

See [`../explanation/threat-model.md`](../explanation/threat-model.md) for the
full list of residual risks and the trust assumptions.

## How to run the existing security-relevant tests

```bash
flutter test test/core/security/   # crypto, vault, biometric
flutter test test/core/sync/       # sync CAS, retry, conflict
flutter test test/features/security/  # SecurityGate widget
```

The full suite is **411 tests, all passing** at `e0de33c`
(2026-10-21, verified with `flutter test`; `test/core/security/` alone is
258, and `android_keystore_envelope_key_provider_test.dart` is 33 of
them). The 310-test figure this section carried previously was measured
at `618e5f1`; re-run the suite rather than trusting either number. The
crypto tests cover the contract behaviors: round-trip, rekey,
envelope persistence and CAS conflict registration. They also cover the
adversarial cases: record swap, keyId relabel, id mismatch, v1/v2
downgrade, item-key-version rewrite, per-item key isolation, and a v4
payload presented without a salt.

What the suite does **not** cover, so an auditor does not assume it does:

- the **Kotlin** biometric envelope — the Dart provider is tested on the
  host through an `isAndroid` seam, but the API < 30 refusal in
  `KeystoreChannel.kt` is not exercised anywhere;
- the Supabase SQL migration, which has never met a real Postgres;
- sync round-tripping a v4 payload **against a live backend** — the Dart
  codec and repository are tested, the database round-trip is not.

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