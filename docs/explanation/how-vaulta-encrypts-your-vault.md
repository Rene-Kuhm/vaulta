# How Vaulta encrypts your vault

This page explains, without code, what happens between typing your master
password and your credentials sitting on the device. It is the reasoning
behind the implementation; the implementation itself is specified in
[ADR 0001](../adr/0001-crypto-key-derivation-and-encrypted-blob.md), and the
risks Vaulta accepts are in the
[threat model](./threat-model.md).

The short version: **your master password is never stored, never leaves the
device, and is the only thing that can open the vault.** Everything else is
derived from it, and each derivation is a one-way step with a different
purpose.

---

## The chain

```
master password
      │
      │  Argon2id  (64 MiB, 3 iterations, 1 lane)
      ▼
   master key  (64 bytes)
      │
      ├── HKDF-SHA256, info "vaulta:v3:verifier" ──▶ verifier  (to check the password)
      └── HKDF-SHA256, info "vaulta:v3:kek"      ──▶ KEK       (to unwrap the vault key)
                                                         │
                                                         │ AES-256-GCM
                                                         ▼
                                                     DEK   (32 bytes, random per vault)
                                                         │
                                                         ├── HKDF-SHA256 ──▶ item key ──▶ one entry
                                                         ├── HKDF-SHA256 ──▶ database key ──▶ the vault file (opt-in)
                                                         └── HKDF-SHA256 ──▶ backup key ──▶ the .vaulta file
```

Four properties fall out of this shape, and they are the reason it looks
like this:

1. **The master password is never stored.** The vault stores a *verifier*,
   derived from the password. It cannot be reversed into the password.
2. **The vault key (DEK) is random, not derived from the password.** The
   password only *unwraps* it. Changing the master password re-wraps the
   same DEK; it does not re-encrypt every entry.
3. **Each item has its own key.** A bug that mishandles one item's
   plaintext cannot reach the vault key or any other item.
4. **Every derivation is domain-separated.** The verifier, the KEK, the item
   keys, the database key and the backup key come from different HKDF
   `info` labels, so a key leaked from one place cannot be replayed in
   another.

## Step 1 — The master password becomes a key

Vaulta normalizes the password to Unicode **NFC** before hashing it, so the
same password typed with a composed or a decomposed accent derives the same
key. The stored record records that it was normalized (`pw_norm: "NFC"`).

**Argon2id**, not a plain hash. The parameters are
`memory = 64 MiB`, `iterations = 3`, `parallelism = 1`, chosen so that
guessing the password is expensive in *memory*, not only in time. On a
device you own, that cost is paid once per unlock, on purpose.

**One run, two halves.** Earlier versions ran Argon2id twice per unlock, to
avoid revealing half the key if the other half leaked. That doubled the cost
on every unlock to buy protection against a threat the design already
covers differently. The current format runs it **once**, derives 64 bytes,
and splits them with HKDF-SHA256 into a *verifier* half and a *KEK* half.
The two `info` labels are what keep the halves from being confused for
each other.

**The verifier is a check, not a lock.** It lets Vaulta tell "wrong
password" from "right password" without ever being able to compute the
password itself.

## Step 2 — The vault key is unwrapped

The vault key (DEK) is **32 random bytes, generated once** when the vault is
created. It is stored wrapped: AES-256-GCM under the KEK, with a unique
nonce.

The DEK is deliberately *not* derived from the password. Two reasons:

- **Changing the master password becomes cheap.** It re-wraps one blob
  instead of re-encrypting every entry.
- **The vault key can travel.** With optional sync, the wrapped DEK is
  stored server-side as metadata, so a second device that knows the master
  password rebuilds the same vault key.

## Step 3 — Every entry gets its own key

Each entry is sealed with AES-256-GCM under a key derived from the DEK with
HKDF-SHA256, using a fresh 16-byte salt per entry version.

The **AAD** (additional authenticated data) binds the ciphertext to its
context:

```
vaulta:item:v4|<recordId>|<keyId>|<iv>
```

That binding is cryptographic, not bookkeeping. It means a ciphertext cannot
be moved to a different record, relabelled as a different key version, or
replayed with a different IV: any of those changes the GCM tag and the
decryption fails instead of silently succeeding.

**The title is encrypted too.** Search decrypts only titles, not whole
entries, so looking for an entry does not decrypt every secret in the
vault.

## Step 4 — What is stored where

By default the vault is **one encrypted blob** in the platform's secure
storage (Android Keystore / Windows Credential Manager). The blob holds the
per-item envelopes described above, so everything a reader can learn from
the file is what the item keys already hide.

An **encrypted SQLite database** is the accepted replacement for that blob
([ADR 0007](../adr/0007-encrypted-local-database.md)). It is implemented
and tested, but it is **off in every normal build**: the
`VAULTA_SQLITE_STORAGE` compile-time flag defaults to `false`, so the
migration never runs over somebody's real vault because of a merge. A build
opts in with:

```bash
flutter run --dart-define=VAULTA_SQLITE_STORAGE=true
```

Turning it on for a release is the owner's decision, and it requires the
verification plan in the ADR: an encrypted `.vaulta` backup taken first,
then a real device run.

Inside that database, when it is enabled:

| Column | Contents |
| --- | --- |
| `record_id` | Opaque identifier |
| `key_id`, `key_version` | Which item key sealed it |
| `payload` | The encrypted entry, byte-for-byte the same envelope sync carries |
| `title_ct` | The encrypted title, sealed under the item key, for search |
| `category` | A fixed enum |
| `updated_at`, `deleted_at` | Timestamps |

`payload` and `title_ct` are ciphertext. The only human-readable data in the
file is the category enum and the timestamps — and the sync server already
sees those. There are no blind indexes: at this scale they would leak more
than they buy.

Deleting an entry is a **soft delete**: the row gets a `deleted_at`, and the
deletion syncs like any other change. That is what keeps a delete on one
device from reappearing on another.

## Step 5 — Biometrics do not replace the password

On Android, Vaulta can unlock the vault with a fingerprint or face. What it
does **not** do is store a copy of your password in the fingerprint sensor.

- An **RSA-2048 key** is generated inside the **Android KeyStore** and tied
  to strong biometrics.
- That key wraps the vault key. The wrapped vault key is what the app
  stores.
- To unlock, Android asks the user for a successful `BiometricPrompt` with
  a `CryptoObject` bound to that key. Only then does the app unwrap the
  vault key.

The consequence: **the biometric cannot be used to open the vault on a
device that has no enrolled biometrics.** There is no biometric
"template" to steal, because there is no biometric secret in the app.

**Below Android 11 (API 30), Vaulta refuses to create the key at all.** It
could create a weaker key that the device PIN would also authorize, and it
chooses not to: refusing is better than a downgrade. The refusal is pinned
by an instrumented test that runs on a real API 29 device, and the recorded
run is in
[the API < 30 verification reference](../reference/api30-biometric-refusal-verification.md).

**The master password remains the recovery path.** It is required to
activate biometrics, to re-enroll them after they are removed, and whenever
the envelope cannot be unwrapped.

## Step 6 — Backups are a separate key

An exported `.vaulta` backup is encrypted under its own key, derived with
Argon2id from a **backup password you choose at export time**. It is *not*
the vault key, and *not* the master password.

Why not reuse the master password? Because a backup has to survive a master
password change, and because a backup password can be shared with a
different trust boundary (a recovery copy in a safe) without giving anyone
the vault.

The backup file has an authenticated header: the header is bound as AAD to
the ciphertext, so the file cannot be altered — not its version, not its
KDF parameters, not its salt — without the tag failing.

The full decision, including the error messages and the restore merge
semantics, is in
[ADR 0006](../adr/0006-encrypted-backup-format.md).

## Step 7 — Sync, when it is on

Remote sync is **off in published builds**. When it is enabled, the model is
optimistic concurrency with explicit conflicts:

- Every record carries a monotonic `version`.
- Every write sends the `expected_version` it was based on. A mismatch is a
  conflict, not a silent overwrite.
- Every mutation carries an `idempotency_key`, so a retried request does not
  duplicate anything.
- Deletes are tombstones and sync like updates.
- The server never sees plaintext: it stores the same encrypted envelopes
  the device stores, plus the wrapped vault key.

See [ADR 0002](../adr/0002-sync-versioning-cas-idempotency-tombstones.md)
for the contract and
[ADR 0003](../adr/0003-session-policy-and-revocation.md) for how a session
can be revoked per device or everywhere at once.

---

## Why this shape and not a simpler one

**Why Argon2id with 64 MiB?** Because the vault file is designed to be
stealable. If the attacker has the file and a weak hash, the master password
is the only barrier and it is a single guess away. Memory-hard derivation
makes each guess expensive on the attacker's hardware, where it matters,
rather than on your phone, where it is paid once.

**Why not derive everything from the password directly?** Because then every
key is coupled to the password, and changing it re-encrypts everything.
The random DEK buys cheap password changes and lets the vault key travel.

**Why per-item keys?** Because a vault is a set of independent secrets. A
single key makes every item's exposure also the vault's exposure. Per-item
keys mean an exposure is contained to one item.

**Why is the title encrypted separately?** Because search has to work. The
alternative — decrypting every item to find one — turns a lookup into a
full-vault operation and puts every secret in memory at once. A separate
title ciphertext keeps search cheap without widening what is exposed.

**Why no blind indexes?** A blind index lets you test whether a value is
present without decrypting, but it also leaks the *distribution* of your
vault to anyone who reads the file. At this scale the performance gain is
not worth it.

## What this does not protect you from

The [threat model](./threat-model.md) is the complete list. The short
version:

- **A compromised device with the vault unlocked** is not defended against.
  That is the point of the auto-lock, and it is why the auto-lock matters.
- **A weak master password** defeats everything above. Length and a
  passphrase beat complexity rules, which is why Vaulta enforces length
  and a breached-password list instead of character classes.
- **A malicious or compromised OS**, a rooted device, or an attacker with
  physical access while the app is unlocked.
- **Your own copy of the export file**, if you leave the plaintext import
  export lying around.

## Where the code is

| Concern | File |
| --- | --- |
| Master password record, KDF, HKDF split | `lib/core/security/master_password_service.dart` |
| Password policy and normalization | `lib/core/security/password_policy.dart` |
| Per-item envelope and AAD | `lib/core/security/aes_gcm_vault_crypto_service.dart` |
| Biometric envelope | `lib/core/security/biometric_key_envelope_service.dart` |
| Android Keystore key | `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/KeystoreChannel.kt` |
| Encrypted local database (opt-in) | `lib/core/storage/vault_database_opener.dart`, `lib/core/storage/vault_schema.dart` |
| Backup format | `lib/core/security/vault_backup_service.dart` |
| Audit index | [the crypto architecture reference](../reference/crypto-architecture.md) |
