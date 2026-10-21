import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../../features/vault/domain/vault_item.dart';
import '../../features/vault/domain/vault_summary.dart';
import '../security/local_encrypted_vault_repository.dart';
import '../security/secure_storage_service.dart';
import '../security/vault_crypto_service.dart';
import '../security/vault_repository.dart';
import '../security/vault_session.dart';
import 'sqlite_vault_repository.dart';
import 'vault_blob_migration.dart';
import 'vault_database_opener.dart';
import 'vault_database_salt_store.dart';

/// [VaultRepository] that opens the encrypted database on first use.
///
/// The vault is unlocked after bootstrap, so the database key does not exist when
/// the composition root wires its dependencies. This class defers opening until
/// the first operation, derives the key from the live session, and runs the
/// one-time migration from the legacy blob at that moment.
///
/// It also owns the two hooks `VaultSecurityController` needs but the database
/// does not provide by itself: re-keying (the file is encrypted with a key derived
/// from the DEK, so changing the master password must re-key the file) and
/// upgrading old payload versions in place.
///
/// Every operation re-reads the session. A locked vault therefore fails closed
/// with a clear error instead of using a key that should no longer be in memory.
class LazySqliteVaultRepository implements VaultRepository {
  /// Builds the repository. [databasePath] is resolved lazily so tests can point
  /// it at a temporary directory without touching platform channels.
  LazySqliteVaultRepository({
    required SecureStorageService storage,
    required VaultCryptoService cryptoService,
    required VaultSession? Function() readSession,
    required int Function() readMinimumVersion,
    required Future<String> Function() databasePath,
    VaultDatabaseSaltStore? saltStore,
    DateTime Function()? now,
  }) : _storage = storage,
       _cryptoService = cryptoService,
       _readSession = readSession,
       _readMinimumVersion = readMinimumVersion,
       _databasePath = databasePath,
       _saltStore =
           saltStore ?? VaultDatabaseSaltStore(storage: storage),
       _now = now ?? DateTime.now;

  final SecureStorageService _storage;
  final VaultCryptoService _cryptoService;
  final VaultSession? Function() _readSession;
  final int Function() _readMinimumVersion;
  final Future<String> Function() _databasePath;
  final VaultDatabaseSaltStore _saltStore;
  final DateTime Function() _now;

  Database? _db;
  String? _keyId;
  SqliteVaultRepository? _inner;

  /// Closes the open database, if any. Safe to call when nothing is open.
  void close() {
    _db?.close();
    _db = null;
    _keyId = null;
    _inner = null;
  }

  @override
  Future<List<VaultItem>> fetchItems() async =>
      (await _repository()).fetchItems();

  @override
  Future<VaultItem?> fetchItemById(String id) async =>
      (await _repository()).fetchItemById(id);

  @override
  Future<VaultSummary> fetchSummary() async =>
      (await _repository()).fetchSummary();

  @override
  Future<VaultItem> saveItem(VaultItem item) async =>
      (await _repository()).saveItem(item);

  @override
  Future<void> deleteItem(String id) async =>
      (await _repository()).deleteItem(id);

  /// Items whose title matches [query]. Delegates to the database repository,
  /// which decrypts only title envelopes.
  Future<List<VaultItem>> search(String query, {int limit = 50}) async =>
      (await _repository()).search(query, limit: limit);

  /// Items indexed for [host], used by autofill. One indexed query.
  Future<List<VaultItem>> findByHost(String host) async =>
      (await _repository()).findByHost(host);

  /// Re-encrypts the database file under the new DEK.
  ///
  /// The file key is derived from the DEK, so a master-password change has to
  /// re-key the file as well as re-wrap the DEK. The salt does not change: the new
  /// key is HKDF over the new session's DEK with the same salt.
  Future<void> rekeyEntries({
    required VaultSession sourceSession,
    required VaultSession targetSession,
  }) async {
    final salt = await _saltStore.readOrCreate();
    final targetKey = Uint8List.fromList(
      await (await deriveVaultDatabaseKey(
        dek: targetSession.secretKey,
        salt: salt,
      )).extractBytes(),
    );

    // Open with the key the file is currently encrypted with, then re-key in
    // place. A single statement, so an interrupted rekey leaves the file under the
    // old key rather than half under each.
    final db = await _openWith(sourceSession, salt: salt);
    try {
      db.execute('PRAGMA rekey = "x\'${_hex(targetKey)}\'";');
    } finally {
      close();
    }
  }

  /// Upgrades rows whose payload envelope is older than the version this build
  /// writes. Idempotent, so the controller can run it after every unlock.
  Future<void> migrateItemsToCurrentVersion() async {
    await _repository(); // ensures the database is open and migrated
    final db = _db!;
    final rows = db.select('SELECT record_id, payload FROM vault_items');
    final session = _readSession();
    if (session == null) return;

    const target = LocalEncryptedVaultRepository.currentItemPayloadVersion;
    for (final row in rows) {
      final recordId = row['record_id'] as String;
      final payload = row['payload'] as String;
      final header = _cryptoService.inspect(payload);
      if (header.version >= target) continue;

      // Old payloads may predate the record binding, so the floor is 1 here: the
      // point is to read them once and rewrite them bound.
      final plaintext = await _cryptoService.decrypt(
        ciphertext: payload,
        secretKey: session,
        expectedKeyId: session.keyId,
        recordId: header.recordId,
        minimumVersion: 1,
      );
      final upgraded = await _cryptoService.encrypt(
        plaintext: plaintext,
        secretKey: session,
        keyId: session.keyId,
        recordId: recordId,
      );
      db.execute('UPDATE vault_items SET payload = ? WHERE record_id = ?', [
        upgraded,
        recordId,
      ]);
    }
  }

  Future<SqliteVaultRepository> _repository() async {
    final session = _readSession();
    if (session == null) {
      // Fail closed: never keep a key in memory for a locked vault.
      close();
      throw StateError(
        'Vault encryption key unavailable. Unlock with the master password first.',
      );
    }
    if (_inner != null && _keyId == session.keyId) return _inner!;
    close();

    final salt = await _saltStore.readOrCreate();
    final db = await _openWith(session, salt: salt);
    ensureVaultSchema(db);

    final migration = VaultBlobMigration(
      storage: _storage,
      cryptoService: _cryptoService,
      db: db,
      readSession: _readSession,
      readMinimumVersion: _readMinimumVersion,
      now: _now,
    );
    final result = await migration.run();
    if (!result.usable) {
      // A failed migration must not silently fall back to an empty database that
      // the user would read as "my vault is gone".
      close();
      throw StateError(
        'Vault storage migration failed and was rolled back: ${result.error}',
      );
    }

    _keyId = session.keyId;
    _db = db;
    _inner = SqliteVaultRepository(
      db: db,
      cryptoService: _cryptoService,
      readSession: _readSession,
      readMinimumVersion: _readMinimumVersion,
    );
    return _inner!;
  }

  Future<Database> _openWith(
    VaultSession session, {
    required List<int> salt,
  }) async {
    final key = Uint8List.fromList(
      await (await deriveVaultDatabaseKey(
        dek: session.secretKey,
        salt: salt,
      )).extractBytes(),
    );
    final path = await _databasePath();
    return openVaultDatabase(path: path, key: key);
  }

  String _hex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
