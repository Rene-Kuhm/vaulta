# Threat model

> Honest description of what Vaulta defends against, what it does
> not, and the residual risks the user accepts by choosing this
> product. Written for an external auditor, but also useful to
> the user when deciding whether Vaulta fits their threat profile.
>
> Snapshot of `feat/enterprise-closure` at `e0de33c` (2026-10-21),
> re-checked against the code after `7590912`, `e12e71a`, `51517c2`,
> `5716334` and `a4fc61b`. The previous snapshot was `master` at
> `618e5f1`. Where this document and the code disagree, the code wins.

## What we defend against

The primary threat we defend against is **device compromise with
seizure while the app is locked**: an attacker (e.g. a thief who
picked up an unlocked phone, a border agent, a curious coworker)
gets physical access to a powered-on device with the app in the
background. The defender is the master password, optionally
backed by a hardware-bound biometric envelope.

Concretely, against this threat we defend:

- **Offline decryption of the vault blob.** The blob is
  AES-256-GCM encrypted with a per-vault random DEK. The DEK is
  in turn encrypted with a KEK that comes from Argon2id over the
  master password (one 64 MiB / 3-iteration run, split in two with
  HKDF-SHA256). Without the password, recovering the DEK requires
  brute-forcing Argon2id, which is intentionally expensive.
- **The same password typed two ways.** The master password is
  NFC-normalized before the KDF, so `café` typed as `e`+U+0301 and
  as U+00E9 derive the same key. On a vault that has migrated to
  the v3 record format this holds; on a legacy v1/v2 record the
  original composition still matters, because those records hashed
  the raw bytes and were not rewritten (see "What we explicitly do
  NOT defend against").
- **One exposed item being the whole vault.** Since item payload v4
  every item is sealed under its own key, derived from the DEK with
  HKDF-SHA256 and a per-item-version salt. Two items never share a
  key, and recovering one item's key does not yield the DEK or any
  other item.
- **Moving a ciphertext between records, relabelling it, or
  replaying it under another key generation.** Item payloads carry
  their record id, key id and item key version as AES-256-GCM
  associated data, so each of those rewrites breaks authentication
  instead of decrypting.
- **Online password guessing.** Master-password attempts are throttled
  with a persisted exponential lockout: 4 free failures, then 30 s
  doubling to a 15 min cap. Every attempt is counted before the KDF
  runs, and the state is stored in secure storage and merged on
  re-read, so killing the app does not reset the counter.
- **Direct extraction of the DEK from secure storage.** On
  Android, the wrapped DEK is persisted in
  EncryptedSharedPreferences (Keystore-backed). On iOS, in
  Keychain. On Windows, in Credential Manager. These are
  not perfect (a rooted device can read them), but on an
  unmodified OS they raise the bar.
- **Biometric replay.** On Android, the private RSA key used to
  unwrap the DEK is bound to the BiometricPrompt and cannot be
  used without a fresh user presence check. The keystore channel
  used to also carry a decrypt path that was not authorized by any
  prompt; it was unreachable and has been deleted, so the only way
  to unwrap the seed is inside a `BiometricPrompt.CryptoObject`.
- **Sync replay / split-brain.** The sync protocol uses CAS
  (version-based) + tombstone + idempotency-key dedup. A
  malicious or replayed sync message cannot make a stale
  mutation win against a newer remote version.
- **Cross-device session leak.** Per-device revocation
  (`ADR-003` + `device_session_revocation_service.dart`) lets the
  user "log out everywhere" or revoke a specific device
  remotely, and the local session is invalidated the next time
  the lifecycle checks.
- **Tampering with the encrypted blob.** Each blob carries a
  GCM authentication tag. Any modification fails decryption and
  the load path surfaces a `FormatException` instead of silently
  accepting corrupted data.

## What we explicitly do NOT defend against

These are **known limitations** documented here so the user can
decide whether Vaulta is appropriate for their use case:

- **A compromised device with the master password in memory.**
  If the attacker has root + the master password is currently
  typed in (or just was), the DEK is in memory. Cold-boot
  attacks are partially mitigated (DEK is held in `VaultSession`
  which lives in process memory; the master password itself is
  not persisted), but we do not try to detect the breach.
- **A compromised OS keychain / secure storage.** On rooted
  Android or jailbroken iOS, the wrapped-DEK envelope is
  readable. The Argon2id layer still protects the plaintext
  DEK as long as the master password is not also compromised.
- **A legacy record's two spellings of one password.** A v1/v2
  master-password record stores the hash of the *raw* bytes it was
  given. That is deliberate — normalizing it would lock the owner
  out irreversibly — but it means a vault still on a pre-v3 record
  format that has a non-ASCII master password is only unlockable by
  typing the password in the exact composition it was created with.
  Vaulta does not tell the user which composition that was, and
  cannot. **Correction (2026-10-21):** this entry previously went on to
  say "There is currently no automatic v2 → v3 rewrite: the only hook that
  rewrites a legacy record still tests `record.version < 2`
  (`vault_security_controller.dart:495`), so a v2 record stays v2
  indefinitely". **That was false, and already false at `f2aa4a0`.**
  `e12e71a` replaced all three call sites with `_needsRecordMigration`
  (`vault_security_controller.dart:496`, `:971`, `:1095`), which
  discriminates on `!record.isCurrentFormat || record.kdf == null ||
  record.dekWrap == null` (`:1505-1508`); `isCurrentFormat` is `version
  == 3 && pwNorm == "NFC"` (`master_password_record.dart:126`). A v2
  record has no `pwNorm`, so **it is rewritten as v3 on the next
  `unlockWithPassword`**. What remains true is that the raw-password
  constraint above is a property of the *legacy* record while it exists,
  and the migration can be **deferred indefinitely** if it keeps failing:
  `5716334` made a failed rewrite fall back to unlocking on the legacy
  pair instead of failing closed, so a user whose rewrite does not
  succeed stays on v2 with no visible counter of attempts.
- **No biometric unlock on Android 6 through 10 (API 23-29).** The app
  installs from API 23 (`android/app/build.gradle.kts:52`), but the
  biometric envelope key is only minted on API 30+, where the KeyStore
  can be told "a biometric, not a device PIN"
  (`setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`). Below
  API 30 no such declaration exists and a
  `setUserAuthenticationRequired(true)` key is authorized by the
  PIN/pattern/password just as readily as by a fingerprint, so `a4fc61b`
  made the channel **refuse** rather than mint a weaker key: `isAvailable`
  answers false and `ensureKey` throws
  (`KeystoreChannel.kt:129-138`, `:229-239`). **Consequence: on Android
  6-10 there is no biometric unlock at all and the master password is
  the only way in.** That is an accepted trade — the alternative is
  raising `minSdk` to 30, which would drop those users entirely for a
  feature they still would not get. Two limits on top of it: the refusal
  has **no automated test coverage** (it needs an API < 30 device or
  emulator, and this repository has neither), and the UI tells those
  users "No biometrics detected" rather than naming the API floor, so
  the reason they are shown is not the real one.
- **A password that is breached but not on our list.** The
  breached-password screen runs against the UK NCSC top-100k
  most-used/breached passwords — **99 838 entries** after filtering,
  shipped as **161 426** truncated SHA-256 digests in
  `assets/security/breached_password_sha256.txt`, generated in
  `7590912` on **2026-10-20** from the SecLists mirror
  `Passwords/Common-Credentials/100k-most-used-passwords-NCSC.txt`
  (upstream 835 538 B, sha256 `c2e5696…c576e0`). A curated in-source
  list still screens the first frames after launch, before the corpus
  loads. **It is not the Pwned Passwords corpus**, which is not
  shippable inside an APK: roughly a tenth of the frequently-used
  space, so a password outside those 99 838 entries that appears in
  some other breach corpus **will still be accepted**. It is a speed
  bump against `Password1!`, not coverage of the corpus. Nothing is
  ever sent to a network service to check a password,
  so there is also no server-side component that grows smarter over
  time.
- **Forward secrecy on sync.** The same DEK encrypts all
  payloads. Compromising the DEK compromises every payload
  ever shipped under it. Rekeying (master password change)
  rotates the DEK, but old ciphertexts remain readable to anyone
  with the old DEK. Per-item keys reduce the blast radius of one
  item key; they do not add forward secrecy, because every item key
  is derived from the DEK.
- **Side channels (timing, cache, EM).** Argon2id is
  constant-time per the spec, but the Dart / Flutter / FFI
  layers around it are not formally side-channel analyzed.
- **Quantum attackers.** AES-256-GCM and Argon2id are
  classical; Grover's algorithm halves AES key strength, but
  we are not using PQ primitives.
- **Hardware keyloggers / compromised keyboards.** If the
  master password is captured at entry (e.g. a keylogger on a
  rooted device), no amount of crypto defends against the
  resulting plaintext. This is a general limitation of all
  password-based systems.
- **Coercion.** The master password is single-factor. A
  physical-coercion attacker who forces the user to type it has
  the same access as the user. (Mitigations like duress
  passwords are out of scope for the current release.)
- **Audit log of unlock attempts.** The local app does not
  maintain a tamper-evident log of unlock attempts or
  configuration changes. Sync-side revocations are recorded in
  the backend but the user cannot review them locally.
- **Replay of a leaked ciphertext.** If an attacker exfiltrates
  an old encrypted blob, they can keep trying to brute-force
  Argon2id forever; we do not rotate the KDF salt or invalidate
  the ciphertext on the user side. (Re-keying the master
  password does rotate the wrap, but the old wrapped-DEK
  envelope is not proactively wiped.)
- **Timing oracles in the sync protocol.** Sync operations do
  constant work per round, but the queue dispatch has timing
  variations based on queue length that could in theory leak
  information about mutation rate. We do not believe this is
  exploitable in practice but flag it for completeness.

## Known gaps in the shipped build

Not threats the user chooses to accept; gaps in what ships today.
Each is stated here so nobody has to infer it from silence.

**Status as of 2026-10-21 (`e0de33c`).** Gaps 1, 2 and 4 were closed
after this list was written and are kept below with the commit that
closed them. Gap 3 is closed for the Dart half and still open for the
Kotlin half. Two new limits were added by `51517c2` and `a4fc61b` and
are numbered 5 and 6.

1. **CLOSED by `51517c2` — sync could not carry the current item format.**
   Item payload v4 needs the item key salt, and the sync wire had nowhere
   to put it, so Vaulta refused to queue a v4 mutation rather than queue
   one the other device cannot open, and did so silently. The salt and the
   item key version now travel as `item_key_salt` /
   `item_key_version`, gated on read by `keyVersion >= 4`
   (`local_encrypted_vault_repository.dart:429-439`, `:568-579`).
   **Residual limit, new:** the Supabase migration
   `20261021120000_add_vault_item_key_salt.sql` has never been executed
   against a real Postgres and no workflow applies it, so the
   cross-device claim is verified in Dart and not against a live backend.
   See ADR-001 G1.
2. **CLOSED by `e12e71a` — a v2 master-password record did not open its
   vault.** Verification worked, but the key-derivation path for records
   below version 3 went to PBKDF2 and returned a key that was not the
   DEK, so an existing vault created before that build could fail to
   decrypt its contents. v2 records now take their own Argon2id branch
   (`master_password_service.dart:225-235`) and are rewritten as v3 on
   the next unlock (`vault_security_controller.dart:1505-1508`). See
   ADR-001 G2. **Residual limit, new:** `5716334` made a failed rewrite
   unlock on the legacy pair instead of failing closed, so the upgrade
   is safe but may be deferred indefinitely without the user being told
   how many attempts have failed.
3. **PARTIALLY closed — the biometric envelope's automated coverage.**
   At `618e5f1` every test in
   `android_keystore_envelope_key_provider_test.dart` skipped itself when
   not running on Android, and CI runs on Linux. `7590912` gave the
   provider an `isAndroid` seam so the Dart side runs on the host; the
   file now holds **33 tests, all green** at `e0de33c`. **Still open:** the
   Kotlin API < 30 refusal added by `a4fc61b` has no coverage at all,
   because verifying it needs an API < 30 device or emulator and this
   repository has neither.
4. **CLOSED by `7590912` — the password blocklist was maintained by hand.**
   There was no process to refresh it and no test pinning its contents.
   The corpus is now generated by a documented recipe
   (`common_password_blocklist.dart:78-121`), refreshed as a deliberate
   change, and its size is pinned by a test
   (`test/core/security/password_policy_test.dart`). The blocklist is
   still not comprehensive — see the NCSC top-100k limit above — but it
   can no longer drift silently.
5. **The Supabase schema change for v4 sync is unverified.**
   `supabase/migrations/20261021120000_add_vault_item_key_salt.sql`
   (`51517c2`) drops and recreates the upsert RPC with two new trailing
   default parameters. It has never been run against a real Postgres
   instance, and no workflow in `.github/workflows/` applies it. A
   reviewer should treat "v4 items sync between two devices" as
   unit-tested in Dart and unproven end to end.
6. **The Android < 30 biometric refusal is unverified by execution.**
   The Kotlin code refuses to mint the envelope key below API 30
   (`KeystoreChannel.kt:229-239`) and `a4fc61b` says so in its own commit
   message, but no test can run it here. The Dart half of the gate is
   tested; the Kotlin half is verified by reading only.

## Trust model

We **trust**:

- The user to choose a strong master password.
- The OS-provided secure storage (Android Keystore / iOS Keychain
  / Windows Credential Manager) to be intact.
- On Android, the device's TEE / StrongBox to actually hold
  the RSA private key (we use `setUserAuthenticationRequired` **and**
  `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`, so the
  device PIN is not an accepted substitute — but the device's hardware
  backing is OS-managed, and on API < 30 we do not mint the key at all
  rather than accept a weaker guarantee).
- The Dart / Flutter runtime to not leak memory to the JS bridge
  or to background isolates (we use the `cryptography` package
  with `SecretKey` which holds bytes; the package's own
  hardening is outside our control).
- The `package:meta`, `package:uuid`, `package:cryptography`,
  `package:unorm_dart` packages from pub.dev (no supply-chain
  attack mitigation beyond pub.dev's signed-publishers model).
  `unorm_dart` in particular is trusted to produce correct
  Unicode NFC: every master-password key derivation depends on
  it, and an NFC implementation that is subtly wrong would
  surface as an unlock that fails for no visible reason.

We **do not trust**:

- The filesystem to be free of leaked ciphertexts (mitigated
  only by OS-level disk encryption, which is the user's
  responsibility).
- The backend (Supabase) with the master password or the DEK;
  the server only ever sees AES-256-GCM ciphertext, but a
  backend compromise leaks all ciphertexts to the attacker.
- The user's network: TLS is the OS's responsibility. We do
  not add an extra application-layer crypto layer.
- The other devices in the sync group: a compromised device
  with a valid DEK can push arbitrary ciphertexts; the CAS
  mechanism catches version conflicts but cannot detect a
  malicious device pushing "correct" ciphertexts that decrypt
  to attacker-chosen plaintext for a known record id. Per-item
  keys do **not** change this: a device that holds the DEK can
  choose its own salt and therefore mint any item key it likes,
  then seal whatever plaintext it likes under it. The AAD still
  binds record id, key id and item key version, so it cannot
  mislabel the result, but it cannot vouch for the content.

## Residual risk acceptance

The user accepts the following risks by choosing Vaulta for the
MVP:

1. No third-party crypto review (this is the gap that
   `vaulta-audit-external` is meant to close — see
   [`../reference/crypto-architecture.md`](../reference/crypto-architecture.md)
   for the audit index).
2. Single-factor master password (no U2F, no hardware token).
3. The biometric unlock path on Android is a UX shortcut, not
   a crypto-binding guarantee. (`local_auth` does not bind
   keys to hardware by itself; the RSA-2048 wrapping in
   `AndroidKeystoreEnvelopeKeyProvider` does, but a compromised
   Keystore breaks the chain.) It is also **not available at all below
   Android 11 / API 30** — see the limitations list above.
4. Sync is disabled by default; the user has to opt in to
   Supabase sync, which moves the trust boundary to include
   the backend. The v4 item format is carried by the wire as of
   `51517c2`, but the Supabase migration behind it has never been run
   against a real Postgres, so opting in on an un-migrated backend is
   untested.
5. The master password is checked against the NCSC top-100k
   breach corpus (99 838 entries, `7590912`, 2026-10-20), not a full
   breach corpus, so password strength is less enforceable than it
   looks in the UI.
6. Vaulta's item-level key separation reduces the damage of a
   single item exposure, but every item key descends from the DEK,
   so there is no forward secrecy and no protection against a DEK
   compromise.

## What a security review should check (questions for the auditor)

1. Are the Argon2id parameters (64 MiB, 3 iterations, parallelism 1)
   appropriate for 2026+ mobile and desktop hardware? Should
   they be raised?
2. Is the AES-GCM nonce generation actually unique across
   concurrent encryptions, given the Dart isolate model and
   the way `package:cryptography` handles random nonces?
3. Since the unlock now runs Argon2id **once** and splits a
   64-byte output into two 32-byte halves with HKDF-SHA256, is
   that weaker than the previous two-independent-salt scheme in
   any way that matters to an offline attacker?
4. Does the DEK live in any place that could be exfiltrated
   by a sandboxed app on a non-rooted device (e.g. process
   memory dumps readable by other apps via /proc)? Does
   deriving a per-item key from it change that picture?
5. Does the Android KeyStore RSA-2048 actually leverage the
   secure element on the target device classes (Pixel 6/7/8,
   Samsung Galaxy S22+, etc.)?
6. Is the v1 → v2 migration path safe against a downgrade
   attack (an attacker who has a v1 blob and the user's
   password tries to re-introduce v1)?
7. Is the sync CAS protocol safe against a backend that
   lies about record versions (e.g. a malicious Supabase
   operator)?
8. Does the biometric envelope survive a Keystore wipe (e.g.
   user changes device PIN)? If yes, how does the user
   recover their vault?
9. Is the NCSC top-100k corpus a defensible control, or does it
   give users more assurance than it can actually deliver? What
   is the smallest realistic path to broader corpus coverage,
   and what does that cost in APK size?
10. ~~What is the right remediation for a v2 record that verifies
    but cannot derive its DEK?~~ **Answered in code:** `e12e71a` gave
    v2 records their own Argon2id branch and `_needsRecordMigration`
    rewrites them as v3 on unlock. The open question is now the
    migration's *ordering* guarantee — `5716334` chose "unlock on the
    legacy pair and defer" over "fail closed" — and whether deferring
    indefinitely, with no attempt counter shown to the user, is
    acceptable.
11. Is refusing the biometric envelope below API 30 the right trade,
    given it costs Android 6-10 users the feature entirely while the
    app still installs there? The alternative considered and rejected was
    `minSdk = 30`. And: the refusal is unverified by execution — how
    should that be closed without an API < 30 device in CI?
12. The Supabase migration for the v4 sync wire has never run against a
    real Postgres. What is the smallest end-to-end test (a throwaway
    database in CI?) that would make "v4 items sync between two
    devices" a claim rather than an inference?

The answers to these belong in the audit report, not in
this document.

## How to update this document

This is not a decision record (those are ADRs). It is a
**statement of the current threat model**. Update it whenever:

- A new threat class is added (e.g. a new feature, a new
  attack surface).
- A defense is added or removed (changes what we defend
  against).
- A new residual risk is identified (e.g. discovered in a
  bug report or in an external review).

Updating this file does not require an ADR; just commit with
a clear message describing the change.