# ADR-007: Local vault storage moves from one encrypted blob to an encrypted database

- Status: Proposed
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
   filter (`vault_dashboard_screen.dart:224-241`). Search cost grows with the
   vault.
3. **No partial read.** Showing one item decrypts all of them.
4. **Attachments are impossible.** A 5 MB PDF has nowhere to live.
5. **Autofill cannot exist on top of this.** An `AutofillService` must answer
   "which items match this app/host" in milliseconds, with the UI not running
   and the user not waiting for a full decrypt.

The staging-blob machinery already in the repository (`..._staging`, and the
`vault_rekey_in_progress_v1` flag) is the workaround for (1), not a fix: it
exists because a whole-vault rewrite can be interrupted.

Autofill is the single missing feature that decides whether Vaulta is a password
manager or a notes app, and it is blocked behind this.

## Decision

### 1. Engine: SQLite through `drift`, file encrypted with SQLCipher

Add `drift`, `drift_flutter`, `sqlite3_flutter_libs` and
`sqlcipher_flutter_libs`.

SQLite is chosen because the requirements are a database's job: transactional
writes, an index, partial reads, schema migrations with a version, and a
concurrency story (WAL). `drift` is chosen for typed queries, generated code and
a migration test harness. SQLCipher is chosen so the file itself is not readable
without the key, including journal and WAL files.

The DB key is derived per session, never stored:

```
dbKey = HKDF-SHA256(DEK, info: "vaulta:db:v1", salt: per-database)
```

The DEK already only exists in memory after unlock (ADR-001), so this adds no new
key to protect and no new place for it to leak.

### 2. The per-item encryption stays the unit of storage

Rows hold the **same v4 payload** the repository produces today; SQLCipher is
defense in depth, not a replacement for it. Reasons:

- The sync wire format does not change, so this migration is entirely local. The
  server keeps receiving the same per-item ciphertext with the same AAD.
- The AAD binding stays meaningful: a row's ciphertext still cannot be moved to
  another `record_id` even inside our own database file.
- A future raw-row export stays as protected as the vault.

Cost is a second AES-GCM pass per read/write, which is irrelevant next to the
O(N) rewrite it removes.

### 3. Schema: opaque columns in clear, secrets inside the payload

```
CREATE TABLE vault_items (
  record_id     TEXT PRIMARY KEY,     -- opaque uuid
  key_id        TEXT NOT NULL,        -- which per-item key
  key_version   INTEGER NOT NULL,
  payload       BLOB NOT NULL,        -- the existing v4 envelope, unchanged
  title_ct      BLOB NOT NULL,        -- title alone, per-item key, AAD includes record_id
  category      TEXT NOT NULL,
  updated_at    INTEGER NOT NULL,
  deleted_at    INTEGER               -- soft delete, trash
);
CREATE INDEX idx_vault_items_updated ON vault_items(updated_at);
CREATE INDEX idx_vault_items_host    ON vault_hosts(host);
```

`title_ct` is a deliberate small duplication: search decrypts only titles
(a few KB total for thousands of items, single-digit milliseconds) instead of
whole items. Nothing human-readable is stored in clear except the category enum
and timestamps, which are already metadata the sync server sees today
(`20260323100000_initial_vault_schema.sql:35-40`). No blind indexes: they leak
more than they buy at this scale.

Host matching for autofill gets its own table (`vault_hosts(record_id, host)`),
populated from the same payload, so `AutofillService` answers a lookup with one
indexed query and one title decrypt.

### 4. `VaultRepository` grows lookup methods

The interface today is collection-shaped (`lib/core/security/vault_repository.dart`:
`fetchSummary`, `fetchItems`, `fetchItemById`, `saveItem`, `deleteItem`). It gains:

- `Future<List<VaultItemSummary>> search({String? query, String? host, int limit})`
- `Future<List<VaultItemSummary>> findByHost(String host)`

`fetchItems()` stays for the dashboard's full view but is no longer the path for
search or autofill. This is a contract change and the only consumer to update is
the composition root.

### 5. Migration is staged, verified, and reversible

The migration runs once, inside one transaction, under the unlock that is already
happening:

1. Read and decrypt the legacy blob.
2. Insert every item into `vault_items` in a single transaction, along with its
   `title_ct` and `vault_hosts` rows.
3. Verify inside the transaction: row count equals the number of decrypted
   items, and for a sample of every record the `record_id` set matches exactly.
4. Write `vault_storage_schema = 1` (the "migrated" marker) **and** leave the
   blob under a renamed key `vault_encrypted_items_legacy_v1`.
5. The legacy blob is deleted only on the next successful unlock **and** only
   when the DB is readable and the marker is present.

If any step fails, the transaction rolls back, the blob is untouched, and the
app keeps working exactly as today. Nothing is destroyed on a first attempt.

Downgrade is refused, not silently degraded: the existing
`vault_item_payload_min_version` mechanism is extended to a storage schema
version. An older build that finds schema 1 refuses to open the vault and says
so, instead of reading a blob that is now stale.

### 6. Rekey and the Keystore envelope keep working

Rekey re-wraps the DEK; it must now also re-derive the DB key and re-key the
database. `sqlcipher` supports `PRAGMA rekey`, which is one statement inside the
same transaction as the DEK re-wrap, so the existing "rekey in progress" flag
keeps its meaning. The biometric envelope (RSA-2048 keystore wrapping a seed that
unwraps the DEK) is unaffected, because the DEK is still the root of both the
item keys and the DB key.

## Consequences

Positive: O(1) write per edit, indexed search, partial reads, room for
attachments, and the foundation autofill needs. The crypto contract and the sync
wire format are untouched.

Negative and accepted:

- **Two native dependencies** on every platform, including the Windows and Linux
  desktop builds. APK size grows. This must be verified per target, not assumed.
- **A second encryption layer** to reason about. Mitigated by the rule that the
  payload envelope is byte-identical to what sync expects, so only one codec
  exists.
- **A one-time migration on someone's real vault.** This is the highest-risk
  change in the project and is treated as risk item 1: single owner, prior
  design (this document), and the verification plan below.

## Rejected alternatives

- **Shard the blob into N buckets.** Cheap, keeps every other problem, and turns
  atomicity into a distributed problem. Rejected.
- **Hive / a key-value store with a cipher.** Same whole-box rewrite per write.
  It is the current design wearing a hat. Rejected.
- **Isar.** Fits the shape, but its maintenance and encryption story are not
  something to bet a password manager on. Rejected.
- **Drop per-item encryption and rely on SQLCipher alone.** Simpler, but it
  breaks the sync payload format, the AAD binding, and ADR-001. Rejected.
- **Store everything decrypted and encrypt only the file.** Loses the row-level
  binding that stops a ciphertext from being swapped between records. Rejected.

## Verification plan

Not done until all of these pass:

1. **Migration unit tests**, against a synthetic blob: happy path, blob that
   fails to decrypt, transaction interrupted mid-insert (must roll back and leave
   the blob), re-run on an already-migrated vault (must be a no-op), legacy blob
   still present after a failed migration.
2. **Round-trip test**: every field of every item survives migration, compared
   against `VaultItem.toJson` before and after.
3. **Write amplification gate**: bytes written to the store for a single
   `saveItem` must be measurable and must not grow with the vault size. Today it
   is O(N); after, it must be O(1). This is the number that justifies the whole
   change.
4. **Performance gate** with 5,000 synthetic items: open < 300 ms, search < 50 ms,
   single save < 20 ms.
5. **Real vault test on device**: export an encrypted `.vaulta` backup first,
   migrate, restart, unlock, verify item count and a sample of secrets, and
   confirm the backup still restores.
6. **Existing suite green**: 445 tests, plus the new ones.
7. **Desktop builds compile** for Windows and Linux with SQLCipher present.

## Out of scope

Attachments, autofill itself, TOTP, folders, and any change to the sync wire
format or the crypto contract. Autofill is the next wave and depends on this one,
but is not part of it.
