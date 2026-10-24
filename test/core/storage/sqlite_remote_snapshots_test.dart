// ignore_for_file: avoid_dynamic_calls

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
import 'package:gestor_contrasenas/core/sync/remote_vault_blob_change.dart';
import 'package:gestor_contrasenas/core/sync/sync_item_payload_codec.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:sqlite3/sqlite3.dart';

/// Envelope fake that mirrors the real service's contract: every payload is
/// bound to its record id, a payload moved to another record or sealed under
/// another key generation is refused, and a record in [tamperedRecords] fails
/// authentication the way real AES-GCM would.
///
/// The plaintext is stored base64-encoded inside a normal v4 envelope, so the
/// wire snapshots this file builds look exactly like the ones the backend
/// carries (`base64` ciphertext that decrypts to the item JSON).
class _FakeCrypto implements VaultCryptoService {
  static const String salt = 'c2FsdA==';

  /// Record ids whose payload has to fail its GCM check.
  final Set<String> tamperedRecords = <String>{};

  @override
  Future<String> encrypt({
    required String plaintext,
    required Object secretKey,
    required String keyId,
    required String recordId,
  }) async => jsonEncode({
    'v': 4,
    'keyId': keyId,
    'rid': recordId,
    'iv': 1,
    'salt': salt,
    'payload': {
      'alg': 'AES-256-GCM',
      'nonce_b64': 'nonce',
      'ciphertext_b64': base64Encode(utf8.encode(plaintext)),
      'tag_b64': 'tag',
    },
  });

  @override
  VaultItemPayloadHeader inspect(String ciphertext) {
    final envelope = _decode(ciphertext);
    return VaultItemPayloadHeader(
      version: (envelope['v'] ?? envelope['version'] ?? 1) as int,
      keyId: envelope['keyId'] as String?,
      recordId: envelope['rid'] as String?,
      itemKeyVersion: envelope['iv'] as int?,
    );
  }

  @override
  Future<String> decrypt({
    required String ciphertext,
    required Object secretKey,
    required String expectedKeyId,
    required String? recordId,
    int minimumVersion = 1,
  }) async {
    final envelope = _decode(ciphertext);
    final header = inspect(ciphertext);
    if (header.version < minimumVersion) {
      throw VaultPayloadRejectedError(
        VaultPayloadRejection.downgrade,
        'Payload v${header.version} is below the vault floor.',
      );
    }
    if (header.keyId != expectedKeyId) {
      throw VaultPayloadRejectedError(
        VaultPayloadRejection.keyMismatch,
        'Payload is sealed under another key generation.',
      );
    }
    if (recordId != null && header.recordId != recordId) {
      throw VaultPayloadRejectedError(
        VaultPayloadRejection.recordMismatch,
        'Payload is bound to another record.',
      );
    }
    if (header.recordId != null && tamperedRecords.contains(header.recordId)) {
      throw SecretBoxAuthenticationError(message: 'tampered payload');
    }
    final nested = envelope['payload'] is Map<String, dynamic>
        ? envelope['payload'] as Map<String, dynamic>
        : envelope;
    final message = (nested['ciphertext_b64'] ?? nested['ciphertext']) as String;
    return utf8.decode(base64Decode(message));
  }

  Map<String, dynamic> _decode(String ciphertext) {
    final decoded = jsonDecode(ciphertext);
    if (decoded is! Map<String, dynamic>) {
      throw VaultPayloadRejectedError(
        VaultPayloadRejection.malformed,
        'Not an envelope.',
      );
    }
    return decoded;
  }
}

class _MapStorage implements SecureStorageService {
  _MapStorage([Map<String, String>? seed]) : values = {...?seed};

  final Map<String, String> values;

  @override
  Future<void> save(String key, String value) async => values[key] = value;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// The vault's payload floor once it has been migrated to the bound format
/// (`LocalEncryptedVaultRepository.currentItemPayloadVersion`): v1/v2 payloads
/// are refused as a downgrade by both storages, v3 and v4 are accepted.
const int _payloadFloor = 3;

VaultSession _session() => VaultSession(
  keyId: 'key-1',
  secretKey: SecretKey(List<int>.generate(32, (i) => i)),
);

VaultItem _item(
  String id, {
  String title = 'Banco',
  String? website,
  VaultCategory category = VaultCategory.finance,
  int strengthScore = 90,
}) => VaultItem(
  id: id,
  title: title,
  username: 'rene',
  secret: 'una-clave-larga-y-unica-$id',
  category: category,
  strengthScore: strengthScore,
  lastUpdatedLabel: 'hoy',
  website: website,
  notes: 'nota',
  updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
);

/// The value the backend stores in `vault_blobs.ciphertext`: for a bound
/// payload the codec wraps the base64 ciphertext with the bound record id.
String _wireCiphertext(VaultItem item, {int keyVersion = 4, String? boundTo}) {
  final ciphertext = base64Encode(utf8.encode(jsonEncode(item.toJson())));
  if (keyVersion < SyncItemPayloadCodec.boundPayloadVersion) {
    return ciphertext;
  }
  return SyncItemPayloadCodec.encode(
    recordId: boundTo ?? item.id,
    ciphertextB64: ciphertext,
  );
}

RemoteVaultBlobSnapshot _snapshot(
  VaultItem item, {
  int keyVersion = 4,
  String? boundTo,
  String? ciphertext,
  String? nonce = 'nonce-1',
  String? salt = _FakeCrypto.salt,
  int? itemKeyVersion = 1,
}) => RemoteVaultBlobSnapshot(
  recordId: item.id,
  version: 1,
  keyVersion: keyVersion,
  ciphertext: ciphertext ?? _wireCiphertext(item, keyVersion: keyVersion, boundTo: boundTo),
  nonce: nonce,
  gcmTag: 'tag',
  itemKeySalt: keyVersion >= SyncItemPayloadCodec.itemKeyPayloadVersion
      ? salt
      : null,
  itemKeyVersion: keyVersion >= SyncItemPayloadCodec.itemKeyPayloadVersion
      ? itemKeyVersion
      : null,
  updatedAt: DateTime.utc(2026, 5, 1),
);

RemoteVaultBlobSnapshot _tombstone(String id) => RemoteVaultBlobSnapshot(
  recordId: id,
  version: 2,
  keyVersion: 4,
  deletedAt: DateTime.utc(2026, 5, 2),
  updatedAt: DateTime.utc(2026, 5, 2),
);

void main() {
  late Directory dir;
  late Database db;
  late _FakeCrypto crypto;
  late SqliteVaultRepository sqlite;
  late VaultSession session;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sqlite_remote_snapshots');
    session = _session();
    crypto = _FakeCrypto();
    db = openVaultDatabase(
      path: '${dir.path}/vault.db',
      key: Uint8List.fromList(List<int>.generate(32, (i) => 40 + i)),
    );
    ensureVaultSchema(db);
    sqlite = SqliteVaultRepository(
      db: db,
      cryptoService: crypto,
      readSession: () => session,
      readMinimumVersion: () => _payloadFloor,
    );
  });

  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  group('SqliteVaultRepository.applyRemoteSnapshots', () {
    test('a tombstone soft-deletes the row and its host index', () async {
      await sqlite.saveItem(
        _item('r1', website: 'https://www.banco.example/login'),
      );

      final rejected = await sqlite.applyRemoteSnapshots(
        snapshots: [_tombstone('r1')],
      );

      expect(rejected, isEmpty);
      expect(await sqlite.fetchItems(), isEmpty);
      expect(await sqlite.fetchItemById('r1'), isNull);
      expect(await sqlite.findByHost('banco.example'), isEmpty);

      final row = db.select(
        'SELECT deleted_at FROM vault_items WHERE record_id = ?',
        ['r1'],
      );
      // Soft, not gone: the ciphertext stays, so a mis-pulled tombstone is
      // recoverable the same way a mistaken local delete is.
      expect(row.single['deleted_at'], isNotNull);
      expect(
        db.select('SELECT * FROM vault_hosts WHERE record_id = ?', ['r1']),
        isEmpty,
      );
    });

    test('a valid snapshot writes the row and its host index', () async {
      final item = _item(
        'r2',
        title: 'Correo',
        website: 'https://mail.example/inbox',
        category: VaultCategory.work,
      );

      final rejected = await sqlite.applyRemoteSnapshots(
        snapshots: [_snapshot(item)],
      );

      expect(rejected, isEmpty);
      final read = await sqlite.fetchItemById('r2');
      expect(read, isNotNull);
      expect(read!.title, 'Correo');
      expect(read.username, 'rene');
      expect(read.secret, item.secret);
      expect(read.category, VaultCategory.work);
      expect(read.website, 'https://mail.example/inbox');
      expect(read.notes, 'nota');

      final rows = db.select(
        'SELECT payload, title_ct, category, updated_at, deleted_at '
        'FROM vault_items WHERE record_id = ?',
        ['r2'],
      );
      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row['payload'], isA<String>());
      expect(row['title_ct'], isA<String>());
      expect(row['category'], 'work');
      expect(
        row['updated_at'],
        item.updatedAt!.millisecondsSinceEpoch,
      );
      expect(row['deleted_at'], isNull);
      expect(
        db
            .select('SELECT host FROM vault_hosts WHERE record_id = ?', ['r2'])
            .map((row) => row['host']),
        ['mail.example'],
      );
      expect(
        (await sqlite.findByHost('mail.example')).map((item) => item.id),
        ['r2'],
      );
    });

    test('a snapshot with a missing nonce is rejected and writes nothing', () async {
      await sqlite.saveItem(_item('kept'));

      final rejected = await sqlite.applyRemoteSnapshots(
        snapshots: [_snapshot(_item('r3', title: 'Sin nonce'), nonce: null)],
      );

      expect(rejected, ['r3']);
      expect(await sqlite.fetchItemById('r3'), isNull);
      expect(
        db.select(
          'SELECT record_id FROM vault_items WHERE record_id = ?',
          ['r3'],
        ),
        isEmpty,
      );
      // The batch kept the rows it was not asked to change.
      expect(
        (await sqlite.fetchItems()).map((item) => item.id),
        ['kept'],
      );
    });

    test('a snapshot bound to another record is rejected', () async {
      await sqlite.saveItem(_item('r4'));

      final rejected = await sqlite.applyRemoteSnapshots(
        snapshots: [
          // The wire payload says it belongs to another record: the pull path
          // must not decrypt it into r4.
          _snapshot(
            _item('r4', title: 'Secuestrado'),
            boundTo: 'otro-record',
          ),
        ],
      );

      expect(rejected, ['r4']);
      expect((await sqlite.fetchItemById('r4'))!.title, 'Banco');
    });

    test('a payload that fails authentication is rejected, not applied', () async {
      crypto.tamperedRecords.add('r5');

      final rejected = await sqlite.applyRemoteSnapshots(
        snapshots: [_snapshot(_item('r5'))],
      );

      expect(rejected, ['r5']);
      expect(await sqlite.fetchItemById('r5'), isNull);
    });

    test('an item-keyed payload without its salt is rejected', () async {
      final rejected = await sqlite.applyRemoteSnapshots(
        snapshots: [_snapshot(_item('r6'), salt: null)],
      );

      expect(rejected, ['r6']);
      expect(await sqlite.fetchItemById('r6'), isNull);
    });

    test('a refused legacy payload is skipped without being reported', () async {
      final rejected = await sqlite.applyRemoteSnapshots(
        snapshots: [
          // A v1 snapshot that lost its nonce: nothing to decrypt and nothing
          // bound, so it is the documented downgrade skip, not a rejection.
          _snapshot(_item('r7'), keyVersion: 1, nonce: null),
        ],
      );

      expect(rejected, isEmpty);
      expect(await sqlite.fetchItemById('r7'), isNull);
    });

    test('applying the same batch twice leaves one row', () async {
      final snapshot = _snapshot(_item('r8', title: 'Idempotente'));

      await sqlite.applyRemoteSnapshots(snapshots: [snapshot]);
      await sqlite.applyRemoteSnapshots(snapshots: [snapshot]);

      expect(
        db.select('SELECT * FROM vault_items WHERE record_id = ?', ['r8']),
        hasLength(1),
      );
      expect((await sqlite.fetchItemById('r8'))!.title, 'Idempotente');
    });

    test('an undecodable payload rolls the whole batch back', () async {
      // A payload that decrypts to something that is not an item is not a
      // per-record rejection the pull path can surface: it is a broken batch,
      // and the blob path writes nothing in that case either.
      final broken = RemoteVaultBlobSnapshot(
        recordId: 'broken',
        version: 1,
        keyVersion: 3,
        ciphertext: SyncItemPayloadCodec.encode(
          recordId: 'broken',
          ciphertextB64: base64Encode(utf8.encode('{"id":"broken"}')),
        ),
        nonce: 'nonce-1',
        updatedAt: DateTime.utc(2026, 5, 1),
      );

      await expectLater(
        sqlite.applyRemoteSnapshots(
          snapshots: [_snapshot(_item('written-first')), broken],
        ),
        throwsA(isA<TypeError>()),
      );

      expect(
        db.select('SELECT * FROM vault_items'),
        isEmpty,
        reason: 'the transaction must roll back the item applied before it',
      );
    });

    test('without an unlocked session the batch fails closed', () async {
      final locked = SqliteVaultRepository(
        db: db,
        cryptoService: crypto,
        readSession: () => null,
        readMinimumVersion: () => _payloadFloor,
      );

      expect(
        () => locked.applyRemoteSnapshots(
          snapshots: [_snapshot(_item('r9'))],
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  test(
    'the SQLite path rejects exactly the records the blob path rejects',
    () async {
      // Both storages at the same payload floor, one fake crypto, one batch.
      final blobStorage = _MapStorage({
        LocalEncryptedVaultRepository.itemPayloadMinVersionKey:
            '$_payloadFloor',
      });
      final blob = LocalEncryptedVaultRepository(
        storage: blobStorage,
        cryptoService: crypto,
        readSession: () => session,
      );

      await sqlite.saveItem(_item('tombstoned'));
      await blob.saveItem(_item('tombstoned'));

      crypto.tamperedRecords.add('tampered');

      final snapshots = <RemoteVaultBlobSnapshot>[
        _snapshot(_item('v3-new', title: 'V3'), keyVersion: 3),
        _snapshot(_item('v4-new', title: 'V4')),
        _tombstone('tombstoned'),
        _snapshot(_item('no-nonce', title: 'X'), keyVersion: 3, nonce: null),
        _snapshot(_item('foreign', title: 'X'), boundTo: 'otro'),
        _snapshot(
          _item('malformed', title: 'X'),
          keyVersion: 3,
          ciphertext: 'sin-punto',
        ),
        _snapshot(_item('tampered', title: 'X'), keyVersion: 3),
        _snapshot(
          _item('legacy-no-nonce', title: 'X'),
          keyVersion: 1,
          nonce: null,
        ),
        _snapshot(_item('legacy-v1', title: 'X'), keyVersion: 1),
        _snapshot(_item('v4-no-salt', title: 'X'), salt: null),
      ];

      final sqliteRejected = await sqlite.applyRemoteSnapshots(
        snapshots: snapshots,
      );
      final blobRejected = await blob.applyRemoteSnapshots(
        snapshots: snapshots,
      );

      expect(sqliteRejected, blobRejected);
      expect(sqliteRejected, [
        'no-nonce',
        'foreign',
        'malformed',
        'tampered',
        'legacy-v1',
        'v4-no-salt',
      ]);

      // Same accepted set on both sides: pulled items land, tombstones hide.
      Set<String> idsOf(List<VaultItem> items) =>
          items.map((item) => item.id).toSet();
      expect(
        idsOf(await sqlite.fetchItems()),
        idsOf(await blob.fetchItems()),
      );
      expect(idsOf(await sqlite.fetchItems()), {'v3-new', 'v4-new'});
    },
  );
}
