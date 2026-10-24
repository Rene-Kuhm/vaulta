import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sqlite3/sqlite3.dart';

import 'vault_schema.dart';

/// Pragma order that every connection must apply, verified in the ADR-007 spike.
///
/// Changing this order breaks the vault in two different ways, both measured:
/// - `journal_mode` before the key fails with `file is not a database`, because
///   the header is written before a cipher context exists;
/// - `cipher` after `key` also fails, which is the good direction: the mistake is
///   loud instead of looking like an empty vault.
///
/// The scheme is declared even though it is the bundled default: a future
/// `sqlite3mc` release may change that default, and then an undeclared scheme
/// would stop opening databases written by this build.
const String vaultCipherScheme = 'chacha20'; // ChaCha20-Poly1305 (AEAD)

/// SQLite3 Multiple Ciphers schemes this build accepts, measured in the spike.
///
/// `chacha20` and `ascon128` are AEAD. `aes128cbc` and `aes256cbc` are
/// encrypt-then-MAC, which is why they are not the chosen default. There is no
/// `aes256gcm` in this build.
const Set<String> availableCipherSchemes = <String>{
  'chacha20',
  'ascon128',
  'aes128cbc',
  'aes256cbc',
};

/// Derives the database key from the vault DEK.
///
/// The DEK already only exists in memory after unlock (ADR-001), so this adds no
/// new secret to protect. [salt] is per database and lives in secure storage,
/// never inside the encrypted database: reading the salt would otherwise require
/// the key it is used to derive.
///
/// [info] keeps this key separate from the per-item and per-backup derivations,
/// so a leaked database key cannot be replayed as anything else.
Future<SecretKey> deriveVaultDatabaseKey({
  required SecretKey dek,
  required List<int> salt,
  List<int> info = const <int>[],
}) {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  return hkdf.deriveKey(
    secretKey: dek,
    nonce: salt,
    info: info.isEmpty ? utf8.encode('vaulta:db:v1') : info,
  );
}

/// Opens the encrypted vault database at [path] and applies the pragma order.
///
/// The caller owns [key]: derive it with [deriveVaultDatabaseKey]. Passing it as
/// bytes keeps this function free of key storage policy.
Database openVaultDatabase({
  required String path,
  required Uint8List key,
  bool createIfMissing = true,
}) {
  if (key.length != 32) {
    throw ArgumentError.value(key.length, 'key.length', 'expected 32 bytes');
  }

  final db = createIfMissing
      ? sqlite3.open(path)
      : sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    _applyConnectionPragmas(db, key);
    return db;
  } catch (_) {
    db.close();
    rethrow;
  }
}

/// Applies cipher, key and the rest of the pragmas to an open connection.
///
/// The key is passed as a bound parameter with `hex()`, so it never appears in a
/// SQL string that could end up in a log or an exception message.
void _applyConnectionPragmas(Database db, Uint8List key) {
  db.execute('PRAGMA cipher = $vaultCipherScheme;');
  db.execute("PRAGMA key = \"x'${_hex(key)}'\";");
  db.execute('PRAGMA journal_mode = WAL;');
  db.execute('PRAGMA synchronous = NORMAL;');
  db.execute('PRAGMA foreign_keys = ON;');
  db.execute('PRAGMA busy_timeout = 5000;');
}

String _hex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final b in bytes) {
    buffer.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Creates the schema if it is not there yet and records its version.
///
/// Idempotent: calling it on an initialized database changes nothing. A database
/// stamped with a schema version this build does not know is rejected rather than
/// guessed at.
void ensureVaultSchema(Database db) {
  final current = readVaultSchemaVersion(db);
  if (current == vaultStorageSchemaVersion) return;
  if (current != null) {
    throw StateError(
      'vault database schema is v$current, this build understands '
      'v$vaultStorageSchemaVersion; refusing to open',
    );
  }
  db.execute('BEGIN IMMEDIATE');
  try {
    for (final statement in vaultSchemaStatements) {
      db.execute(statement);
    }
    db.execute(
      'INSERT INTO vault_meta (key, value) VALUES (?, ?)',
      [metaSchemaVersionKey, '$vaultStorageSchemaVersion'],
    );
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

/// Reads the recorded schema version, or `null` when the database is empty.
int? readVaultSchemaVersion(Database db) {
  final hasTable = db.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'vault_meta'",
  );
  if (hasTable.isEmpty) return null;
  final rows = db.select(
    'SELECT value FROM vault_meta WHERE key = ?',
    [metaSchemaVersionKey],
  );
  if (rows.isEmpty) return null;
  return int.tryParse(rows.first['value'] as String);
}
