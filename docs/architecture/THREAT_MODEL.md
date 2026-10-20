# Threat model

> Honest description of what Vaulta defends against, what it does
> not, and the residual risks the user accepts by choosing this
> product. Written for an external auditor, but also useful to
> the user when deciding whether Vaulta fits their threat profile.
>
> Snapshot of `master` at `618e5f1`. Where this document and the
> code disagree, the code wins.

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
  cannot. There is currently **no automatic v2 → v3 rewrite**: the
  only hook that rewrites a legacy record still tests
  `record.version < 2` (`vault_security_controller.dart:495`), so a
  v2 record stays v2 indefinitely and only a fresh vault creation
  produces a v3 one.
- **A password that is breached but not on our list.** The
  breached-password screen runs against a hand-curated subset of
  common breached passwords (a few hundred entries), not the full
  Pwned Passwords corpus, which is not shippable inside an APK. It
  is a speed bump against `Password1!`, not coverage of the corpus.
  Nothing is ever sent to a network service to check a password,
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

1. **Sync cannot carry the current item format.** Item payload v4
   needs the item key salt, and the sync wire has nowhere to put
   it. Vaulta therefore refuses to queue a v4 mutation at all
   rather than queue one the other device cannot open, and does so
   silently: no error, no banner, and nothing recorded about the
   skipped mutation.
   If you enable sync, **item changes made after this build will
   not propagate.** A release build has no sync backend configured
   at all (the bootstrap returns without `SUPABASE_URL` /
   `SUPABASE_ANON_KEY`), so this cannot surprise anyone today; it
   becomes live the moment those defines are supplied. Carrying the
   salt through the wire and the Supabase schema is the required
   follow-up. See ADR-002 (2026-10-20).
2. **A v2 master-password record does not currently open its
   vault.** Verification still works, but the key-derivation path
   for records below version 3 no longer uses Argon2id, so an
   existing vault created before this build may fail to decrypt its
   contents. This is a defect, not a trade-off, and it is currently
   untested. See ADR-001 G2.
3. **The biometric envelope has no automated test coverage on
   `master`.** Every test in
   `android_keystore_envelope_key_provider_test.dart` at `618e5f1`
   skips itself when it is not running on Android, and CI runs on
   Linux, so the most sensitive path in the app is exercised only by
   hand.
4. **The password blocklist is maintained by hand.** There is no
   process to refresh it from a new breach corpus, and no test
   pins its contents, so it can only drift toward being smaller.

## Trust model

We **trust**:

- The user to choose a strong master password.
- The OS-provided secure storage (Android Keystore / iOS Keychain
  / Windows Credential Manager) to be intact.
- On Android, the device's TEE / StrongBox to actually hold
  the RSA private key (we use `setUserAuthenticationRequired`,
  but the device's hardware backing is OS-managed).
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
   `vaulta-audit-external` is meant to close — see CRYPTO.md
   for the audit index).
2. Single-factor master password (no U2F, no hardware token).
3. The biometric unlock path on Android is a UX shortcut, not
   a crypto-binding guarantee. (`local_auth` does not bind
   keys to hardware by itself; the RSA-2048 wrapping in
   `AndroidKeystoreEnvelopeKeyProvider` does, but a compromised
   Keystore breaks the chain.)
4. Sync is disabled by default; the user has to opt in to
   Supabase sync, which moves the trust boundary to include
   the backend. Note the caveat above: with the current item
   format, opting in gives you a sync that silently does not
   carry item changes.
5. The master password is checked against a curated blocklist
   rather than a full breach corpus, so password strength is
   less enforceable than it looks in the UI.
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
9. Is a hand-curated blocklist a defensible control, or does it
   give users more assurance than it can actually deliver? What
   is the smallest realistic path to real corpus coverage?
10. What is the right remediation for a v2 record that verifies
    but cannot derive its DEK, and for a user already on one?

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