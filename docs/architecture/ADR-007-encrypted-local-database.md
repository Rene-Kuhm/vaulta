# ADR-007: Local vault storage moves from one encrypted blob to an encrypted database

- Status: **Accepted** (2026-10-21)
- Date: 2026-10-21
- Supersedes: none. Keeps the ADR-001 crypto contract unchanged.

## Context

Today the whole vault is one value in secure storage:

```
vault_encrypted_items_v1   ← every item, as one AES-256-GCM JSON blob
```

`LocalEncryptedVaultRepository` reads it, decrypts every item into memory
(`local_encrypted_vault_repository.dart:53`), mutates the list, re-encrypts all
of it and writes the whole thing back. The crypto is not the problem and this
ADR does not touch it: per-item keys via HKDF over the DEK, AAD binding
`vaulta:item:v4|<recordId>|<keyId>|<keyVersion>` (ADR-001), DEK wrapped by an
Argon2id-derived KEK. That contract stays exactly as it is.

The blob storage does not hold up. Measured consequences:

1. **Write amplification is O(N).** Every single edit rewrites and re-encrypts
   the entire vault. At 5,000 items a save is a multi-hundred-millisecond
   freeze, and a crash mid-write risks the whole vault.
2. **No index.** `fetchItems()` must decrypt everything before the dashboard can
   filter (`vault_dashboard_screen.dart:224-241`).
3. **No partial read.** Showing one item decrypts all of them.
4. **Attachments are impossible.** A 5 MB PDF has nowhere to live.
5. **Autofill cannot exist on top of this.** An `AutofillService` must answer
   "which items match this app/host" in milliseconds, with the UI not running.

The staging-blob machinery already in the repository (`..._staging`, and the
`vault_rekey_in_progress_v1` flag) is the workaround for (1), not a fix.

Autofill is the single missing feature that decides whether Vaulta is a password
manager or a notes app, and it is blocked behind this.

## Decision

### 1. Engine: the current SQLite stack, not the one in every tutorial

Verified against the package registry on 2026-10-21:

| Package | Version | Note |
|---|---|---|
| `sqlite3` | 3.7.1 | ships **SQLite 3.54.0**, builds itself with **native assets** |
| `drift` | 2.35.2 | typed queries, codegen, migration harness |
| `sqlite3_flutter_libs` | 0.6.0**+eol** | **end of life**: "Not used anymore, update to version 3.x of package:sqlite3" |
| `sqlcipher_flutter_libs` | 0.7.0**+eol** | **end of life**, same reason |

So: **`sqlite3` 3.x only**, with native assets (on by default in the Flutter
toolchain of this project, `flutter config` reports `defaults to on`). The
classic `sqlite3_flutter_libs` / `sqlcipher_flutter_libs` pair is dead, and any
guide still recommending it is stale.

`drift_flutter` 0.3.1 still lists the two EOL packages as dependencies. They are
no-op shims kept for compatibility, but we do not depend on them: we take
`drift` + `sqlite3` + `path_provider` and build `NativeDatabase` ourselves. No
end-of-life package in the graph.

### 2. Encryption: SQLite3 Multiple Ciphers, not SQLCipher

Both are bundled by `sqlite3` 3.x and selected with one user define:

```yaml
hooks:
  user_defines:
    sqlite3:
      source: sqlite3mc   # bundled SQLite3 Multiple Ciphers 2.6.1
```

SQLite3 Multiple Ciphers wins on the two things that matter here:

- **AEAD block ciphers.** It offers ChaCha20-Poly1305 and Ascon-AEAD128. SQLCipher
  only offers AES-256-CBC with a separate HMAC — encrypt-then-MAC, a composition
  this project already avoided at the payload layer by choosing AES-GCM
  (ADR-001). Encrypting the file with a weaker construction than the payload
  would be incoherent.
- **Freshness and licensing.** The bundled `sqlite3mc` 2.6.1 tracks SQLite
  3.54.0 and is **MIT** (`utelle/SQLite3MultipleCiphers`), while the bundled
  SQLCipher build "may include an older SQLite version" (upstream's own warning)
  and links OpenSSL on Windows, Linux and Android.

**Measured in spike zero** (see below): this build accepts exactly
`chacha20`, `ascon128`, `aes128cbc`, `aes256cbc`. It does **not** accept
`aes256gcm`, `aes128gcm`, `sqlchacha20`, `aegis128` or `aegis256`. So the AEAD
choice is **ChaCha20-Poly1305** (`pragma cipher = 'chacha20'`), not AES-GCM.

The database key is derived per session, never stored:

```
dbKey = HKDF-SHA256(DEK, info: "vaulta:db:v1", salt: per-database)
```

The DEK already only exists in memory after unlock (ADR-001), so this adds no new
key to protect and no new place for it to leak.

### 2b. Pragma order is part of the contract

Three statements, in this order, on every connection before anything else:

```sql
PRAGMA cipher = 'chacha20';   -- the build's default today, declared anyway
PRAGMA key    = :dbKey;
PRAGMA journal_mode = WAL;    -- only after the key
```

Spike zero proved both failure directions are real:

- `journal_mode = WAL` **before** the key → `SqliteException(26) file is not a
  database`: the header gets written before the cipher context exists.
- `cipher` **after** `key` → `SqliteException(26)`, also loud.

That second point is the important one: the ordering mistake fails **loudly**,
not with an empty result set. Silent data invisibility would have been a reason
to reject the whole design. It also means the default must never be relied on:
if a future bundled version changes it, old databases stop opening, so the
scheme is declared explicitly even though it matches today's default.

### 3. Pragma and schema posture

```
PRAGMA journal_mode = WAL;         -- concurrent readers, one writer
PRAGMA synchronous  = NORMAL;      -- with WAL: survives app crash, not power loss
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
```

Tables are declared `STRICT` (SQLite 3.37+): a wrong type is an error instead of
a silent coercion, which for a vault is the difference between a bug and data
loss.

### 4. The per-item encryption stays the unit of storage

Rows hold the **same v4 payload** the repository produces today; the file cipher
is defense in depth, not a replacement. Reasons:

- The sync wire format does not change, so this migration is entirely local. The
  server keeps receiving the same per-item ciphertext with the same AAD.
- The AAD binding stays meaningful: a row's ciphertext cannot be moved to
  another `record_id`, even inside our own database file.
- A future raw-row export, or a stolen `.db`, stays protected twice over.

### 5. Schema: opaque columns in clear, secrets inside the payload

```sql
CREATE TABLE vault_items (
  record_id     TEXT PRIMARY KEY,     -- opaque uuid
  key_id        TEXT NOT NULL,
  key_version   INTEGER NOT NULL,
  payload       BLOB NOT NULL,        -- the existing v4 envelope, unchanged
  title_ct      BLOB NOT NULL,        -- title alone, per-item key, AAD includes record_id
  category      TEXT NOT NULL,
  updated_at    INTEGER NOT NULL,
  deleted_at    INTEGER               -- soft delete, trash
) STRICT;
CREATE INDEX idx_vault_items_updated ON vault_items(updated_at);

CREATE TABLE vault_hosts (
  record_id TEXT NOT NULL REFERENCES vault_items(record_id) ON DELETE CASCADE,
  host      TEXT NOT NULL,
  PRIMARY KEY (record_id, host)
) STRICT;
CREATE INDEX idx_vault_hosts_host ON vault_hosts(host);
```

`title_ct` is a deliberate small duplication: search decrypts only titles (a few
KB total for thousands of items, single-digit milliseconds) instead of whole
items. `vault_hosts` lets `AutofillService` answer a lookup with one indexed
query. Nothing human-readable is stored in clear except the category enum and
timestamps, which are already metadata the sync server sees today
(`20260323100000_initial_vault_schema.sql:35-40`). No blind indexes: they leak
more than they buy at this scale.

### 6. `VaultRepository` grows lookup methods

The interface today is collection-shaped (`lib/core/security/vault_repository.dart`:
`fetchSummary`, `fetchItems`, `fetchItemById`, `saveItem`, `deleteItem`). It gains:

- `Future<List<VaultItemSummary>> search({String? query, String? host, int limit})`
- `Future<List<VaultItemSummary>> findByHost(String host)`

`fetchItems()` stays for the dashboard's full view but is no longer the path for
search or autofill. The only consumer to update is the composition root.

### 7. Migration is staged, verified, and reversible

One transaction, inside the unlock that is already happening:

1. Read and decrypt the legacy blob.
2. Insert every item plus its `title_ct` and `vault_hosts` rows.
3. Verify inside the transaction: row count matches the number of decrypted
   items, and the `record_id` set matches exactly.
4. Write `vault_storage_schema = 1` and keep the blob under
   `vault_encrypted_items_legacy_v1`.
5. The legacy blob is deleted only on the next successful unlock, and only when
   the database is readable and the marker is present.

If any step fails the transaction rolls back, the blob is untouched, and the app
works exactly as today. Nothing is destroyed on a first attempt.

Downgrade is refused, not silently degraded: the existing
`vault_item_payload_min_version` mechanism is extended to a storage schema
version. An older build that finds schema 1 refuses to open the vault and says
so.

### 8. Rekey keeps working

Rekey re-wraps the DEK; it must now also re-derive the DB key and re-key the
database in the same transaction, so the existing "rekey in progress" flag keeps
its meaning. The biometric envelope is unaffected: the DEK remains the root of
both the item keys and the database key.

### 9. What the flag exposed and does not yet close

Wiring the switch proved the sync layer was coupled to the blob implementation:
`buildDeviceSyncLifecycle` took the concrete `LocalEncryptedVaultRepository`
because it forwards pulled snapshots through `applyRemoteSnapshots`. That is now a
narrow port, `RemoteSnapshotApplier`, which the blob implements.

The SQLite storage does **not** implement it yet. Its path therefore passes
`null`, which the lifecycle already documents as "pull advances the local sync
state, vault items unchanged". This is a deliberate, recorded degradation: until
the port is implemented for the database, **sync on the SQLite path pulls nothing
into the vault**. Pull-to-apply has to be ported before the flag can default on
for anyone who syncs.

## Consequences

Positive: O(1) write per edit, indexed search, partial reads, room for
attachments, and the foundation autofill needs. Crypto contract and sync wire
format untouched. No end-of-life dependency.

Negative and accepted:

- **Native assets must build SQLite for every target**, including Windows and
  Linux desktop. This is verified by compiling, not assumed. Native assets is
  enabled by default in this toolchain but is a moving part.
- **Sync pull-to-apply is not ported** to the database storage; the gap above.
- **Two layers of encryption** to reason about. Mitigated by the rule that the
  payload envelope is byte-identical to what sync expects, so only one codec
  exists.
- **A one-time migration over someone's real vault.** Highest-risk change in the
  project: risk item 1. Single owner, prior design (this document), and the
  verification plan below.

## Rejected alternatives

- **SQLCipher instead of SQLite3 Multiple Ciphers.** CBC + HMAC instead of AEAD,
  an older bundled SQLite, and an OpenSSL link on three platforms, for no gain.
- **Keep the blob and shard it.** Keeps every problem and turns atomicity into a
  distributed problem.
- **Hive / a key-value store with a cipher.** Same whole-box rewrite per write.
  The current design wearing a hat.
- **Isar.** Fits the shape; maintenance and encryption story are not something to
  bet a password manager on.
- **Drop per-item encryption and rely on the file cipher alone.** Breaks the sync
  payload format, the AAD binding and ADR-001.
- **`drift_flutter` for convenience.** It pulls the two EOL packages into the
  graph for no benefit.

## Spike zero result (done, 2026-10-21)

Run on this machine against `sqlite3` 3.7.1 / `source: sqlite3mc`:

| Check | Result |
|---|---|
| Native assets build SQLite | **3.54.0**, built from source by the hook, works |
| Default cipher of the build | `chacha20` (ChaCha20-Poly1305, AEAD) |
| Schemes accepted | `chacha20`, `ascon128`, `aes128cbc`, `aes256cbc` |
| Schemes rejected | `aes256gcm`, `aes128gcm`, `sqlchacha20`, `aegis128`, `aegis256` |
| `STRICT` tables enforced | yes — a column without a type is rejected (`missing datatype`) |
| Secret visible in `.db` with `strings` | **no** |
| Open without key | fails, `SqliteException(26)` |
| Open with key | round-trip correct |
| `journal_mode` before key | fails, `file is not a database` |
| `cipher` after `key` | fails, not silent |

Still to prove in the real Flutter app: that the same hook configuration builds
for Android, Windows and Linux, and that `.db`/`-wal`/`-shm` contain no
plaintext **while the database is open** (the spike closed it before scanning, so
WAL was checkpointed away).

## Verification plan

Not done until all of these pass:

1. ~~**Spike zero**: cipher is AEAD, scheme applied before the key, reopening
   without the key fails clearly~~ — **done above**; the Flutter-target build is
   carried into item 9.
2. **Migration unit tests** against a synthetic blob: happy path, undecryptable
   blob, interrupted insert (must roll back and leave the blob), re-run on an
   already-migrated vault (no-op), legacy blob still present after a failure.
3. **Round-trip test**: every field of every item survives migration, compared
   against `VaultItem.toJson` before and after.
4. **Write amplification gate**: bytes written per `saveItem` must not grow with
   the vault size. Today it is O(N); after, O(1). This is the number that
   justifies the change.
5. **Performance gate** with 5,000 synthetic items: open < 300 ms, search < 50 ms,
   single save < 20 ms.
6. ~~**Confidentiality gate**: `strings` over the database, `-wal` and `-shm` files
   must not contain any secret, title or username from the test vault.~~
   **Done on device** (`integration_test/sqlite_storage_migration_test.dart`,
   Android 10 emulator): `.db` 4096 B, `-wal` 70072 B, `-shm` 32768 B, and none of
   the secret, the title, the username or the host appears in clear in any of
   them.
7. **Real vault test on device**: the migration itself is now proven on a device
   with a real legacy blob, real secure storage and the real filesystem. Still
   pending before a release default: the full sequence on a vault created through
   the UI (backup `.vaulta`, install, migrate, restart, unlock, verify, restore).
   The app sets `FLAG_SECURE`, so this step needs a manual run by a person, not
   automation: screenshots are black and the accessibility tree exposes no
   widgets by design.
8. **Existing suite green**: 445 tests, plus the new ones.
9. **Desktop builds compile** for Windows and Linux with native assets, and the
   Android build ships the encrypted SQLite, not the plain one.

## Out of scope

Attachments, autofill itself, TOTP, folders, and any change to the sync wire
format or the crypto contract. Autofill is the next wave and depends on this one.
