/// Schema of the encrypted local vault database (ADR-007).
///
/// The DDL is written by hand instead of generated, because every table is
/// `STRICT`: SQLite 3.37+ rejects a value that does not match the declared type
/// instead of coercing it, and for a vault that difference is between a bug and
/// data loss. `drift` generates `CREATE TABLE` without `STRICT`, so the schema is
/// the single source of truth here and queries are built on top of it later.
///
/// Nothing human-readable lives in a clear column: the payload and the title are
/// ciphertext (ADR-001 per-item envelope), and only opaque identifiers, the
/// category enum and timestamps are readable. Those are already metadata the
/// sync server sees today (`20260323100000_initial_vault_schema.sql:35-40`).
library;

/// Version of this schema, stored in `vault_meta` under [metaSchemaVersionKey].
///
/// A build that finds a schema version it does not know refuses to open the
/// vault instead of reading a shape it cannot interpret.
const int vaultStorageSchemaVersion = 1;

/// Meta table key holding [vaultStorageSchemaVersion].
const String metaSchemaVersionKey = 'storage_schema';

/// Meta table key recording that the one-time migration from the legacy blob ran.
const String metaMigratedFromBlobAtKey = 'migrated_from_blob_at';

/// Statements that create the schema. Order matters: `vault_items` before
/// `vault_hosts`, which references it.
const List<String> vaultSchemaStatements = <String>[
  '''
CREATE TABLE vault_items (
  record_id   TEXT PRIMARY KEY,
  key_id      TEXT NOT NULL,
  key_version INTEGER NOT NULL,
  payload     BLOB NOT NULL,
  title_ct    BLOB NOT NULL,
  category    TEXT NOT NULL,
  updated_at  INTEGER NOT NULL,
  deleted_at  INTEGER
) STRICT
''',
  'CREATE INDEX idx_vault_items_updated ON vault_items(updated_at)',
  // Every host an item is offered to. Exists so AutofillService answers a lookup
  // with one indexed query instead of decrypting the vault.
  '''
CREATE TABLE vault_hosts (
  record_id TEXT NOT NULL REFERENCES vault_items(record_id) ON DELETE CASCADE,
  host      TEXT NOT NULL,
  PRIMARY KEY (record_id, host)
) STRICT
''',
  'CREATE INDEX idx_vault_hosts_host ON vault_hosts(host)',
  // Bookkeeping: schema version, migration marker, and the per-database salt the
  // DB key is derived with is NOT stored here on purpose (it would be
  // chicken-and-egg); it lives in secure storage next to the wrapped DEK.
  '''
CREATE TABLE vault_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
) STRICT
''',
];
