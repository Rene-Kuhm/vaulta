# AGENTS.md — `lib/core/storage`

The encrypted SQLite storage: the repository, the schema, the opener with the
cipher, the database salt store, the host index and the blob-to-database
migration. It is the second of the two storage implementations; the default
one is the encrypted blob in `lib/core/security`.

The map of this module: `mise run repo-map --module lib/core/storage`.

## Invariants

- The database file is encrypted at rest. The opener applies the cipher
  pragmas in a fixed order — `cipher`, then `key`, then the rest — and the
  scheme is declared explicitly (`chacha20`, ChaCha20-Poly1305) even though it
  is the bundled default of SQLite3 Multiple Ciphers, so a future release
  that changes the default cannot silently write the vault in the clear.
- The database key never appears in a SQL string: it is passed as a bound
  parameter with `hex()`, so it cannot end up in a log or in an exception
  message.
- The database key is derived from the DEK with HKDF over a 16-byte salt that
  is created once and persisted in the secure storage
  (`vault_db_salt_v1`). The salt is read, never regenerated, or the database
  becomes unreadable.
- The schema holds ciphertext, not plaintext: the item payload stays
  encrypted per item (ADR-0001) and the tables only carry opaque identifiers,
  the search columns and the sync metadata. The schema version is a single
  constant, `vaultStorageSchemaVersion`.
- `vault_hosts` is an index, not a copy: it maps a normalized host to the
  items that use it, so `findByHost` answers without decrypting the vault.
- The repository implements the same `VaultRepository` port as the blob, and
  it is opened lazily: the file is created on first use, not at startup.
- The blob-to-database migration is idempotent and reports what it did
  (`alreadyMigrated`, `nothingToMigrate`, `migrated`, `failed`). A failed
  migration leaves the blob in place.

## How it is tested

- `test/core/storage/sqlite_vault_repository_test.dart` — the repository:
  the items, the summary, the search and the host lookup.
- `test/core/storage/vault_database_opener_test.dart` — the opener: the
  cipher pragmas, the schema and the version.
- `test/core/storage/vault_blob_migration_test.dart` — the migration and its
  outcomes.
- `test/core/storage/lazy_sqlite_vault_repository_test.dart` — the lazy
  opening and the delegation to the real repository.
- `test/core/storage/sqlite_remote_snapshots_test.dart` and
  `test/core/storage/sync_round_trip_test.dart` — the storage side of the
  sync round trip.
- `test/core/storage/write_amplification_test.dart` — how many writes a save
  costs.
- `integration_test/sqlite_storage_migration_test.dart` — the migration on a
  device.

## Do not touch

- The `sqlite3` native-asset hook in `pubspec.yaml`
  (`hooks.user_defines.sqlite3.source = sqlite3mc`). It is what encrypts the
  database file; removing it writes the vault in the clear.
- `vaultCipherScheme` and `availableCipherSchemes`. The scheme is checked
  against the list the spike measured; adding one is a measurement, not a
  guess.
- The pragma order in `_applyConnectionPragmas` (`cipher`, `key`,
  `journal_mode`). The ADR-007 spike measured what breaks otherwise:
  `journal_mode` before the key fails with "file is not a database".
- The database salt (`vault_db_salt_v1`, 16 bytes). Changing it makes every
  existing database unreadable.
- The schema statements and `vaultStorageSchemaVersion` without a migration.
  A schema change needs a new version and a migration path, not an edit.
- The `VAULTA_SQLITE_STORAGE` flag: turning the storage on for a release is
  an owner decision that requires the verification plan in ADR-0007.

## Boundaries

- Depends on: `lib/core/security` — the DEK, the crypto service and the
  ports (`VaultRepository`, `RemoteSnapshotApplier`).
- Depends on: `lib/features/vault/domain` — the item and summary types.
- Never imports: `lib/features/*/presentation` and `lib/app`. `lib/core`
  never imports a screen.
- Never imports: `lib/core/sync` for behavior. Only the sync *ports and value
  types* are imported — `RemoteSnapshotApplier`, `RemoteSnapshotEnvelope` and
  `RemoteVaultBlobChange` — never the sync service or its Supabase
  implementations. The dependency runs the other way: the sync layer plugs
  into the repository through the ports, and the storage implements them.
