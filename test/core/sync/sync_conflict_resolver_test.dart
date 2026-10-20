import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/sync/local_remote_vault_store.dart';
import 'package:gestor_contrasenas/core/sync/remote_vault_blob_change.dart';
import 'package:gestor_contrasenas/core/sync/remote_vault_sync_repository.dart';
import 'package:gestor_contrasenas/core/sync/sync_conflict.dart';
import 'package:gestor_contrasenas/core/sync/sync_conflict_resolver.dart';

void main() {
  group('SyncConflictResolver', () {
    test('keep_local requeues mutation using remote version', () async {
      final storage = _InMemorySecureStorageService();
      final store = LocalRemoteVaultStore(storage: storage);
      var syncRuns = 0;
      final resolver = SyncConflictResolver(
        repository: _FakeRemoteVaultSyncRepository(),
        localStore: store,
        triggerPushSync: () async {
          syncRuns += 1;
        },
        now: () => DateTime.utc(2026, 3, 23, 15, 0),
      );

      const opId = 'op-1';
      await store.savePushQueue(
        userId: 'user-1',
        items: [
          PushQueueItem(
            opId: opId,
            localRecordId: 'entry-1',
            remoteRecordId: 'entry-1',
            kind: PushQueueOperationKind.upsert,
            status: PushQueueStatus.conflict,
            expectedVersion: 2,
            ciphertext: 'cipher-v3',
            nonce: 'nonce-v3',
            gcmTag: 'gcmTag-v3',
            keyVersion: 1,
            idempotencyKey: 'idem-1',
            attemptCount: 1,
            createdAt: DateTime.utc(2026, 3, 23, 14, 0),
            updatedAt: DateTime.utc(2026, 3, 23, 14, 1),
          ),
        ],
      );
      await store.savePendingConflicts(
        userId: 'user-1',
        conflicts: [
          SyncConflictRecord(
            id: 'conflict-1',
            opId: opId,
            localRecordId: 'entry-1',
            remoteRecordId: 'entry-1',
            kind: SyncConflictOperationKind.upsert,
            createdAt: DateTime.utc(2026, 3, 23, 14, 1),
            updatedAt: DateTime.utc(2026, 3, 23, 14, 1),
            expectedVersion: 2,
            currentVersion: 5,
          ),
        ],
      );

      final result = await resolver.resolve(
        conflictId: 'conflict-1',
        resolution: SyncConflictResolution.keepLocal,
      );

      final queue = await store.readPushQueue(userId: 'user-1');
      final conflicts = await store.readPendingConflicts(userId: 'user-1');

      expect(result.ok, isTrue);
      expect(queue, hasLength(1));
      expect(queue.first.status, PushQueueStatus.pending);
      expect(queue.first.expectedVersion, 5);
      expect(queue.first.idempotencyKey, isNull);
      expect(conflicts, isEmpty);
      expect(syncRuns, 1);
    });

    test('keep_remote drops queue mutation and clears conflict', () async {
      final storage = _InMemorySecureStorageService();
      final store = LocalRemoteVaultStore(storage: storage);
      final resolver = SyncConflictResolver(
        repository: _FakeRemoteVaultSyncRepository(),
        localStore: store,
      );

      await store.savePushQueue(
        userId: 'user-1',
        items: [
          PushQueueItem(
            opId: 'op-2',
            localRecordId: 'entry-2',
            remoteRecordId: 'entry-2',
            kind: PushQueueOperationKind.delete,
            status: PushQueueStatus.conflict,
            expectedVersion: 3,
            idempotencyKey: 'idem-2',
            attemptCount: 1,
            createdAt: DateTime.utc(2026, 3, 23, 14, 0),
            updatedAt: DateTime.utc(2026, 3, 23, 14, 2),
          ),
        ],
      );
      await store.savePendingConflicts(
        userId: 'user-1',
        conflicts: [
          SyncConflictRecord(
            id: 'conflict-2',
            opId: 'op-2',
            localRecordId: 'entry-2',
            remoteRecordId: 'entry-2',
            kind: SyncConflictOperationKind.delete,
            createdAt: DateTime.utc(2026, 3, 23, 14, 2),
            updatedAt: DateTime.utc(2026, 3, 23, 14, 2),
            expectedVersion: 3,
            currentVersion: 8,
          ),
        ],
      );

      final result = await resolver.resolve(
        conflictId: 'conflict-2',
        resolution: SyncConflictResolution.keepRemote,
      );

      final queue = await store.readPushQueue(userId: 'user-1');
      final conflicts = await store.readPendingConflicts(userId: 'user-1');

      expect(result.ok, isTrue);
      expect(queue, isEmpty);
      expect(conflicts, isEmpty);
    });

    test('keep_local keeps the item key salt of a v4 mutation', () async {
      final storage = _InMemorySecureStorageService();
      final store = LocalRemoteVaultStore(storage: storage);
      final resolver = SyncConflictResolver(
        repository: _FakeRemoteVaultSyncRepository(),
        localStore: store,
        now: () => DateTime.utc(2026, 3, 23, 15, 0),
      );

      const opId = 'op-v4';
      await store.savePushQueue(
        userId: 'user-1',
        items: [
          PushQueueItem(
            opId: opId,
            localRecordId: 'entry-1',
            remoteRecordId: 'entry-1',
            kind: PushQueueOperationKind.upsert,
            status: PushQueueStatus.conflict,
            expectedVersion: 2,
            ciphertext: 'ZW50cnkuMQ.Y2lwaGVy',
            nonce: 'bm9uY2U=',
            gcmTag: 'dGFn',
            keyVersion: 4,
            itemKeySalt: 'c2FsdC1ieC1ieQ==',
            itemKeyVersion: 1,
            idempotencyKey: 'idem-1',
            attemptCount: 1,
            createdAt: DateTime.utc(2026, 3, 23, 14, 0),
            updatedAt: DateTime.utc(2026, 3, 23, 14, 1),
          ),
        ],
      );
      await store.savePendingConflicts(
        userId: 'user-1',
        conflicts: [
          SyncConflictRecord(
            id: 'conflict-v4',
            opId: opId,
            localRecordId: 'entry-1',
            remoteRecordId: 'entry-1',
            kind: SyncConflictOperationKind.upsert,
            createdAt: DateTime.utc(2026, 3, 23, 14, 1),
            updatedAt: DateTime.utc(2026, 3, 23, 14, 1),
            expectedVersion: 2,
            currentVersion: 5,
          ),
        ],
      );

      final result = await resolver.resolve(
        conflictId: 'conflict-v4',
        resolution: SyncConflictResolution.keepLocal,
      );

      final queue = await store.readPushQueue(userId: 'user-1');
      expect(result.ok, isTrue);
      expect(queue, hasLength(1));
      expect(
        queue.first.itemKeySalt,
        'c2FsdC1ieC1ieQ==',
        reason: 'a v4 retry without its salt is a payload nobody can open',
      );
      expect(queue.first.itemKeyVersion, 1);
      expect(queue.first.expectedVersion, 5);
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

class _FakeRemoteVaultSyncRepository implements RemoteVaultSyncRepository {
  @override
  Future<List<RemoteVaultBlobChange>> fetchChangesSince({
    required int afterOpId,
    int limit = 200,
  }) async {
    return const [];
  }

  @override
  Future<RemoteVaultPushResult> pushDeleteBlob({
    required String deviceId,
    required String idempotencyKey,
    required String recordId,
    required int expectedVersion,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<RemoteVaultPushResult> pushUpsertBlob({
    required String deviceId,
    required String idempotencyKey,
    required String recordId,
    required int? expectedVersion,
    required String ciphertext,
    required String nonce,
    required String? gcmTag,
    required int keyVersion,
    String? itemKeySalt,
    int? itemKeyVersion,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<String?> readCurrentUserId() async => 'user-1';
}
