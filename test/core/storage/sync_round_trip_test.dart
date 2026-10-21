import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/core/security/aes_gcm_vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/vault_session.dart';
import 'package:gestor_contrasenas/core/storage/sqlite_vault_repository.dart';
import 'package:gestor_contrasenas/core/storage/vault_database_opener.dart';
import 'package:gestor_contrasenas/core/sync/remote_vault_blob_change.dart';
import 'package:gestor_contrasenas/core/sync/sync_item_payload_codec.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:sqlite3/sqlite3.dart';

/// The sync round trip without a network: two independent encrypted databases
/// driven through the same code path the pull side uses.
///
/// This is what can honestly be proven in this environment. A real two-device
/// round trip needs a Supabase project and credentials, which do not exist here;
/// what that would add on top is transport, RLS and CAS conflict handling, not the
/// port that was missing.
void main() {
  late Directory dir;
  late VaultSession session;
  late AesGcmVaultCryptoService crypto;

  const secret = 'Secreto-Que-Viaja-Entre-Bases-77';
  const title = 'Correo Compartido';
  const website = 'https://www.correo.example/login';

  VaultItem item({String id = 'sync-record-1'}) => VaultItem(
    id: id,
    title: title,
    username: 'rene',
    secret: secret,
    category: VaultCategory.work,
    strengthScore: 92,
    lastUpdatedLabel: 'hoy',
    website: website,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
  );

  ({Database db, SqliteVaultRepository repo}) openRepo(
    String name,
    Uint8List key,
  ) {
    final db = openVaultDatabase(path: '${dir.path}/$name.db', key: key);
    ensureVaultSchema(db);
    return (
      db: db,
      repo: SqliteVaultRepository(
        db: db,
        cryptoService: crypto,
        readSession: () => session,
        readMinimumVersion: () => 3,
      ),
    );
  }

  String storedPayload(Database db, String recordId) =>
      db.select('SELECT payload FROM vault_items WHERE record_id = ?', [
            recordId,
          ]).first['payload']
          as String;

  /// Splits a stored v4 envelope back into the fields the sync wire carries. This
  /// mirrors what the push side sends, which is what the pull side must rebuild.
  RemoteVaultBlobSnapshot upsertSnapshot({
    required String recordId,
    required String envelope,
  }) {
    final decoded = jsonDecode(envelope) as Map<String, dynamic>;
    final payload = decoded['payload'] as Map<String, dynamic>;
    return RemoteVaultBlobSnapshot(
      recordId: recordId,
      version: 1,
      keyVersion: decoded['v'] as int,
      ciphertext: SyncItemPayloadCodec.encode(
        recordId: recordId,
        ciphertextB64: payload['ciphertext_b64'] as String,
      ),
      nonce: payload['nonce_b64'] as String,
      gcmTag: payload['tag_b64'] as String,
      itemKeySalt: decoded['salt'] as String?,
      itemKeyVersion: decoded['iv'] as int?,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
  }

  RemoteVaultBlobSnapshot tombstoneSnapshot(String recordId) =>
      RemoteVaultBlobSnapshot(
        recordId: recordId,
        version: 2,
        keyVersion: 4,
        deletedAt: DateTime.fromMillisecondsSinceEpoch(1800000000000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1800000000000),
      );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sync_round_trip');
    crypto = AesGcmVaultCryptoService();
    session = VaultSession(
      keyId: 'sync-key',
      secretKey: SecretKey(List<int>.generate(32, (i) => 31 + i)),
    );
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('an item written on device A lands on device B through the pull path', () async {
    final a = openRepo('a', Uint8List.fromList(List<int>.generate(32, (i) => 41 + i)));
    await a.repo.saveItem(item());

    final snapshot = upsertSnapshot(
      recordId: 'sync-record-1',
      envelope: storedPayload(a.db, 'sync-record-1'),
    );
    a.db.close();

    final b = openRepo('b', Uint8List.fromList(List<int>.generate(32, (i) => 51 + i)));
    expect(await b.repo.fetchItems(), isEmpty);

    final rejected = await b.repo.applyRemoteSnapshots(snapshots: [snapshot]);
    expect(rejected, isEmpty);

    final landed = await b.repo.fetchItems();
    expect(landed, hasLength(1));
    expect(landed.single.secret, secret);
    expect(landed.single.title, title);
    expect(landed.single.website, website);

    // The autofill index is rebuilt locally from the pulled item, so B can fill.
    expect(await b.repo.findByHost('correo.example'), hasLength(1));
    b.db.close();
  });

  test('a tombstone removes the item and its autofill index, softly', () async {
    final b = openRepo('b2', Uint8List.fromList(List<int>.generate(32, (i) => 61 + i)));
    await b.repo.saveItem(item());

    final rejected = await b.repo.applyRemoteSnapshots(
      snapshots: [tombstoneSnapshot('sync-record-1')],
    );
    expect(rejected, isEmpty);
    expect(await b.repo.fetchItems(), isEmpty, reason: 'the item must disappear');
    expect(
      await b.repo.findByHost('correo.example'),
      isEmpty,
      reason: 'the autofill index must drop the entry too',
    );

    // Soft: the row and its ciphertext are still there for audit and recovery.
    final row = b.db.select(
      'SELECT deleted_at FROM vault_items WHERE record_id = ?',
      ['sync-record-1'],
    );
    expect(row, hasLength(1));
    expect(row.first['deleted_at'], isNotNull);
    b.db.close();
  });

  test('a snapshot from a different vault key is rejected, not written', () async {
    final a = openRepo('a3', Uint8List.fromList(List<int>.generate(32, (i) => 71 + i)));
    await a.repo.saveItem(item());
    final snapshot = upsertSnapshot(
      recordId: 'sync-record-1',
      envelope: storedPayload(a.db, 'sync-record-1'),
    );
    a.db.close();

    // Device B is unlocked with a DIFFERENT vault DEK, so the payload cannot be
    // authenticated there. It must be reported as rejected and change nothing.
    session = VaultSession(
      keyId: 'other-key',
      secretKey: SecretKey(List<int>.generate(32, (i) => 91 + i)),
    );
    final b = openRepo('b3', Uint8List.fromList(List<int>.generate(32, (i) => 81 + i)));
    final rejected = await b.repo.applyRemoteSnapshots(snapshots: [snapshot]);

    expect(rejected, ['sync-record-1']);
    expect(await b.repo.fetchItems(), isEmpty);
    b.db.close();
  });

  test('the wire form round-trips through the codec both sides share', () {
    final wire = SyncItemPayloadCodec.encode(
      recordId: 'record-1',
      ciphertextB64: 'abc123',
    );
    final decoded = SyncItemPayloadCodec.decode(wire);
    expect(decoded, isNotNull);
    expect(decoded!.recordId, 'record-1');
    expect(decoded.ciphertextB64, 'abc123');
  });
}
