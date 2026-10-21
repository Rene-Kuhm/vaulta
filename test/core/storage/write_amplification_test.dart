import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/core/security/local_encrypted_vault_repository.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/vault_session.dart';
import 'package:gestor_contrasenas/core/storage/sqlite_vault_repository.dart';
import 'package:gestor_contrasenas/core/storage/vault_database_opener.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';

/// The number that justifies ADR-007: saving one item in a large vault must not
/// re-encrypt the whole vault.
///
/// The measurement is the count of crypto operations and the number of bytes
/// handed to storage for a single save. It is deterministic on purpose: no
/// timings, no file sizes, nothing that depends on the machine.
class _CountingCrypto implements VaultCryptoService {
  int encrypts = 0;
  int decrypts = 0;

  @override
  Future<String> encrypt({
    required String plaintext,
    required Object secretKey,
    required String keyId,
    required String recordId,
  }) async {
    encrypts++;
    return jsonEncode({'rid': recordId, 'kid': keyId, 'pt': plaintext});
  }

  @override
  Future<String> decrypt({
    required String ciphertext,
    required Object secretKey,
    required String expectedKeyId,
    required String? recordId,
    int minimumVersion = 1,
  }) async {
    decrypts++;
    return (jsonDecode(ciphertext) as Map<String, dynamic>)['pt'] as String;
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

  void reset() {
    encrypts = 0;
    decrypts = 0;
  }
}

class _MemoryStorage implements SecureStorageService {
  final Map<String, String> values = {};
  int bytesWritten = 0;

  @override
  Future<void> save(String key, String value) async {
    bytesWritten += value.length;
    values[key] = value;
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> delete(String key) async => values.remove(key);

  void resetCounters() => bytesWritten = 0;
}

const int vaultSize = 500;

VaultItem item(String id, {String title = 'Titulo'}) => VaultItem(
  id: id,
  title: title,
  username: 'rene',
  secret: 'clave-unica-$id',
  category: VaultCategory.work,
  strengthScore: 90,
  lastUpdatedLabel: 'hoy',
  updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
);

void main() {
  late VaultSession session;
  late _CountingCrypto crypto;

  setUp(() {
    session = VaultSession(
      keyId: 'key-1',
      secretKey: SecretKey(List<int>.generate(32, (i) => i)),
    );
    crypto = _CountingCrypto();
  });

  test('the blob repository re-encrypts the whole vault for one save', () async {
    final storage = _MemoryStorage();

    // Seed a vault of 500 items the way the app stores it: one JSON array.
    final envelopes = <String>[];
    for (var i = 0; i < vaultSize; i++) {
      final i0 = item('r$i', title: 'Item $i');
      envelopes.add(
        await crypto.encrypt(
          plaintext: jsonEncode(i0.toJson()),
          secretKey: session,
          keyId: 'key-1',
          recordId: i0.id,
        ),
      );
    }
    storage.values[LocalEncryptedVaultRepository.encryptedVaultItemsKey] =
        jsonEncode(envelopes);

    final repo = LocalEncryptedVaultRepository(
      storage: storage,
      cryptoService: crypto,
      readSession: () => session,
    );

    crypto.reset();
    storage.resetCounters();
    await repo.saveItem(item('nuevo'));

    // ignore: avoid_print
    print(
      'blob   · un guardado con $vaultSize ítems → ${crypto.encrypts} cifrados, '
      '${storage.bytesWritten} bytes escritos',
    );

    expect(
      crypto.encrypts,
      greaterThanOrEqualTo(vaultSize),
      reason: 'the blob path re-encrypts every item on each save',
    );
  });

  test('the SQLite repository encrypts only the item it saved', () async {
    final dir = Directory.systemTemp.createTempSync('write_amp');
    final db = openVaultDatabase(
      path: '${dir.path}/vault.db',
      key: Uint8List.fromList(List<int>.generate(32, (i) => 70 + i)),
    );
    ensureVaultSchema(db);

    // Seed the same 500 items as rows.
    for (var i = 0; i < vaultSize; i++) {
      final i0 = item('r$i', title: 'Item $i');
      final payload = await crypto.encrypt(
        plaintext: jsonEncode(i0.toJson()),
        secretKey: session,
        keyId: 'key-1',
        recordId: i0.id,
      );
      final title = await crypto.encrypt(
        plaintext: jsonEncode({'title': i0.title}),
        secretKey: session,
        keyId: 'key-1',
        recordId: i0.id,
      );
      db.execute(
        'INSERT INTO vault_items (record_id, key_id, key_version, payload, '
        'title_ct, category, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          i0.id,
          'key-1',
          4,
          payload,
          title,
          i0.category.name,
          1700000000000,
        ],
      );
    }

    final repo = SqliteVaultRepository(
      db: db,
      cryptoService: crypto,
      readSession: () => session,
      readMinimumVersion: () => 4,
    );

    crypto.reset();
    final bytesBefore =
        db.select('SELECT SUM(LENGTH(payload)) b FROM vault_items').first['b']
            as int;
    await repo.saveItem(item('nuevo'));
    final bytesAfter =
        db.select('SELECT SUM(LENGTH(payload)) b FROM vault_items').first['b']
            as int;

    // ignore: avoid_print
    print(
      'sqlite · un guardado con $vaultSize ítems → ${crypto.encrypts} cifrados, '
      '${bytesAfter - bytesBefore} bytes de payload agregados',
    );

    expect(
      crypto.encrypts,
      2,
      reason: 'one envelope for the payload and one for the title, nothing else',
    );
    expect(bytesAfter - bytesBefore, lessThan(500));

    db.close();
    dir.deleteSync(recursive: true);
  });
}
