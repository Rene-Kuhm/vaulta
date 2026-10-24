import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/core/security/vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/vault_session.dart';
import 'package:gestor_contrasenas/core/storage/sqlite_vault_repository.dart';
import 'package:gestor_contrasenas/core/storage/vault_database_opener.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:sqlite3/sqlite3.dart';

/// Records the associated data it is asked to bind, then round-trips the
/// plaintext inside a JSON envelope. The repository is the unit under test here,
/// so the real AES-GCM is not what this file needs to prove.
class _FakeCrypto implements VaultCryptoService {
  final List<({String recordId, String keyId})> encryptCalls = [];
  String? lastMinimumVersionSeen;

  @override
  Future<String> encrypt({
    required String plaintext,
    required Object secretKey,
    required String keyId,
    required String recordId,
  }) async {
    encryptCalls.add((recordId: recordId, keyId: keyId));
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
    lastMinimumVersionSeen = '$minimumVersion';
    final envelope = jsonDecode(ciphertext) as Map<String, dynamic>;
    if (envelope['kid'] != expectedKeyId) {
      throw StateError('keyId mismatch');
    }
    if (recordId != null && envelope['rid'] != recordId) {
      throw StateError('recordId mismatch: the payload is bound elsewhere');
    }
    return envelope['pt'] as String;
  }

  @override
  VaultItemPayloadHeader inspect(String ciphertext) =>
      throw UnimplementedError();
}

void main() {
  late Directory dir;
  late Database db;
  late _FakeCrypto crypto;
  late SqliteVaultRepository repo;
  late VaultSession session;

  VaultItem item({
    required String id,
    String title = 'Banco',
    String secret = 'una-clave-larga-y-unica-1',
    String? website,
    VaultCategory category = VaultCategory.finance,
    int strengthScore = 90,
  }) => VaultItem(
    id: id,
    title: title,
    username: 'rene',
    secret: secret,
    category: category,
    strengthScore: strengthScore,
    lastUpdatedLabel: 'hoy',
    website: website,
    notes: 'nota',
    updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sqlite_repo_test');
    session = VaultSession(
      keyId: 'key-1',
      secretKey: SecretKey(List<int>.generate(32, (i) => i)),
    );
    crypto = _FakeCrypto();

    // The repository does not need an encrypted file to be exercised, but using
    // the real opener keeps the schema and pragma path under test too.
    db = openVaultDatabase(
      path: '${dir.path}/vault.db',
      key: Uint8List.fromList(List<int>.generate(32, (i) => 40 + i)),
    );
    ensureVaultSchema(db);
    repo = SqliteVaultRepository(
      db: db,
      cryptoService: crypto,
      readSession: () => session,
      readMinimumVersion: () => 4,
    );
  });

  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  test('save then fetch round-trips every field', () async {
    final saved = await repo.saveItem(
      item(id: 'r1', title: 'Correo', website: 'https://mail.example'),
    );
    expect(saved.id, 'r1');

    final items = await repo.fetchItems();
    expect(items, hasLength(1));
    final read = items.first;
    expect(read.title, 'Correo');
    expect(read.username, 'rene');
    expect(read.secret, 'una-clave-larga-y-unica-1');
    expect(read.category, VaultCategory.finance);
    expect(read.website, 'https://mail.example');
    expect(read.notes, 'nota');
    expect(read.updatedAt, DateTime.fromMillisecondsSinceEpoch(1700000000000));
  });

  test('saving twice updates one row instead of appending', () async {
    await repo.saveItem(item(id: 'r1', title: 'Primero'));
    await repo.saveItem(item(id: 'r1', title: 'Segundo'));

    final count = db.select('SELECT COUNT(*) c FROM vault_items').first['c'];
    expect(count, 1);
    expect((await repo.fetchItems()).first.title, 'Segundo');
  });

  test('the AAD is bound to the record id and the session key id', () async {
    await repo.saveItem(item(id: 'record-42'));
    // Two envelopes per item: payload and title. Both must bind the same record.
    expect(crypto.encryptCalls, hasLength(2));
    expect(crypto.encryptCalls.every((c) => c.recordId == 'record-42'), isTrue);
    expect(crypto.encryptCalls.every((c) => c.keyId == 'key-1'), isTrue);
  });

  test('delete is a soft delete and hides the item', () async {
    await repo.saveItem(item(id: 'r1'));
    await repo.deleteItem('r1');

    expect(await repo.fetchItems(), isEmpty);
    expect(await repo.fetchItemById('r1'), isNull);

    final row = db.select('SELECT deleted_at FROM vault_items').first;
    expect(row['deleted_at'], isNotNull);
  });

  test('search matches the title, case-insensitively, without decrypting payloads', () async {
    await repo.saveItem(item(id: 'r1', title: 'Banco Galicia'));
    await repo.saveItem(item(id: 'r2', title: 'Correo personal'));

    final hits = await repo.search('galicia');
    expect(hits, hasLength(1));
    expect(hits.first.id, 'r1');

    final all = await repo.search('');
    expect(all, hasLength(2));
  });

  test('findByHost normalizes the website and uses the index', () async {
    await repo.saveItem(
      item(id: 'r1', website: 'https://www.Banco.example/login?x=1'),
    );
    await repo.saveItem(item(id: 'r2', website: 'https://otro.example'));

    final stored = db.select('SELECT host FROM vault_hosts');
    expect(stored.map((r) => r['host']), contains('banco.example'));

    final hits = await repo.findByHost('banco.example');
    expect(hits, hasLength(1));
    expect(hits.first.id, 'r1');
  });

  test('an item without a website is not indexed for autofill', () async {
    await repo.saveItem(item(id: 'r1'));
    expect(db.select('SELECT * FROM vault_hosts'), isEmpty);
    expect(await repo.findByHost('cualquiera'), isEmpty);
  });

  test('the summary mirrors the blob repository math', () async {
    await repo.saveItem(
      item(id: 'r1', secret: 'repetida-clave-000', strengthScore: 50),
    );
    await repo.saveItem(
      item(id: 'r2', secret: 'repetida-clave-000', strengthScore: 90),
    );
    await repo.saveItem(
      item(id: 'r3', secret: 'otra-clave-distinta-111', strengthScore: 100),
    );

    final summary = await repo.fetchSummary();
    expect(summary.totalItems, 3);
    expect(summary.weakItems, 1); // only 50 is below 80
    expect(summary.reusedItems, 2); // the two items sharing a secret
    expect(summary.securityScore, 80); // (50 + 90 + 100) ~/ 3
  });

  test('without an unlocked session the repository refuses to work', () async {
    final locked = SqliteVaultRepository(
      db: db,
      cryptoService: crypto,
      readSession: () => null,
      readMinimumVersion: () => 4,
    );
    expect(() => locked.fetchItems(), throwsA(isA<StateError>()));
    expect(() => locked.saveItem(item(id: 'r1')), throwsA(isA<StateError>()));
  });

  test('a payload bound to another record is rejected, not silently used', () async {
    await repo.saveItem(item(id: 'r1'));
    // Simulate a row whose ciphertext was moved from another record.
    final foreign = await crypto.encrypt(
      plaintext: jsonEncode(item(id: 'r2').toJson()),
      secretKey: session,
      keyId: 'key-1',
      recordId: 'r2',
    );
    db.execute('UPDATE vault_items SET payload = ? WHERE record_id = ?', [
      foreign,
      'r1',
    ]);

    expect(() => repo.fetchItems(), throwsA(isA<StateError>()));
  });
}
