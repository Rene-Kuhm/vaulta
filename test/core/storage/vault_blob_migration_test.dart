import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/core/security/local_encrypted_vault_repository.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/vault_session.dart';
import 'package:gestor_contrasenas/core/storage/vault_blob_migration.dart';
import 'package:gestor_contrasenas/core/storage/vault_database_opener.dart';
import 'package:gestor_contrasenas/core/storage/vault_host.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:sqlite3/sqlite3.dart';

class _MemoryStorage implements SecureStorageService {
  final Map<String, String> values = {};
  @override
  Future<void> save(String key, String value) async => values[key] = value;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Envelope fake: enough structure for the migration to inspect and decrypt, and
/// it records the record id it was asked to bind.
class _FakeCrypto implements VaultCryptoService {
  bool failDecrypt = false;

  @override
  Future<String> encrypt({
    required String plaintext,
    required Object secretKey,
    required String keyId,
    required String recordId,
  }) async => jsonEncode({'rid': recordId, 'kid': keyId, 'pt': plaintext});

  @override
  Future<String> decrypt({
    required String ciphertext,
    required Object secretKey,
    required String expectedKeyId,
    required String? recordId,
    int minimumVersion = 1,
  }) async {
    if (failDecrypt) throw StateError('cannot decrypt');
    final envelope = jsonDecode(ciphertext) as Map<String, dynamic>;
    if (recordId != null && envelope['rid'] != recordId) {
      throw StateError('record mismatch');
    }
    return envelope['pt'] as String;
  }

  @override
  VaultItemPayloadHeader inspect(String ciphertext) {
    final envelope = jsonDecode(ciphertext) as Map<String, dynamic>;
    return VaultItemPayloadHeader(
      version: 4,
      keyId: envelope['kid'] as String?,
      recordId: envelope['rid'] as String?,
      itemKeyVersion: 1,
    );
  }
}

void main() {
  late Directory dir;
  late Database db;
  late _MemoryStorage storage;
  late _FakeCrypto crypto;
  late VaultSession session;

  VaultItem item(String id, {String title = 'Titulo', String? website}) =>
      VaultItem(
        id: id,
        title: title,
        username: 'rene',
        secret: 'clave-$id',
        category: VaultCategory.work,
        strengthScore: 90,
        lastUpdatedLabel: 'hoy',
        website: website,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  Future<void> writeBlob(List<VaultItem> items) async {
    final envelopes = <String>[];
    for (final i in items) {
      envelopes.add(
        await crypto.encrypt(
          plaintext: jsonEncode(i.toJson()),
          secretKey: session,
          keyId: session.keyId,
          recordId: i.id,
        ),
      );
    }
    storage.values[LocalEncryptedVaultRepository.encryptedVaultItemsKey] =
        jsonEncode(envelopes);
  }

  VaultBlobMigration migration({VaultSession? lockedOut}) => VaultBlobMigration(
    storage: storage,
    cryptoService: crypto,
    db: db,
    readSession: () => lockedOut,
    readMinimumVersion: () => 4,
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('migration_test');
    session = VaultSession(
      keyId: 'key-1',
      secretKey: SecretKey(List<int>.generate(32, (i) => i)),
    );
    crypto = _FakeCrypto();
    storage = _MemoryStorage();
    db = openVaultDatabase(
      path: '${dir.path}/vault.db',
      key: Uint8List.fromList(List<int>.generate(32, (i) => 60 + i)),
    );
    ensureVaultSchema(db);
  });

  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  int rowCount() =>
      db.select('SELECT COUNT(*) c FROM vault_items').first['c'] as int;

  test('moves every item and sets the legacy blob aside', () async {
    await writeBlob([item('r1', title: 'Uno'), item('r2', title: 'Dos')]);

    final result = await migration(lockedOut: session).run();

    expect(result.outcome, VaultMigrationOutcome.migrated);
    expect(result.itemCount, 2);
    expect(rowCount(), 2);
    expect(
      storage.values[VaultBlobMigration.legacyBlobKey],
      isNotNull,
      reason: 'the blob must survive as the rollback',
    );
    expect(
      storage.values[LocalEncryptedVaultRepository.encryptedVaultItemsKey],
      isNull,
      reason: 'the live key must be gone so the old path cannot read a stale blob',
    );
  });

  test('a second run is a no-op', () async {
    await writeBlob([item('r1')]);
    await migration(lockedOut: session).run();

    final again = await migration(lockedOut: session).run();
    expect(again.outcome, VaultMigrationOutcome.alreadyMigrated);
    expect(rowCount(), 1);
  });

  test('with no blob there is nothing to migrate and nothing is written', () async {
    final result = await migration(lockedOut: session).run();
    expect(result.outcome, VaultMigrationOutcome.nothingToMigrate);
    expect(rowCount(), 0);
  });

  test('an undecryptable blob leaves everything untouched', () async {
    await writeBlob([item('r1'), item('r2')]);
    crypto.failDecrypt = true;

    final result = await migration(lockedOut: session).run();

    expect(result.outcome, VaultMigrationOutcome.failed);
    expect(rowCount(), 0);
    expect(
      storage.values[LocalEncryptedVaultRepository.encryptedVaultItemsKey],
      isNotNull,
      reason: 'a failed migration must not touch the blob',
    );
    expect(storage.values[VaultBlobMigration.legacyBlobKey], isNull);
  });

  test('an item bound to another record aborts the whole run', () async {
    final envelopes = <String>[
      await crypto.encrypt(
        plaintext: jsonEncode(item('r1').toJson()),
        secretKey: session,
        keyId: 'key-1',
        recordId: 'r1',
      ),
      // declares record r2 but its payload says r3
      await crypto.encrypt(
        plaintext: jsonEncode(item('r3').toJson()),
        secretKey: session,
        keyId: 'key-1',
        recordId: 'r2',
      ),
    ];
    storage.values[LocalEncryptedVaultRepository.encryptedVaultItemsKey] =
        jsonEncode(envelopes);

    final result = await migration(lockedOut: session).run();

    expect(result.outcome, VaultMigrationOutcome.failed);
    expect(rowCount(), 0);
    expect(
      storage.values[LocalEncryptedVaultRepository.encryptedVaultItemsKey],
      isNotNull,
    );
  });

  test('verification failure rolls back instead of keeping a partial vault', () async {
    // Two envelopes carrying the same record id: the upsert collapses them into
    // one row, so the count check has to catch it and undo everything.
    final same = await crypto.encrypt(
      plaintext: jsonEncode(item('r1').toJson()),
      secretKey: session,
      keyId: 'key-1',
      recordId: 'r1',
    );
    storage.values[LocalEncryptedVaultRepository.encryptedVaultItemsKey] =
        jsonEncode([same, same]);

    final result = await migration(lockedOut: session).run();

    expect(result.outcome, VaultMigrationOutcome.failed);
    expect(rowCount(), 0, reason: 'the transaction must have rolled back');
    expect(
      storage.values[LocalEncryptedVaultRepository.encryptedVaultItemsKey],
      isNotNull,
    );
  });

  test('a locked vault refuses to migrate and keeps the blob', () async {
    await writeBlob([item('r1')]);

    await expectLater(
      migration(lockedOut: null).run(),
      throwsA(isA<StateError>()),
    );
    expect(rowCount(), 0);
    expect(
      storage.values[LocalEncryptedVaultRepository.encryptedVaultItemsKey],
      isNotNull,
    );
  });

  test('the migrated item can be read back through the repository layer', () async {
    await writeBlob([item('r1', title: 'Banco', website: 'https://www.banco.example/x')]);
    await migration(lockedOut: session).run();

    final rows = db.select('SELECT record_id, payload FROM vault_items');
    expect(rows, hasLength(1));
    final plaintext = await crypto.decrypt(
      ciphertext: rows.first['payload'] as String,
      secretKey: session,
      expectedKeyId: 'key-1',
      recordId: rows.first['record_id'] as String,
    );
    final restored = VaultItem.fromJson(
      jsonDecode(plaintext) as Map<String, dynamic>,
    );
    expect(restored.title, 'Banco');

    final hosts = db.select('SELECT host FROM vault_hosts');
    expect(hosts.map((r) => r['host']), contains('banco.example'));
    expect(vaultHostOfWebsite('https://www.banco.example/x'), 'banco.example');
  });
}
