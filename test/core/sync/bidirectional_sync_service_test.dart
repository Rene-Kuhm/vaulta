import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/sync/bidirectional_sync_service.dart';
import 'package:gestor_contrasenas/core/sync/local_remote_vault_store.dart';
import 'package:gestor_contrasenas/core/sync/local_vault_mutation.dart';
import 'package:gestor_contrasenas/core/sync/remote_vault_blob_change.dart';
import 'package:gestor_contrasenas/core/sync/remote_vault_sync_repository.dart';
import 'package:gestor_contrasenas/core/sync/sync_item_payload_codec.dart';
import 'package:gestor_contrasenas/core/sync/sync_runtime_hardening.dart';

class _InMemorySecureStorageService implements SecureStorageService {
  final Map<String, String> _values = {};

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> save(String key, String value) async => _values[key] = value;
}

/// A local record id that is already a UUID, so the remote row it maps to
/// is the same string and a pulled payload's bound record id can be
/// verified against the row it arrived under.
const _v4RecordId = '11111111-1111-4111-8111-111111111111';

class _FakeRemoteVaultSyncRepository implements RemoteVaultSyncRepository {
  _FakeRemoteVaultSyncRepository({
    Map<int, List<RemoteVaultBlobChange>>? pullBatches,
    List<RemoteVaultPushResult> pushResponses = const [],
    Object? failFirstFetchWith,
  }) : _pullBatches = pullBatches ?? const {},
       _pushResponses = [...pushResponses],
       _failFirstFetchWith = failFirstFetchWith;

  final Map<int, List<RemoteVaultBlobChange>> _pullBatches;
  final List<RemoteVaultPushResult> _pushResponses;
  final Object? _failFirstFetchWith;
  int _pushIndex = 0;

  final List<int> afterOpIds = [];
  final List<_UpsertCall> upsertCalls = [];
  final List<_DeleteCall> deleteCalls = [];

  int _fetchCallCount = 0;

  @override
  Future<String?> readCurrentUserId() async => 'user-1';

  @override
  Future<List<RemoteVaultBlobChange>> fetchChangesSince({
    required int afterOpId,
    int limit = 200,
  }) async {
    _fetchCallCount += 1;
    afterOpIds.add(afterOpId);
    if (_fetchCallCount == 1 && _failFirstFetchWith != null) {
      throw _failFirstFetchWith;
    }
    return _pullBatches[afterOpId] ?? const [];
  }

  @override
  Future<RemoteVaultPushResult> pushUpsertBlob({
    required String deviceId,
    required String idempotencyKey,
    required String recordId,
    required int? expectedVersion,
    required String ciphertext,
    required String nonce,
    String? gcmTag,
    required int keyVersion,
    String? itemKeySalt,
    int? itemKeyVersion,
  }) async {
    upsertCalls.add(
      _UpsertCall(
        deviceId: deviceId,
        idempotencyKey: idempotencyKey,
        recordId: recordId,
        expectedVersion: expectedVersion,
        ciphertext: ciphertext,
        nonce: nonce,
        gcmTag: gcmTag,
        keyVersion: keyVersion,
        itemKeySalt: itemKeySalt,
        itemKeyVersion: itemKeyVersion,
      ),
    );
    return _nextPushResponse();
  }

  @override
  Future<RemoteVaultPushResult> pushDeleteBlob({
    required String deviceId,
    required String idempotencyKey,
    required String recordId,
    required int expectedVersion,
  }) async {
    deleteCalls.add(
      _DeleteCall(deviceId: deviceId, recordId: recordId, expectedVersion: expectedVersion),
    );
    return _nextPushResponse();
  }

  RemoteVaultPushResult _nextPushResponse() {
    if (_pushIndex >= _pushResponses.length) {
      return const RemoteVaultPushResult(
        code: RemoteVaultPushResultCode.applied,
        applied: true,
        idempotentReplay: false,
        conflict: false,
        appliedVersion: 1,
      );
    }
    return _pushResponses[_pushIndex++];
  }
}

class _UpsertCall {
  const _UpsertCall({
    required this.deviceId,
    required this.idempotencyKey,
    required this.recordId,
    required this.expectedVersion,
    required this.ciphertext,
    required this.nonce,
    required this.gcmTag,
    required this.keyVersion,
    this.itemKeySalt,
    this.itemKeyVersion,
  });

  final String deviceId;
  final String idempotencyKey;
  final String recordId;
  final int? expectedVersion;
  final String ciphertext;
  final String nonce;
  final String? gcmTag;
  final int keyVersion;
  final String? itemKeySalt;
  final int? itemKeyVersion;
}

class _DeleteCall {
  const _DeleteCall({
    required this.deviceId,
    required this.recordId,
    required this.expectedVersion,
  });

  final String deviceId;
  final String recordId;
  final int expectedVersion;
}

class _NetworkError implements Exception {
  const _NetworkError(this.message);
  final String message;
  @override
  String toString() => 'NetworkError: $message';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BidirectionalSyncService', () {
    test('REQ-BS-001: enqueues local upsert and triggers async push', () async {
      final storage = _InMemorySecureStorageService();
      final localStore = LocalRemoteVaultStore(storage: storage);
      final repository = _FakeRemoteVaultSyncRepository(
        pushResponses: const [
          RemoteVaultPushResult(
            code: RemoteVaultPushResultCode.applied,
            applied: true,
            idempotentReplay: false,
            conflict: false,
            appliedVersion: 1,
          ),
        ],
      );
      final events = <SyncDiagnosticEvent>[];

      final service = BidirectionalSyncService(
        repository: repository,
        localStore: localStore,
        readDeviceId: () async => 'device-1',
        uuid: const Uuid(),
        now: () => DateTime.utc(2026, 6, 11, 12, 0),
        diagnosticsHook: events.add,
      );

      await service.onLocalMutation(
        LocalVaultMutation.upsert(
          localRecordId: 'entry-1',
          ciphertext: 'cipher-a',
          nonce: 'nonce-a',
          gcmTag: 'gcmTag-a',
          keyVersion: 1,
          occurredAt: DateTime.utc(2026, 6, 11, 12, 0),
        ),
      );

      final queue = await localStore.readPushQueue(userId: 'user-1');
      expect(queue, isEmpty);
      expect(repository.upsertCalls, hasLength(1));
      expect(repository.upsertCalls.first.recordId, isNot('entry-1'));
    });

    test('REQ-BS-002: pull is throttled when within throttleInterval', () async {
      final storage = _InMemorySecureStorageService();
      final localStore = LocalRemoteVaultStore(storage: storage);
      final repository = _FakeRemoteVaultSyncRepository();
      await localStore.saveLastPullAt(
        userId: 'user-1',
        deviceId: 'device-1',
        lastPullAt: DateTime.utc(2026, 6, 11, 11, 59),
      );

      final service = BidirectionalSyncService(
        repository: repository,
        localStore: localStore,
        readDeviceId: () async => 'device-1',
        pullThrottleInterval: const Duration(minutes: 5),
        now: () => DateTime.utc(2026, 6, 11, 12, 0),
      );

      await service.onSessionStarted();

      expect(repository.afterOpIds, isEmpty);
    });

    test(
      'REQ-BS-002: pull resumes from saved cursor and persists new cursor',
      () async {
        final storage = _InMemorySecureStorageService();
        final localStore = LocalRemoteVaultStore(storage: storage);
        await localStore.saveCursor(
          userId: 'user-1',
          deviceId: 'device-1',
          cursor: 5,
        );

        final repository = _FakeRemoteVaultSyncRepository(
          pullBatches: {
            5: [
              RemoteVaultBlobChange(
                opCursor: 6,
                recordId: 'record-a',
                version: 1,
                keyVersion: 1,
                ciphertext: 'a1',
                nonce: 'na1',
                gcmTag: 'aa1',
                updatedAt: DateTime.utc(2026, 6, 11, 12, 0),
              ),
              RemoteVaultBlobChange(
                opCursor: 7,
                recordId: 'record-b',
                version: 2,
                keyVersion: 1,
                ciphertext: 'b2',
                nonce: 'nb2',
                gcmTag: 'ab2',
                updatedAt: DateTime.utc(2026, 6, 11, 12, 1),
              ),
            ],
          },
        );

        final service = BidirectionalSyncService(
          repository: repository,
          localStore: localStore,
          readDeviceId: () async => 'device-1',
          pullThrottleInterval: Duration.zero,
          now: () => DateTime.utc(2026, 6, 11, 12, 30),
        );

        await service.pullNow(force: true);

        expect(repository.afterOpIds, [5]);
        expect(
          await localStore.readCursor(userId: 'user-1', deviceId: 'device-1'),
          7,
        );
      },
    );

    test('REQ-BS-003: push applied clears the queue and persists snapshot',
        () async {
      final storage = _InMemorySecureStorageService();
      final localStore = LocalRemoteVaultStore(storage: storage);
      final repository = _FakeRemoteVaultSyncRepository(
        pushResponses: const [
          RemoteVaultPushResult(
            code: RemoteVaultPushResultCode.applied,
            applied: true,
            idempotentReplay: false,
            conflict: false,
            appliedVersion: 1,
          ),
        ],
      );

      final service = BidirectionalSyncService(
        repository: repository,
        localStore: localStore,
        readDeviceId: () async => 'device-1',
        uuid: const Uuid(),
        now: () => DateTime.utc(2026, 6, 11, 12, 0),
      );

      await service.onLocalMutation(
        LocalVaultMutation.upsert(
          localRecordId: 'entry-1',
          ciphertext: 'cipher-a',
          nonce: 'nonce-a',
          keyVersion: 1,
          occurredAt: DateTime.utc(2026, 6, 11, 12, 0),
        ),
      );

      await service.runNow();

      final queue = await localStore.readPushQueue(userId: 'user-1');
      expect(queue, isEmpty);
      final snapshots = await localStore.readSnapshots(userId: 'user-1');
      expect(snapshots.values.first.version, 1);
    });

    test('REQ-BS-003: push casConflict registers a SyncConflictRecord',
        () async {
      final storage = _InMemorySecureStorageService();
      final localStore = LocalRemoteVaultStore(storage: storage);
      final repository = _FakeRemoteVaultSyncRepository(
        pushResponses: const [
          RemoteVaultPushResult(
            code: RemoteVaultPushResultCode.casConflict,
            applied: false,
            idempotentReplay: false,
            conflict: true,
            currentVersion: 7,
            message: 'expected_version mismatch',
          ),
        ],
      );

      final service = BidirectionalSyncService(
        repository: repository,
        localStore: localStore,
        readDeviceId: () async => 'device-1',
        uuid: const Uuid(),
        now: () => DateTime.utc(2026, 6, 11, 12, 0),
      );

      await service.onLocalMutation(
        LocalVaultMutation.upsert(
          localRecordId: 'entry-1',
          ciphertext: 'cipher-a',
          nonce: 'nonce-a',
          keyVersion: 1,
          occurredAt: DateTime.utc(2026, 6, 11, 12, 0),
        ),
      );

      await service.runNow();

      final queue = await localStore.readPushQueue(userId: 'user-1');
      expect(queue, hasLength(1));
      expect(queue.first.status, PushQueueStatus.conflict);

      final pending = await localStore.readPendingConflicts(userId: 'user-1');
      expect(pending, hasLength(1));
      expect(pending.first.lastResultCode, SyncStatusCodes.casConflict);
    });

    test('REQ-BS-004: pull retry recovers on second attempt', () async {
      final storage = _InMemorySecureStorageService();
      final localStore = LocalRemoteVaultStore(storage: storage);

      final repository = _FakeRemoteVaultSyncRepository(
        pullBatches: const {0: []},
        failFirstFetchWith: const _NetworkError('connection reset'),
      );

      final service = BidirectionalSyncService(
        repository: repository,
        localStore: localStore,
        readDeviceId: () async => 'device-1',
        pullThrottleInterval: Duration.zero,
        pullMaxRetryAttempts: 2,
        pullBaseRetryDelay: const Duration(milliseconds: 1),
        delay: (_) async {},
        now: () => DateTime.utc(2026, 6, 11, 12, 0),
      );

      await service.pullNow(force: true);

      expect(repository.afterOpIds.length, 2);
    });

    test(
      'REQ-BS-AAD: v3 payloads ship their version and are only applied '
      'under the row their bound record id derives to',
      () async {
        final storage = _InMemorySecureStorageService();
        final localStore = LocalRemoteVaultStore(storage: storage);
        final pullBatches = <int, List<RemoteVaultBlobChange>>{};
        final repository = _FakeRemoteVaultSyncRepository(
          pullBatches: pullBatches,
        );
        final events = <SyncDiagnosticEvent>[];
        final applied = <RemoteVaultBlobSnapshot>[];
        final service = BidirectionalSyncService(
          repository: repository,
          localStore: localStore,
          readDeviceId: () async => 'device-1',
          pullThrottleInterval: Duration.zero,
          now: () => DateTime.utc(2026, 6, 11, 12, 0),
          diagnosticsHook: events.add,
          applyLocalSnapshots: (snapshots) async {
            applied.addAll(snapshots);
            return const ['refused-by-vault'];
          },
        );
        final wire = SyncItemPayloadCodec.encode(
          recordId: 'entry-1',
          ciphertextB64: 'Y2lwaGVy',
        );

        await service.onLocalMutation(
          LocalVaultMutation.upsert(
            localRecordId: 'entry-1',
            ciphertext: wire,
            nonce: 'bm9uY2U=',
            gcmTag: 'dGFn',
            keyVersion: 3,
            occurredAt: DateTime.utc(2026, 6, 11, 12, 0),
          ),
        );
        final pushed = repository.upsertCalls.single;
        expect(pushed.keyVersion, 3);
        expect(pushed.ciphertext, wire);
        final ownRow = pushed.recordId;
        const otherRow = '11111111-1111-4111-8111-111111111111';

        RemoteVaultBlobChange change(int cursor, String row, String text) {
          return RemoteVaultBlobChange(
            opCursor: cursor,
            recordId: row,
            version: 2,
            keyVersion: 3,
            ciphertext: text,
            nonce: 'bm9uY2U=',
            gcmTag: 'dGFn',
            updatedAt: DateTime.utc(2026, 6, 11, 12, 0),
          );
        }

        pullBatches[0] = [
          change(1, ownRow, wire),
          // Same bound ciphertext moved onto another row: rejected.
          change(2, otherRow, wire),
          // v3-tagged but no record binding on the wire: rejected.
          change(3, '22222222-2222-4222-8222-222222222222', 'Y2lwaGVy'),
        ];

        await service.pullNow(force: true);

        expect(applied.map((s) => s.recordId), ['entry-1']);
        final rejections = events
            .where((e) => e.code == SyncStatusCodes.payloadRejected)
            .map((e) => e.metadata['reason'])
            .toList();
        expect(
          rejections,
          ['record_binding_mismatch', 'malformed_binding', 'refused_by_vault'],
        );
        expect(
          await localStore.resolveLocalRecordId(
            userId: 'user-1',
            remoteRecordId: ownRow,
          ),
          'entry-1',
        );
      },
    );

    test(
      'REQ-BS-ITEMKEY: a v4 upsert ships its item key salt and the applied '
      'snapshot keeps it',
      () async {
        final storage = _InMemorySecureStorageService();
        final localStore = LocalRemoteVaultStore(storage: storage);
        final repository = _FakeRemoteVaultSyncRepository(
          pushResponses: const [
            RemoteVaultPushResult(
              code: RemoteVaultPushResultCode.applied,
              applied: true,
              idempotentReplay: false,
              conflict: false,
              appliedVersion: 2,
            ),
          ],
        );
        final service = BidirectionalSyncService(
          repository: repository,
          localStore: localStore,
          readDeviceId: () async => 'device-1',
          now: () => DateTime.utc(2026, 6, 11, 12, 0),
        );

        await service.onLocalMutation(
          LocalVaultMutation.upsert(
            localRecordId: 'entry-1',
            ciphertext: SyncItemPayloadCodec.encode(
              recordId: 'entry-1',
              ciphertextB64: 'Y2lwaGVy',
            ),
            nonce: 'bm9uY2U=',
            gcmTag: 'dGFn',
            keyVersion: SyncItemPayloadCodec.itemKeyPayloadVersion,
            itemKeySalt: 'c2FsdC1ieC1ieQ==',
            itemKeyVersion: 1,
            occurredAt: DateTime.utc(2026, 6, 11, 12, 0),
          ),
        );

        final pushed = repository.upsertCalls.single;
        expect(pushed.keyVersion, 4);
        expect(pushed.itemKeySalt, 'c2FsdC1ieC1ieQ==');
        expect(pushed.itemKeyVersion, 1);

        final snapshot = (await localStore.readSnapshots(userId: 'user-1'))
            .values
            .single;
        expect(snapshot.keyVersion, 4);
        expect(snapshot.itemKeySalt, 'c2FsdC1ieC1ieQ==');
        expect(snapshot.itemKeyVersion, 1);
      },
    );

    test(
      'REQ-BS-ITEMKEY: a pulled v4 change reaches the vault with its salt',
      () async {
        final storage = _InMemorySecureStorageService();
        final localStore = LocalRemoteVaultStore(storage: storage);
        final wire = SyncItemPayloadCodec.encode(
          recordId: _v4RecordId,
          ciphertextB64: 'Y2lwaGVy',
        );
        const row = _v4RecordId;
        final repository = _FakeRemoteVaultSyncRepository(
          pullBatches: {
            0: [
              RemoteVaultBlobChange(
                opCursor: 1,
                recordId: row,
                version: 2,
                keyVersion: SyncItemPayloadCodec.itemKeyPayloadVersion,
                ciphertext: wire,
                nonce: 'bm9uY2U=',
                gcmTag: 'dGFn',
                itemKeySalt: 'c2FsdC1ieC1ieQ==',
                itemKeyVersion: 1,
                updatedAt: DateTime.utc(2026, 6, 11, 12, 0),
              ),
            ],
          },
        );
        final applied = <RemoteVaultBlobSnapshot>[];
        final service = BidirectionalSyncService(
          repository: repository,
          localStore: localStore,
          readDeviceId: () async => 'device-1',
          pullThrottleInterval: Duration.zero,
          now: () => DateTime.utc(2026, 6, 11, 12, 0),
          applyLocalSnapshots: (snapshots) async {
            applied.addAll(snapshots);
            return const <String>[];
          },
        );

        await service.pullNow(force: true);

        expect(applied, hasLength(1));
        expect(applied.single.recordId, _v4RecordId);
        expect(applied.single.ciphertext, wire);
        expect(applied.single.itemKeySalt, 'c2FsdC1ieC1ieQ==');
        expect(applied.single.itemKeyVersion, 1);
        final snapshot = (await localStore.readSnapshots(userId: 'user-1'))
            .values
            .single;
        expect(snapshot.itemKeySalt, 'c2FsdC1ieC1ieQ==');
        expect(snapshot.itemKeyVersion, 1);
      },
    );

    test(
      'REQ-BS-ITEMKEY: a conflict record keeps the salt of the payload it '
      'queued',
      () async {
        final storage = _InMemorySecureStorageService();
        final localStore = LocalRemoteVaultStore(storage: storage);
        final repository = _FakeRemoteVaultSyncRepository(
          pushResponses: const [
            RemoteVaultPushResult(
              code: RemoteVaultPushResultCode.casConflict,
              applied: false,
              idempotentReplay: false,
              conflict: true,
              currentVersion: 7,
              message: 'expected_version mismatch',
            ),
          ],
        );
        final service = BidirectionalSyncService(
          repository: repository,
          localStore: localStore,
          readDeviceId: () async => 'device-1',
          now: () => DateTime.utc(2026, 6, 11, 12, 0),
        );

        await service.onLocalMutation(
          LocalVaultMutation.upsert(
            localRecordId: _v4RecordId,
            ciphertext: SyncItemPayloadCodec.encode(
              recordId: _v4RecordId,
              ciphertextB64: 'Y2lwaGVy',
            ),
            nonce: 'bm9uY2U=',
            gcmTag: 'dGFn',
            keyVersion: SyncItemPayloadCodec.itemKeyPayloadVersion,
            itemKeySalt: 'c2FsdC1ieC1ieQ==',
            itemKeyVersion: 1,
            occurredAt: DateTime.utc(2026, 6, 11, 12, 0),
          ),
        );

        final pending = await localStore.readPendingConflicts(userId: 'user-1');
        expect(pending, hasLength(1));
        expect(pending.single.localSnapshot!.itemKeySalt, 'c2FsdC1ieC1ieQ==');
        expect(pending.single.localSnapshot!.itemKeyVersion, 1);
        final queued = (await localStore.readPushQueue(userId: 'user-1')).single;
        expect(queued.itemKeySalt, 'c2FsdC1ieC1ieQ==');
        expect(queued.itemKeyVersion, 1);
      },
    );
  });
}
