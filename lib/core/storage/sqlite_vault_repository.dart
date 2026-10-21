import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../features/vault/domain/vault_item.dart';
import '../../features/vault/domain/vault_summary.dart';
import '../security/vault_crypto_service.dart';
import '../security/vault_repository.dart';
import '../security/vault_session.dart';
import 'vault_host.dart';
import 'vault_schema.dart';

/// SQLite-backed [VaultRepository] (ADR-007).
///
/// Not wired: no production path constructs this yet, and the composition root
/// still uses the encrypted blob. It exists so the migration (task C) and the
/// swap (task D) can be built against a real implementation.
///
/// Differences from `LocalEncryptedVaultRepository` that are intentional:
/// - a save touches one row, not the whole vault, so write cost does not grow
///   with the number of items;
/// - `deleteItem` is a soft delete (`deleted_at`), so a mistake in the UI no
///   longer destroys the secret;
/// - `fetchItemById`, `search` and `findByHost` no longer decrypt everything.
///
/// The crypto contract is unchanged: every payload is the ADR-001 v4 envelope
/// bound to its `record_id`, produced by the same [VaultCryptoService].
class SqliteVaultRepository implements VaultRepository {
  /// Builds the repository over an already-opened, already-keyed [db].
  ///
  /// [readSession] is called on every operation rather than captured, so locking
  /// the app drops the key for the repository too. [readMinimumVersion] is the
  /// vault's downgrade floor, passed straight to the crypto service.
  SqliteVaultRepository({
    required Database db,
    required VaultCryptoService cryptoService,
    required VaultSession? Function() readSession,
    required int Function() readMinimumVersion,
  }) : _db = db,
       _cryptoService = cryptoService,
       _readSession = readSession,
       _readMinimumVersion = readMinimumVersion;

  final Database _db;
  final VaultCryptoService _cryptoService;
  final VaultSession? Function() _readSession;
  final int Function() _readMinimumVersion;

  /// Marker written into the title envelope so a title ciphertext cannot be
  /// swapped into the payload column and silently decrypt as an item.
  static const String _titleKind = 'title';

  @override
  Future<VaultSummary> fetchSummary() async {
    final items = await fetchItems();
    final weakItems = items.where((item) => item.strengthScore < 80).length;
    final reusedItems = _countReusedSecrets(items);
    final averageScore = items.isEmpty
        ? 0
        : items.fold<int>(0, (sum, item) => sum + item.strengthScore) ~/
              items.length;

    return VaultSummary(
      totalItems: items.length,
      weakItems: weakItems,
      reusedItems: reusedItems,
      securityScore: averageScore,
      connectedDevices: 1,
      syncEnabled: false,
    );
  }

  @override
  Future<List<VaultItem>> fetchItems() async {
    final rows = _db.select(
      'SELECT record_id, payload FROM vault_items '
      'WHERE deleted_at IS NULL ORDER BY updated_at DESC',
    );
    return _decryptRows(rows);
  }

  @override
  Future<VaultItem?> fetchItemById(String id) async {
    final rows = _db.select(
      'SELECT record_id, payload FROM vault_items '
      'WHERE record_id = ? AND deleted_at IS NULL',
      [id],
    );
    if (rows.isEmpty) return null;
    final items = await _decryptRows(rows);
    return items.isEmpty ? null : items.first;
  }

  @override
  Future<VaultItem> saveItem(VaultItem item) async {
    final session = _requireSession();
    final updatedAt = item.updatedAt ?? DateTime.now();

    final payload = await _cryptoService.encrypt(
      plaintext: jsonEncode(item.toJson()),
      secretKey: session,
      keyId: session.keyId,
      recordId: item.id,
    );
    final title = await _cryptoService.encrypt(
      plaintext: jsonEncode(<String, String>{
        _titleKind: item.title,
      }),
      secretKey: session,
      keyId: session.keyId,
      recordId: item.id,
    );

    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute(vaultItemsUpsertSql, [
        item.id,
        session.keyId,
        _readMinimumVersion(),
        payload,
        title,
        item.category.name,
        updatedAt.millisecondsSinceEpoch,
      ]);
      _db.execute(vaultHostsDeleteSql, [item.id]);
      final host = vaultHostOfWebsite(item.website);
      if (host != null) {
        _db.execute(vaultHostsInsertSql, [item.id, host]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return item;
  }

  @override
  Future<void> deleteItem(String id) async {
    // Soft delete: the row and its ciphertext stay, the UI stops seeing it. A
    // hard delete is a purge operation and belongs behind its own confirmation.
    _db.execute(
      'UPDATE vault_items SET deleted_at = ? WHERE record_id = ?',
      [DateTime.now().millisecondsSinceEpoch, id],
    );
    _db.execute('DELETE FROM vault_hosts WHERE record_id = ?', [id]);
  }

  /// Items whose title contains [query], case-insensitive, newest first.
  ///
  /// Decrypts only the title envelope, not the whole item: at a few thousand
  /// items that is single-digit milliseconds, while decrypting every payload
  /// was the cost this migration exists to remove.
  Future<List<VaultItem>> search(String query, {int limit = 50}) async {
    final needle = query.trim().toLowerCase();
    final rows = _db.select(
      'SELECT record_id, title_ct FROM vault_items '
      'WHERE deleted_at IS NULL ORDER BY updated_at DESC',
    );
    final matches = <String>[];
    for (final row in rows) {
      final title = await _decryptTitle(
        ciphertext: row['title_ct'] as String,
        recordId: row['record_id'] as String,
      );
      if (needle.isEmpty || title.toLowerCase().contains(needle)) {
        matches.add(row['record_id'] as String);
        if (matches.length >= limit) break;
      }
    }
    return _itemsByIds(matches);
  }

  /// Items offered to [host], for the future AutofillService. One indexed query,
  /// no scan.
  Future<List<VaultItem>> findByHost(String host) async {
    final rows = _db.select(
      'SELECT h.record_id FROM vault_hosts h '
      'JOIN vault_items i ON i.record_id = h.record_id '
      'WHERE h.host = ? AND i.deleted_at IS NULL '
      'ORDER BY i.updated_at DESC',
      [host.toLowerCase()],
    );
    return _itemsByIds([for (final row in rows) row['record_id'] as String]);
  }

  VaultSession _requireSession() {
    final session = _readSession();
    if (session == null) {
      throw StateError(
        'Vault encryption key unavailable. Unlock with the master password first.',
      );
    }
    return session;
  }

  Future<List<VaultItem>> _decryptRows(List<Row> rows) async {
    final session = _requireSession();
    final minimumVersion = _readMinimumVersion();
    final items = <VaultItem>[];
    for (final row in rows) {
      final recordId = row['record_id'] as String;
      final plaintext = await _cryptoService.decrypt(
        ciphertext: row['payload'] as String,
        secretKey: session,
        expectedKeyId: session.keyId,
        recordId: recordId,
        minimumVersion: minimumVersion,
      );
      final item = VaultItem.fromJson(
        jsonDecode(plaintext) as Map<String, dynamic>,
      );
      if (item.id != recordId) {
        throw StateError(
          'Decrypted item id ${item.id} does not match its bound record id '
          '$recordId',
        );
      }
      items.add(item);
    }
    return items;
  }

  Future<String> _decryptTitle({
    required String ciphertext,
    required String recordId,
  }) async {
    final session = _requireSession();
    final plaintext = await _cryptoService.decrypt(
      ciphertext: ciphertext,
      secretKey: session,
      expectedKeyId: session.keyId,
      recordId: recordId,
      minimumVersion: _readMinimumVersion(),
    );
    final decoded = jsonDecode(plaintext);
    if (decoded is! Map<String, dynamic> || decoded[_titleKind] is! String) {
      throw StateError('Title envelope for $recordId is not a title payload');
    }
    return decoded[_titleKind] as String;
  }

  Future<List<VaultItem>> _itemsByIds(List<String> ids) async {
    if (ids.isEmpty) return <VaultItem>[];
    final placeholders = List<String>.filled(ids.length, '?').join(',');
    final rows = _db.select(
      'SELECT record_id, payload FROM vault_items '
      'WHERE record_id IN ($placeholders) AND deleted_at IS NULL',
      ids,
    );
    final byId = <String, VaultItem>{
      for (final item in await _decryptRows(rows)) item.id: item,
    };
    return [for (final id in ids) if (byId[id] != null) byId[id]!];
  }

  int _countReusedSecrets(List<VaultItem> items) {
    final counts = <String, int>{};
    for (final item in items) {
      final secret = item.secret.trim();
      if (secret.isEmpty) continue;
      counts[secret] = (counts[secret] ?? 0) + 1;
    }
    return counts.values.where((count) => count > 1).fold<int>(
      0,
      (sum, count) => sum + count,
    );
  }
}
