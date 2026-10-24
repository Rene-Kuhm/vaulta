// The push queue has to survive a process restart carrying the item key
// salt, otherwise a retry after a crash ships a v4 payload with no salt
// and the receiving device derives the wrong item key.
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/sync/local_remote_vault_store.dart';
import 'package:gestor_contrasenas/core/sync/local_vault_mutation.dart';
import 'package:gestor_contrasenas/core/sync/sync_item_payload_codec.dart';

void main() {
  group('PushQueueItem', () {
    test('takes the salt off the mutation it was built from', () {
      final item = PushQueueItem.fromMutation(
        opId: 'op-1',
        remoteRecordId: 'remote-1',
        mutation: LocalVaultMutation.upsert(
          localRecordId: 'entry-1',
          ciphertext: 'ZW50cnkuMQ.Y2lwaGVy',
          nonce: 'bm9uY2U=',
          gcmTag: 'dGFn',
          keyVersion: SyncItemPayloadCodec.itemKeyPayloadVersion,
          itemKeySalt: 'c2FsdC1ieC1ieQ==',
          itemKeyVersion: 1,
          occurredAt: DateTime.utc(2026, 3, 23, 15),
        ),
      );

      expect(item.itemKeySalt, 'c2FsdC1ieC1ieQ==');
      expect(item.itemKeyVersion, 1);
    });

    test('a delete carries no salt', () {
      final item = PushQueueItem.fromMutation(
        opId: 'op-2',
        remoteRecordId: 'remote-2',
        mutation: LocalVaultMutation.delete(
          localRecordId: 'entry-2',
          occurredAt: DateTime.utc(2026, 3, 23, 15),
        ),
      );

      expect(item.itemKeySalt, isNull);
      expect(item.itemKeyVersion, isNull);
    });

    test('survives a queue save and reload', () async {
      final storage = _InMemorySecureStorageService();
      final store = LocalRemoteVaultStore(storage: storage);
      final created = DateTime.utc(2026, 3, 23, 15);

      await store.savePushQueue(
        userId: 'user-1',
        items: [
          PushQueueItem.fromMutation(
            opId: 'op-1',
            remoteRecordId: 'remote-1',
            mutation: LocalVaultMutation.upsert(
              localRecordId: 'entry-1',
              ciphertext: 'ZW50cnkuMQ.Y2lwaGVy',
              nonce: 'bm9uY2U=',
              gcmTag: 'dGFn',
              keyVersion: SyncItemPayloadCodec.itemKeyPayloadVersion,
              itemKeySalt: 'c2FsdC1ieC1ieQ==',
              itemKeyVersion: 1,
              occurredAt: created,
            ),
          ),
        ],
      );

      final reloaded = await store.readPushQueue(userId: 'user-1');

      expect(reloaded, hasLength(1));
      expect(reloaded.single.itemKeySalt, 'c2FsdC1ieC1ieQ==');
      expect(reloaded.single.itemKeyVersion, 1);
      expect(reloaded.single.ciphertext, 'ZW50cnkuMQ.Y2lwaGVy');
    });

    test('a queue persisted before this change still loads', () async {
      final storage = _InMemorySecureStorageService();
      final store = LocalRemoteVaultStore(storage: storage);
      await storage.save(
        'vault_sync_push_queue_v1:user-1',
        '[{"opId":"op-1","localRecordId":"entry-1",'
            '"remoteRecordId":"remote-1","kind":"upsert",'
            '"status":"pending","keyVersion":3,'
            '"ciphertext":"ZW50cnkuMQ.Y2lwaGVy","nonce":"bm9uY2U=",'
            '"gcmTag":"dGFn","createdAt":"2026-03-23T15:00:00.000Z",'
            '"updatedAt":"2026-03-23T15:00:00.000Z"}]',
      );

      final reloaded = await store.readPushQueue(userId: 'user-1');

      expect(reloaded, hasLength(1));
      expect(reloaded.single.itemKeySalt, isNull);
      expect(reloaded.single.itemKeyVersion, isNull);
    });

    test('copyWith keeps the salt across dispatch updates', () {
      final item = PushQueueItem(
        opId: 'op-1',
        localRecordId: 'entry-1',
        remoteRecordId: 'remote-1',
        kind: PushQueueOperationKind.upsert,
        status: PushQueueStatus.pending,
        ciphertext: 'ZW50cnkuMQ.Y2lwaGVy',
        nonce: 'bm9uY2U=',
        gcmTag: 'dGFn',
        keyVersion: SyncItemPayloadCodec.itemKeyPayloadVersion,
        itemKeySalt: 'c2FsdC1ieC1ieQ==',
        itemKeyVersion: 1,
        createdAt: DateTime.utc(2026, 3, 23, 15),
        updatedAt: DateTime.utc(2026, 3, 23, 15),
      );

      final inFlight = item.copyWith(
        status: PushQueueStatus.inFlight,
        idempotencyKey: 'idem-1',
        attemptCount: 1,
      );

      expect(inFlight.itemKeySalt, 'c2FsdC1ieC1ieQ==');
      expect(inFlight.itemKeyVersion, 1);
    });
  });
}

class _InMemorySecureStorageService implements SecureStorageService {
  final Map<String, String> _values = {};

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> save(String key, String value) async {
    _values[key] = value;
  }
}
