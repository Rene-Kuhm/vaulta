// Payload v3 (record-bound AES-GCM associated data) at the repository
// level: legacy compatibility, the one-time migration, the downgrade
// defense and the sync apply path. See docs/adr/0001-crypto-key-derivation-and-encrypted-blob.md.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/aes_gcm_vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/local_encrypted_vault_repository.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/vault_session.dart';
import 'package:gestor_contrasenas/core/sync/local_vault_mutation.dart';
import 'package:gestor_contrasenas/core/sync/remote_vault_blob_change.dart';
import 'package:gestor_contrasenas/core/sync/sync_item_payload_codec.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';

const _itemsKey = LocalEncryptedVaultRepository.encryptedVaultItemsKey;
const _markerKey = LocalEncryptedVaultRepository.itemPayloadMinVersionKey;

VaultItem _item(String id, {String secret = 'Str0ng!Secret#2026'}) {
  return VaultItem(
    id: id,
    title: 'Title $id',
    username: '$id@vaulta.test',
    secret: secret,
    category: VaultCategory.personal,
    strengthScore: 90,
    lastUpdatedLabel: 'now',
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

VaultSession _session({String keyId = 'key-generation-1'}) {
  return VaultSession.v2(
    keyId: keyId,
    secretKey: SecretKey(List<int>.generate(32, (i) => i * 7 % 256)),
    kdf: const {'name': 'argon2id'},
    dekWrap: const {'alg': 'AES-256-GCM'},
  );
}

class _Harness {
  _Harness({VaultSession? session, _ScriptedStorage? storage})
    : session = session ?? _session(),
      storage = storage ?? _ScriptedStorage();

  final VaultSession session;
  final _ScriptedStorage storage;
  final crypto = AesGcmVaultCryptoService();
  final mutations = <LocalVaultMutation>[];

  late final repository = LocalEncryptedVaultRepository(
    storage: storage,
    cryptoService: crypto,
    readSession: () => session,
    mutationSink: _RecordingSink(mutations),
  );

  /// Writes [items] as legacy envelopes: even indexes as v1 (raw key),
  /// odd indexes as v2 (session), exactly as pre-v3 builds stored them.
  Future<void> seedLegacy(List<VaultItem> items) async {
    final envelopes = <String>[];
    for (var i = 0; i < items.length; i++) {
      envelopes.add(
        await crypto.encryptLegacyForTesting(
          plaintext: jsonEncode(items[i].toJson()),
          secretKey: i.isEven ? session.secretKey : session,
          keyId: session.keyId,
        ),
      );
    }
    await storage.save(_itemsKey, jsonEncode(envelopes));
  }

  Future<List<Map<String, dynamic>>> storedEnvelopes() async {
    final raw = await storage.read(_itemsKey);
    return (jsonDecode(raw!) as List<dynamic>)
        .cast<String>()
        .map((e) => jsonDecode(e) as Map<String, dynamic>)
        .toList();
  }

  Future<void> appendRawEnvelope(String envelope) async {
    final raw = await storage.read(_itemsKey);
    final list = raw == null
        ? <String>[]
        : (jsonDecode(raw) as List<dynamic>).cast<String>();
    await storage.save(_itemsKey, jsonEncode([...list, envelope]));
  }

  /// Saves [item] and returns the mutation the repository queued for sync,
  /// or `null` when it deliberately queued none.
  ///
  /// This is the fail-closed probe for v4: the item key salt is not on
  /// the sync wire, so a v4 payload must not be queued at all.
  Future<LocalVaultMutation?> mutationFromSave(VaultItem item) async {
    mutations.clear();
    await repository.saveItem(item);
    await Future<void>.delayed(Duration.zero);
    return mutations.isEmpty ? null : mutations.single;
  }

  /// A v3 sync snapshot of [item]: sealed under the DEK with
  /// record-bound AAD, and still representable on the sync wire.
  ///
  /// v4 is the current at-rest format but sync refuses it until the wire
  /// carries the item key salt, so the sync contract is exercised with
  /// v3 — the newest payload the wire can actually express.
  Future<RemoteVaultBlobSnapshot> v3Snapshot(VaultItem item) async {
    final envelope =
        jsonDecode(
              await crypto.encryptV3ForTesting(
                plaintext: jsonEncode(item.toJson()),
                secretKey: session,
                keyId: session.keyId,
                recordId: item.id,
              ),
            )
            as Map<String, dynamic>;
    final payload = envelope['payload'] as Map<String, dynamic>;
    return RemoteVaultBlobSnapshot(
      recordId: item.id,
      version: 1,
      keyVersion: AesGcmVaultCryptoService.payloadVersionV3,
      ciphertext: SyncItemPayloadCodec.encode(
        recordId: envelope['rid'] as String,
        ciphertextB64: payload['ciphertext_b64'] as String,
      ),
      nonce: payload['nonce_b64'] as String,
      gcmTag: payload['tag_b64'] as String,
      updatedAt: DateTime.utc(2026, 1, 2),
    );
  }

  /// A v2 sync snapshot of [item] that decrypts correctly under the
  /// shared DEK, as a not-yet-upgraded device would push it.
  Future<RemoteVaultBlobSnapshot> legacySnapshot(VaultItem item) async {
    final legacy =
        jsonDecode(
              await crypto.encryptLegacyForTesting(
                plaintext: jsonEncode(item.toJson()),
                secretKey: session,
                keyId: session.keyId,
              ),
            )
            as Map<String, dynamic>;
    final payload = legacy['payload'] as Map<String, dynamic>;
    return RemoteVaultBlobSnapshot(
      recordId: item.id,
      version: 1,
      keyVersion: 2,
      ciphertext: payload['ciphertext_b64'] as String,
      nonce: payload['nonce_b64'] as String,
      gcmTag: payload['tag_b64'] as String,
      updatedAt: DateTime.utc(2026, 1, 2),
    );
  }
}

Matcher _rejectedWith(VaultPayloadRejection reason) => throwsA(
  isA<VaultPayloadRejectedError>().having((e) => e.reason, 'reason', reason),
);

void main() {
  group('payload v3 at rest', () {
    test('new writes are v3 envelopes bound to the item id', () async {
      final h = _Harness();
      await h.repository.saveItem(_item('github'));

      final envelopes = await h.storedEnvelopes();
      expect(envelopes.single['v'], AesGcmVaultCryptoService.payloadVersionV4);
      expect(envelopes.single['rid'], 'github');
      expect(envelopes.single['keyId'], h.session.keyId);
      expect(await h.storage.read(_markerKey), '3');
      expect((await h.repository.fetchItems()).single.id, 'github');
    });

    test('a stored envelope whose item id differs from its bound id is '
        'rejected', () async {
      final h = _Harness();
      // A device holding the DEK encrypts item "evil" but binds it to
      // record "github": the AAD verifies, the id check must not.
      final forged = await h.crypto.encrypt(
        plaintext: jsonEncode(_item('evil').toJson()),
        secretKey: h.session,
        keyId: h.session.keyId,
        recordId: 'github',
      );
      await h.appendRawEnvelope(forged);

      await expectLater(
        h.repository.fetchItems(),
        _rejectedWith(VaultPayloadRejection.recordMismatch),
      );
    });

    test('relabelling a stored envelope onto another record fails GCM',
        () async {
      final h = _Harness();
      await h.repository.saveItem(_item('github'));
      final envelope = (await h.storedEnvelopes()).single
        ..['rid'] = 'bank';
      await h.storage.save(_itemsKey, jsonEncode([jsonEncode(envelope)]));

      await expectLater(
        h.repository.fetchItems(),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('v1/v2 -> v3 migration', () {
    test('legacy items decrypt before migration', () async {
      final h = _Harness();
      await h.seedLegacy([_item('a'), _item('b')]);

      final items = await h.repository.fetchItems();
      expect(items.map((i) => i.id), unorderedEquals(['a', 'b']));
      expect(await h.storage.read(_markerKey), isNull);
    });

    test('converts every item to v3 and persists the marker', () async {
      final h = _Harness();
      final originals = [_item('a'), _item('b'), _item('c')];
      await h.seedLegacy(originals);

      final migrated = await h.repository.migrateItemsToCurrentVersion();

      expect(migrated, 3);
      final envelopes = await h.storedEnvelopes();
      expect(envelopes.map((e) => e['v']), everyElement(AesGcmVaultCryptoService.payloadVersionV4));
      expect(envelopes.map((e) => e['rid']), ['a', 'b', 'c']);
      expect(await h.storage.read(_markerKey), '3');
      final items = await h.repository.fetchItems();
      expect(
        items.map((i) => i.toJson()),
        unorderedEquals(originals.map((i) => i.toJson())),
      );
    });

    test('is idempotent', () async {
      final h = _Harness();
      await h.seedLegacy([_item('a'), _item('b')]);
      await h.repository.migrateItemsToCurrentVersion();
      final afterFirst = await h.storage.read(_itemsKey);

      final secondRun = await h.repository.migrateItemsToCurrentVersion();

      expect(secondRun, 0);
      expect(await h.storage.read(_itemsKey), afterFirst);
      expect(await h.storage.read(_markerKey), '3');
    });

    test('a failed live write leaves the legacy vault intact and retries',
        () async {
      final h = _Harness();
      await h.seedLegacy([_item('a'), _item('b')]);
      final legacyBlob = await h.storage.read(_itemsKey);
      h.storage.failNextSaveOf(_itemsKey);

      await expectLater(
        h.repository.migrateItemsToCurrentVersion(),
        throwsA(isA<StorageWriteFailure>()),
      );

      expect(await h.storage.read(_itemsKey), legacyBlob);
      expect(await h.storage.read(_markerKey), isNull);
      expect(
        await h.storage.read(LocalEncryptedVaultRepository.rekeyInProgressKey),
        isNull,
      );
      expect(
        (await h.repository.fetchItems()).map((i) => i.id),
        unorderedEquals(['a', 'b']),
      );

      expect(await h.repository.migrateItemsToCurrentVersion(), 2);
      expect((await h.storedEnvelopes()).map((e) => e['v']), everyElement(AesGcmVaultCryptoService.payloadVersionV4));
    });

    test('a process killed after staging recovers without data loss',
        () async {
      final h = _Harness();
      await h.seedLegacy([_item('a'), _item('b')]);
      final legacyBlob = await h.storage.read(_itemsKey);
      // Simulate a crash after the staging write but before the swap.
      await h.storage.save(
        LocalEncryptedVaultRepository.rekeyInProgressKey,
        'true',
      );
      await h.storage.save(
        LocalEncryptedVaultRepository.encryptedVaultItemsStagingKey,
        '["half-written"]',
      );

      final items = await h.repository.fetchItems();

      expect(items.map((i) => i.id), unorderedEquals(['a', 'b']));
      expect(await h.storage.read(_itemsKey), legacyBlob);
      expect(
        await h.storage.read(
          LocalEncryptedVaultRepository.encryptedVaultItemsStagingKey,
        ),
        isNull,
      );
      expect(await h.repository.migrateItemsToCurrentVersion(), 2);
    });

    test('a swap that committed before the write reported failure counts',
        () async {
      final h = _Harness();
      await h.seedLegacy([_item('a')]);
      h.storage.failNextSaveOf(_itemsKey, afterWriting: true);

      expect(await h.repository.migrateItemsToCurrentVersion(), 1);
      expect((await h.storedEnvelopes()).single['v'], AesGcmVaultCryptoService.payloadVersionV4);
      expect(await h.storage.read(_markerKey), '3');
    });

    test('after migration a legacy envelope at rest is refused', () async {
      final h = _Harness();
      await h.seedLegacy([_item('a')]);
      await h.repository.migrateItemsToCurrentVersion();

      final legacy = await h.crypto.encryptLegacyForTesting(
        plaintext: jsonEncode(_item('rolled-back').toJson()),
        secretKey: h.session,
        keyId: h.session.keyId,
      );
      await h.appendRawEnvelope(legacy);

      await expectLater(
        h.repository.fetchItems(),
        _rejectedWith(VaultPayloadRejection.downgrade),
      );
    });

    test('rekey output is v3 and sets the marker', () async {
      final h = _Harness();
      await h.seedLegacy([_item('a')]);
      final target = _session(keyId: 'key-generation-2');

      await h.repository.rekeyEntries(
        sourceSession: h.session,
        targetSession: target,
      );

      final envelope = (await h.storedEnvelopes()).single;
      expect(envelope['v'], AesGcmVaultCryptoService.payloadVersionV4);
      expect(envelope['keyId'], 'key-generation-2');
      expect(await h.storage.read(_markerKey), '3');
    });
  });

  group('sync apply path', () {
    test('a v3 payload round-trips to another device', () async {
      final sender = _Harness();
      final snapshot = await sender.v3Snapshot(_item('github'));
      expect(
        snapshot.keyVersion,
        AesGcmVaultCryptoService.payloadVersionV3,
      );
      expect(SyncItemPayloadCodec.decode(snapshot.ciphertext)?.recordId,
          'github');

      final receiver = _Harness(session: sender.session);
      final rejected = await receiver.repository.applyRemoteSnapshots(
        snapshots: [snapshot],
      );

      expect(rejected, isEmpty);
      expect((await receiver.repository.fetchItems()).single.id, 'github');
    });

    test('a v3 payload delivered under another record id is rejected',
        () async {
      final sender = _Harness();
      final snapshot = await sender.v3Snapshot(_item('github'));
      final receiver = _Harness(session: sender.session);
      await receiver.repository.saveItem(_item('bank'));

      final moved = RemoteVaultBlobSnapshot(
        recordId: 'bank',
        version: 2,
        keyVersion: snapshot.keyVersion,
        ciphertext: snapshot.ciphertext,
        nonce: snapshot.nonce,
        gcmTag: snapshot.gcmTag,
        updatedAt: snapshot.updatedAt,
      );
      final bound = SyncItemPayloadCodec.decode(snapshot.ciphertext)!;
      final relabelled = RemoteVaultBlobSnapshot(
        recordId: 'bank',
        version: 2,
        keyVersion: snapshot.keyVersion,
        ciphertext: SyncItemPayloadCodec.encode(
          recordId: 'bank',
          ciphertextB64: bound.ciphertextB64,
        ),
        nonce: snapshot.nonce,
        gcmTag: snapshot.gcmTag,
        updatedAt: snapshot.updatedAt,
      );

      final rejected = await receiver.repository.applyRemoteSnapshots(
        snapshots: [moved, relabelled],
      );

      expect(rejected, ['bank', 'bank']);
      final items = await receiver.repository.fetchItems();
      expect(items.map((i) => i.id), ['bank']);
      expect(items.single.title, 'Title bank');
    });

    test('a v3 payload under another key generation is rejected', () async {
      final sender = _Harness();
      final snapshot = await sender.v3Snapshot(_item('github'));
      final receiver = _Harness(
        session: VaultSession.v2(
          keyId: 'key-generation-2',
          secretKey: sender.session.secretKey,
          kdf: const {'name': 'argon2id'},
          dekWrap: const {'alg': 'AES-256-GCM'},
        ),
      );

      final rejected = await receiver.repository.applyRemoteSnapshots(
        snapshots: [snapshot],
      );

      expect(rejected, ['github']);
      expect(await receiver.repository.fetchItems(), isEmpty);
    });

    test('a v3 payload whose item id differs from the binding is rejected',
        () async {
      final h = _Harness();
      final forged =
          jsonDecode(
                await h.crypto.encrypt(
                  plaintext: jsonEncode(_item('evil').toJson()),
                  secretKey: h.session,
                  keyId: h.session.keyId,
                  recordId: 'github',
                ),
              )
              as Map<String, dynamic>;
      final payload = forged['payload'] as Map<String, dynamic>;

      final rejected = await h.repository.applyRemoteSnapshots(
        snapshots: [
          RemoteVaultBlobSnapshot(
            recordId: 'github',
            version: 1,
            keyVersion: 3,
            ciphertext: SyncItemPayloadCodec.encode(
              recordId: 'github',
              ciphertextB64: payload['ciphertext_b64'] as String,
            ),
            nonce: payload['nonce_b64'] as String,
            gcmTag: payload['tag_b64'] as String,
            updatedAt: DateTime.utc(2026, 1, 2),
          ),
        ],
      );

      expect(rejected, ['github']);
      expect(await h.repository.fetchItems(), isEmpty);
    });

    test('before migration a v2 sync payload is still accepted', () async {
      final h = _Harness();
      await h.seedLegacy([_item('a')]);

      final rejected = await h.repository.applyRemoteSnapshots(
        snapshots: [await h.legacySnapshot(_item('b'))],
      );

      expect(rejected, isEmpty);
      expect(
        (await h.repository.fetchItems()).map((i) => i.id),
        unorderedEquals(['a', 'b']),
      );
    });

    test('after migration a v1/v2 sync payload is rejected', () async {
      final h = _Harness();
      await h.seedLegacy([_item('a')]);
      await h.repository.migrateItemsToCurrentVersion();

      final downgraded = await h.legacySnapshot(
        _item('a', secret: 'attacker-chosen'),
      );
      final v1 = RemoteVaultBlobSnapshot(
        recordId: 'c',
        version: 1,
        keyVersion: 1,
        ciphertext: downgraded.ciphertext,
        nonce: downgraded.nonce,
        gcmTag: downgraded.gcmTag,
        updatedAt: downgraded.updatedAt,
      );
      final rejected = await h.repository.applyRemoteSnapshots(
        snapshots: [downgraded, v1],
      );

      expect(rejected, ['a', 'c']);
      final items = await h.repository.fetchItems();
      expect(items.single.secret, 'Str0ng!Secret#2026');
      expect((await h.storedEnvelopes()).map((e) => e['v']), everyElement(AesGcmVaultCryptoService.payloadVersionV4));
    });

    test('a v3-tagged payload without a valid binding is rejected', () async {
      final h = _Harness();
      final rejected = await h.repository.applyRemoteSnapshots(
        snapshots: [
          RemoteVaultBlobSnapshot(
            recordId: 'x',
            version: 1,
            keyVersion: 3,
            ciphertext: 'bm90LWJvdW5k',
            nonce: 'bm9uY2U=',
            gcmTag: 'dGFn',
            updatedAt: DateTime.utc(2026, 1, 2),
          ),
        ],
      );
      expect(rejected, ['x']);
    });
  });
}

/// Error thrown by [_ScriptedStorage] for an injected write failure.
class StorageWriteFailure implements Exception {
  const StorageWriteFailure();
}

class _ScriptedStorage implements SecureStorageService {
  final Map<String, String> _values = {};
  final Map<String, bool> _failures = {};

  /// Makes the next `save` of [key] throw. With [afterWriting] the
  /// value is persisted before the throw (a write that committed but
  /// reported failure).
  void failNextSaveOf(String key, {bool afterWriting = false}) {
    _failures[key] = afterWriting;
  }

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> save(String key, String value) async {
    final afterWriting = _failures.remove(key);
    if (afterWriting == null) {
      _values[key] = value;
      return;
    }
    if (afterWriting) {
      _values[key] = value;
    }
    throw const StorageWriteFailure();
  }
}

class _RecordingSink implements LocalVaultMutationSink {
  _RecordingSink(this.mutations);

  final List<LocalVaultMutation> mutations;

  @override
  Future<void> onLocalMutation(LocalVaultMutation mutation) async {
    mutations.add(mutation);
  }
}
