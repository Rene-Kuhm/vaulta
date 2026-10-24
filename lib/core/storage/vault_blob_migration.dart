import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../features/vault/domain/vault_item.dart';
import '../security/local_encrypted_vault_repository.dart';
import '../security/secure_storage_service.dart';
import '../security/vault_crypto_service.dart';
import '../security/vault_session.dart';
import 'vault_database_opener.dart';
import 'vault_host.dart';
import 'vault_schema.dart';

/// How a migration attempt ended.
enum VaultMigrationOutcome {
  /// The database was already migrated by a previous run.
  alreadyMigrated,

  /// There was no legacy blob, so there was nothing to move.
  nothingToMigrate,

  /// Every item was written and the legacy blob was set aside.
  migrated,

  /// Nothing was written and the legacy blob is untouched.
  failed,
}

/// Result of [VaultBlobMigration.run].
class VaultMigrationResult {
  /// Builds a result.
  const VaultMigrationResult({
    required this.outcome,
    this.itemCount = 0,
    this.error,
  });

  /// What happened.
  final VaultMigrationOutcome outcome;

  /// How many items ended up in the database.
  final int itemCount;

  /// The failure, when [outcome] is [VaultMigrationOutcome.failed].
  final Object? error;

  /// `true` when the vault is safe to use on the new storage.
  bool get usable =>
      outcome == VaultMigrationOutcome.migrated ||
      outcome == VaultMigrationOutcome.alreadyMigrated ||
      outcome == VaultMigrationOutcome.nothingToMigrate;
}

/// One-time move from the single encrypted blob to the SQLite database (ADR-007).
///
/// The contract this class exists to honour: **a failed migration destroys
/// nothing**. The legacy blob is only set aside after the transaction committed
/// and was verified, and every failure path returns with the blob exactly where
/// it was, so the app can keep running on the old storage.
///
/// The caller owns the database and its key; this class never opens or keys a
/// database itself.
class VaultBlobMigration {
  /// Builds the migration.
  VaultBlobMigration({
    required SecureStorageService storage,
    required VaultCryptoService cryptoService,
    required Database db,
    required VaultSession? Function() readSession,
    required int Function() readMinimumVersion,
    DateTime Function()? now,
  }) : _storage = storage,
       _cryptoService = cryptoService,
       _db = db,
       _readSession = readSession,
       _readMinimumVersion = readMinimumVersion,
       _now = now ?? DateTime.now;

  /// Secure-storage key the legacy blob is moved to once the migration is done.
  ///
  /// It is kept, not deleted: it is the rollback for one release, and deleting
  /// the last copy of a vault on the strength of a single successful run is not
  /// a trade worth making.
  static const String legacyBlobKey = 'vault_encrypted_items_legacy_v1';

  final SecureStorageService _storage;
  final VaultCryptoService _cryptoService;
  final Database _db;
  final VaultSession? Function() _readSession;
  final int Function() _readMinimumVersion;
  final DateTime Function() _now;

  /// Runs the migration. Safe to call on every unlock: after the first success it
  /// is a no-op.
  Future<VaultMigrationResult> run() async {
    if (readVaultSchemaVersion(_db) != vaultStorageSchemaVersion) {
      throw StateError(
        'ensureVaultSchema must run before migrating; the database has no '
        'schema this build understands',
      );
    }
    if (_readMeta(metaMigratedFromBlobAtKey) != null) {
      return const VaultMigrationResult(
        outcome: VaultMigrationOutcome.alreadyMigrated,
      );
    }

    final raw = await _storage.read(
      LocalEncryptedVaultRepository.encryptedVaultItemsKey,
    );
    if (raw == null || raw.isEmpty) {
      // Nothing to lose: record it so later unlocks do not look again.
      _writeMeta(metaMigratedFromBlobAtKey, _now().toUtc().toIso8601String());
      return const VaultMigrationResult(
        outcome: VaultMigrationOutcome.nothingToMigrate,
      );
    }

    final session = _readSession();
    if (session == null) {
      throw StateError(
        'Cannot migrate an encrypted vault while it is locked. Unlock first.',
      );
    }

    final List<VaultItem> items;
    try {
      items = await _decryptBlob(raw, session);
    } catch (error) {
      // The blob stays where it is; the app keeps working on the old storage.
      return VaultMigrationResult(
        outcome: VaultMigrationOutcome.failed,
        error: error,
      );
    }

    final minimumVersion = _readMinimumVersion();
    final envelopes = (jsonDecode(raw) as List<dynamic>).cast<String>();

    _db.execute('BEGIN IMMEDIATE');
    try {
      for (var i = 0; i < items.length; i++) {
        await _writeItem(
          item: items[i],
          envelope: envelopes[i],
          session: session,
          keyVersion: minimumVersion,
        );
      }
      _verify(items.length, items.map((item) => item.id).toSet());
      _db.execute(
        'INSERT INTO vault_meta (key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [
          metaMigratedFromBlobAtKey,
          _now().toUtc().toIso8601String(),
        ],
      );
      _db.execute('COMMIT');
    } catch (error) {
      _db.execute('ROLLBACK');
      return VaultMigrationResult(
        outcome: VaultMigrationOutcome.failed,
        error: error,
      );
    }

    // Only now: the data is committed and verified. Move the blob aside so the
    // old code path cannot read a stale copy, but keep it as the rollback.
    await _storage.save(legacyBlobKey, raw);
    await _storage.delete(
      LocalEncryptedVaultRepository.encryptedVaultItemsKey,
    );

    return VaultMigrationResult(
      outcome: VaultMigrationOutcome.migrated,
      itemCount: items.length,
    );
  }

  /// Decrypts every envelope in the blob, preserving order so envelope `i`
  /// matches item `i`.
  Future<List<VaultItem>> _decryptBlob(String raw, VaultSession session) async {
    final envelopes = (jsonDecode(raw) as List<dynamic>).cast<String>();
    final minimumVersion = _readMinimumVersion();
    final items = <VaultItem>[];

    for (final envelope in envelopes) {
      final header = _cryptoService.inspect(envelope);
      final plaintext = await _cryptoService.decrypt(
        ciphertext: envelope,
        secretKey: session,
        expectedKeyId: session.keyId,
        recordId: header.recordId,
        minimumVersion: minimumVersion,
      );
      final item = VaultItem.fromJson(
        jsonDecode(plaintext) as Map<String, dynamic>,
      );
      if (header.recordId != null && item.id != header.recordId) {
        throw StateError(
          'Decrypted item ${item.id} does not match its bound record '
          '${header.recordId}',
        );
      }
      items.add(item);
    }
    return items;
  }

  Future<void> _writeItem({
    required VaultItem item,
    required String envelope,
    required VaultSession session,
    required int keyVersion,
  }) async {
    final title = await _cryptoService.encrypt(
      plaintext: jsonEncode(<String, String>{'title': item.title}),
      secretKey: session,
      keyId: session.keyId,
      recordId: item.id,
    );

    _db.execute(vaultItemsUpsertSql, [
      item.id,
      session.keyId,
      keyVersion,
      envelope,
      title,
      item.category.name,
      (item.updatedAt ?? _now()).millisecondsSinceEpoch,
    ]);

    _db.execute(vaultHostsDeleteSql, [item.id]);
    final host = vaultHostOfWebsite(item.website);
    if (host != null) {
      _db.execute(vaultHostsInsertSql, [item.id, host]);
    }
  }

  /// Checks, inside the transaction, that the database holds exactly the items
  /// the blob held. A count alone would miss a wrong row.
  void _verify(int expectedCount, Set<String> expectedIds) {
    final count = _db.select(
      'SELECT COUNT(*) c FROM vault_items WHERE deleted_at IS NULL',
    ).first['c'] as int;
    if (count != expectedCount) {
      throw StateError(
        'migration wrote $count rows, the blob had $expectedCount items',
      );
    }
    final ids = _db
        .select('SELECT record_id FROM vault_items WHERE deleted_at IS NULL')
        .map((row) => row['record_id'] as String)
        .toSet();
    if (ids.length != expectedIds.length || !ids.containsAll(expectedIds)) {
      throw StateError('migration row ids do not match the blob record ids');
    }
  }

  String? _readMeta(String key) {
    final rows = _db.select('SELECT value FROM vault_meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void _writeMeta(String key, String value) {
    _db.execute(
      'INSERT INTO vault_meta (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }
}
