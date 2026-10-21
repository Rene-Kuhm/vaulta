import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/core/security/local_encrypted_vault_repository.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/vault_session.dart';
import 'package:gestor_contrasenas/core/storage/lazy_sqlite_vault_repository.dart';
import 'package:gestor_contrasenas/core/storage/vault_blob_migration.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';

class _MemoryStorage implements SecureStorageService {
  final Map<String, String> values = {};
  @override
  Future<void> save(String key, String value) async => values[key] = value;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Envelope fake that also reports a caller-controlled version, so the payload
/// upgrade can be exercised without real AES.
class _FakeCrypto implements VaultCryptoService {
  int version = 4;

  @override
  Future<String> encrypt({
    required String plaintext,
    required Object secretKey,
    required String keyId,
    required String recordId,
  }) async => jsonEncode({
    'rid': recordId,
    'kid': keyId,
    'v': version,
    'pt': plaintext,
  });

  @override
  Future<String> decrypt({
    required String ciphertext,
    required Object secretKey,
    required String expectedKeyId,
    required String? recordId,
    int minimumVersion = 1,
  }) async {
    final envelope = jsonDecode(ciphertext) as Map<String, dynamic>;
    if ((envelope['v'] as int) < minimumVersion) {
      throw StateError('downgrade rejected');
    }
    if (recordId != null && envelope['rid'] != recordId) {
      throw StateError('record mismatch');
    }
    return envelope['pt'] as String;
  }

  @override
  VaultItemPayloadHeader inspect(String ciphertext) {
    final envelope = jsonDecode(ciphertext) as Map<String, dynamic>;
    return VaultItemPayloadHeader(
      version: envelope['v'] as int,
      keyId: envelope['kid'] as String?,
      recordId: envelope['rid'] as String?,
      itemKeyVersion: 1,
    );
  }
}

VaultItem item(String id) => VaultItem(
  id: id,
  title: 'Titulo $id',
  username: 'rene',
  secret: 'clave-$id',
  category: VaultCategory.work,
  strengthScore: 90,
  lastUpdatedLabel: 'hoy',
  website: 'https://www.example.com/x',
  updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
);

VaultSession session(String keyId, int seed) => VaultSession(
  keyId: keyId,
  secretKey: SecretKey(List<int>.generate(32, (i) => seed + i)),
);

void main() {
  late Directory dir;
  late _MemoryStorage storage;
  late _FakeCrypto crypto;
  late int pathCalls;
  late VaultSession? active;

  LazySqliteVaultRepository build() => LazySqliteVaultRepository(
    storage: storage,
    cryptoService: crypto,
    readSession: () => active,
    readMinimumVersion: () => 3,
    databasePath: () async {
      pathCalls++;
      return '${dir.path}/vault.db';
    },
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('lazy_repo');
    storage = _MemoryStorage();
    crypto = _FakeCrypto();
    pathCalls = 0;
    active = session('key-1', 1);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('a locked vault fails closed and creates no database', () async {
    active = null;
    final repo = build();
    await expectLater(repo.fetchItems(), throwsA(isA<StateError>()));
    expect(File('${dir.path}/vault.db').existsSync(), isFalse);
  });

  test('opens once and reuses the connection across operations', () async {
    final repo = build();
    await repo.saveItem(item('r1'));
    await repo.fetchItems();
    await repo.fetchItemById('r1');

    expect(pathCalls, 1, reason: 'the database must be opened once, not per call');
    repo.close();
  });

  test('the first use runs the migration from the legacy blob', () async {
    final env = await crypto.encrypt(
      plaintext: jsonEncode(item('r1').toJson()),
      secretKey: active!,
      keyId: 'key-1',
      recordId: 'r1',
    );
    storage.values[LocalEncryptedVaultRepository.encryptedVaultItemsKey] =
        jsonEncode([env]);

    final repo = build();
    final items = await repo.fetchItems();

    expect(items, hasLength(1));
    expect(items.first.id, 'r1');
    expect(
      storage.values[VaultBlobMigration.legacyBlobKey],
      isNotNull,
      reason: 'the legacy blob is kept as the rollback',
    );
    repo.close();
  });

  test('rekey changes the file key so the old session can no longer read it', () async {
    final oldSession = active!;
    final newSession = session('key-1', 99); // same keyId, different DEK

    final repo = build();
    await repo.saveItem(item('r1'));
    expect(await repo.fetchItems(), hasLength(1));

    await repo.rekeyEntries(sourceSession: oldSession, targetSession: newSession);

    // Opening with the new DEK reads the same item.
    active = newSession;
    final reopened = build();
    expect(await reopened.fetchItems(), hasLength(1));
    reopened.close();

    // Opening the re-keyed file with the old DEK must fail, not read garbage.
    active = oldSession;
    final stale = build();
    await expectLater(stale.fetchItems(), throwsA(isA<Exception>()));
    stale.close();
  });

  test('old payload versions are upgraded in place and the upgrade is idempotent', () async {
    // A v2 row cannot be read with the v3 floor.
    crypto.version = 2;
    final repo = build();
    await repo.saveItem(item('r1'));
    await expectLater(
      repo.fetchItems(),
      throwsA(isA<StateError>()),
      reason: 'the floor of 3 must reject a v2 payload',
    );
    repo.close();

    // The upgrade rewrites it as v3, so the same floor now reads it.
    crypto.version = 3;
    final upgrading = build();
    await upgrading.migrateItemsToCurrentVersion();
    expect(await upgrading.fetchItems(), hasLength(1));

    // Idempotent: running it again keeps the row readable and does not duplicate it.
    await upgrading.migrateItemsToCurrentVersion();
    expect(await upgrading.fetchItems(), hasLength(1));
    upgrading.close();
  });
}
