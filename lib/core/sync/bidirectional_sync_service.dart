// ignore_for_file: depend_on_referenced_packages
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import 'local_remote_vault_store.dart';
import 'local_vault_mutation.dart';
import 'remote_vault_blob_change.dart';
import 'remote_vault_sync_repository.dart';
import 'sync_conflict.dart';
import 'sync_item_payload_codec.dart';
import 'sync_runtime_hardening.dart';
import 'vault_change_signal.dart';

/// Callback that hands resolved remote snapshots to the vault writer.
/// Returns the record ids the writer refused (invalid, downgraded or
/// unauthenticated payloads) so the sync layer can report them; `null`
/// or an empty iterable means everything was applied.
typedef ApplyLocalSnapshots =
    Future<Iterable<String>?> Function(
      Iterable<RemoteVaultBlobSnapshot> snapshots,
    );

/// Bidirectional sync coordinator: single owner of the local cursor
/// (pull) and the local push queue (push). Replaces the historical
/// split `IncrementalPullSyncService` + `IncrementalPushSyncService`
/// pair (removed in T5 of ADR-004) without changing the on-disk
/// contract (queue items, cursor, conflict records are all the same
/// shape).
///
/// Lifecycle: [onSessionStarted] is the bootstrap hook (called once per
/// session). [onAppResumed] is the foreground-resume hook. [runNow]
/// triggers an explicit push drain (used by the conflict resolver
/// after a `keepLocal` decision). [pullNow] triggers an explicit pull
/// (used by tests and by future background triggers).
///
/// Implements [LocalVaultMutationSink] so the local vault repository
/// can notify the service of upserts/deletes as they happen.
class BidirectionalSyncService implements LocalVaultMutationSink {
  /// Builds a [BidirectionalSyncService]. Most callers should rely on
  /// the defaults; the optional [uuid] / [delay] / [now] are for
  /// tests, and the optional [applyLocalSnapshots] callback is
  /// what feeds the vault writer during a pull (see
  /// [ApplyLocalSnapshots]).
  BidirectionalSyncService({
    required RemoteVaultSyncRepository repository,
    required LocalRemoteVaultStore localStore,
    required Future<String> Function() readDeviceId,
    Uuid? uuid,
    int pullBatchSize = 200,
    Duration pullThrottleInterval = const Duration(minutes: 2),
    int pullMaxRetryAttempts = 2,
    Duration pullBaseRetryDelay = const Duration(seconds: 1),
    int pushMaxItemsPerRun = 20,
    Duration pushBaseBackoff = const Duration(seconds: 2),
    Duration pushMaxBackoff = const Duration(minutes: 2),
    this.diagnosticsHook,
    VaultChangeSignal? vaultChanges,
    ApplyLocalSnapshots? applyLocalSnapshots,
    Future<void> Function(Duration delay)? delay,
    DateTime Function()? now,
  }) : _repository = repository,
       _localStore = localStore,
       _readDeviceId = readDeviceId,
       _uuid = uuid ?? const Uuid(),
       _pullBatchSize = pullBatchSize,
       _pullThrottleInterval = pullThrottleInterval,
       _pullMaxRetryAttempts = pullMaxRetryAttempts,
       _pullBaseRetryDelay = pullBaseRetryDelay,
       _pushMaxItemsPerRun = pushMaxItemsPerRun,
       _pushBaseBackoff = pushBaseBackoff,
       _pushMaxBackoff = pushMaxBackoff,
       _applyLocalSnapshots = applyLocalSnapshots,
       _vaultChanges = vaultChanges,
       _delay = delay ?? Future<void>.delayed,
       _now = now ?? DateTime.now;

  final RemoteVaultSyncRepository _repository;
  final LocalRemoteVaultStore _localStore;
  final Future<String> Function() _readDeviceId;
  final Uuid _uuid;
  final int _pullBatchSize;
  final Duration _pullThrottleInterval;
  final int _pullMaxRetryAttempts;
  final Duration _pullBaseRetryDelay;
  final int _pushMaxItemsPerRun;
  final Duration _pushBaseBackoff;
  final Duration _pushMaxBackoff;
  final ApplyLocalSnapshots? _applyLocalSnapshots;
  final Future<void> Function(Duration delay) _delay;
  final DateTime Function() _now;

  /// Optional hook that receives a [SyncDiagnosticEvent] for every
  /// pull/push failure. Wired by the lifecycle to surface sync
  /// issues in the settings screen.
  final SyncDiagnosticsHook? diagnosticsHook;

  /// Optional signal published after a pull actually wrote remote
  /// snapshots into the local vault, so the UI can re-read the
  /// repository without any user gesture. `null` keeps the service
  /// silent (tests, builds without a UI).
  ///
  /// Publishing is deliberately coarse — one event per pull cycle, no
  /// item data — and never happens for an empty or fully refused batch,
  /// so a no-op pull cannot trigger a UI reload. Private on purpose: it
  /// is an outbound notification, not part of the service's read
  /// surface, so fakes implementing this class do not have to model it.
  final VaultChangeSignal? _vaultChanges;

  bool _pushRunning = false;
  bool _pushRerunRequested = false;

  /// Bootstrap hook (called once per session). Runs a pull and a
  /// push drain in sequence.
  Future<void> onSessionStarted() async {
    await pullNow();
    await _triggerPush();
  }

  /// Foreground-resume hook. Runs a pull and a push drain in
  /// sequence; the pull is subject to the [pullThrottleInterval]
  /// gate so a rapid foreground transition does not hammer the
  /// backend.
  Future<void> onAppResumed() async {
    await pullNow();
    await _triggerPush();
  }

  /// Triggers a pull cycle. Pass [force] = true to bypass the
  /// throttle window (used by tests and by future background
  /// triggers).
  Future<void> pullNow({bool force = false}) async {
    await _runPull(force: force);
  }

  /// Triggers an explicit push drain. Used by the conflict
  /// resolver after a `keepLocal` decision to immediately re-attempt
  /// the just-rebased item instead of waiting for the next
  /// pull/push trigger.
  Future<void> runNow() async {
    await _triggerPush();
  }

  @override
  Future<void> onLocalMutation(LocalVaultMutation mutation) async {
    final userId = await _repository.readCurrentUserId();
    if (userId == null || userId.isEmpty) {
      return;
    }

    final remoteRecordId = _remoteRecordIdFor(
      userId: userId,
      localRecordId: mutation.localRecordId,
    );
    await _localStore.saveRecordIdMapping(
      userId: userId,
      localRecordId: mutation.localRecordId,
      remoteRecordId: remoteRecordId,
    );
    await _localStore.enqueuePushMutation(
      userId: userId,
      item: PushQueueItem.fromMutation(
        opId: _uuid.v4(),
        remoteRecordId: remoteRecordId,
        mutation: mutation,
      ),
    );
    await _triggerPush();
  }

  Future<void> _runPull({required bool force}) async {
    final userId = await _repository.readCurrentUserId();
    if (userId == null || userId.isEmpty) {
      return;
    }

    final deviceId = await _readDeviceId();
    if (deviceId.isEmpty) {
      return;
    }

    if (!force) {
      final lastPullAt = await _localStore.readLastPullAt(
        userId: userId,
        deviceId: deviceId,
      );
      if (lastPullAt != null &&
          _now().difference(lastPullAt) < _pullThrottleInterval) {
        return;
      }
    }

    var cursor = await _localStore.readCursor(
      userId: userId,
      deviceId: deviceId,
    );
    var appliedAnyChange = false;

    while (true) {
      final changes = await _fetchWithRetry(afterOpId: cursor);
      if (changes == null) {
        return;
      }

      if (changes.isEmpty) {
        break;
      }

      cursor = changes.last.opCursor;
      await _localStore.applyChanges(
        userId: userId,
        deviceId: deviceId,
        changes: changes,
        newCursor: cursor,
      );
      final applyLocalSnapshots = _applyLocalSnapshots;
      if (applyLocalSnapshots != null) {
        final snapshots = await _resolveSnapshotIds(
          userId: userId,
          changes: changes,
        );
        final refused =
            (await applyLocalSnapshots(snapshots))?.toList(growable: false) ??
            const <String>[];
        for (final recordId in refused) {
          _reportRejectedPayload(
            recordId: recordId,
            reason: 'refused_by_vault',
          );
        }
        // Only a batch that left something written counts as a change: an
        // empty pull or one the vault refused entirely did not touch it.
        if (snapshots.length > refused.length) {
          appliedAnyChange = true;
        }
      }

      if (changes.length < _pullBatchSize) {
        break;
      }
    }

    await _localStore.saveLastPullAt(
      userId: userId,
      deviceId: deviceId,
      lastPullAt: _now().toUtc(),
    );

    // Published last, so a listener that re-reads the repository sees both
    // the applied snapshots and the advanced cursor.
    if (appliedAnyChange) {
      _vaultChanges?.notifyVaultChanged(origin: VaultChangeOrigin.pull);
    }
  }

  /// Maps each pulled change to the local record id the vault writer
  /// should use.
  ///
  /// Record-bound (v3) payloads carry their bound local record id in
  /// the wire ciphertext (see [SyncItemPayloadCodec]). That id is only
  /// trusted when it derives to the remote row the change arrived
  /// under; otherwise the ciphertext was moved between rows (or forged)
  /// and the change is dropped and reported instead of applied. A
  /// verified binding also records the remote -> local id mapping so
  /// later tombstones for the row resolve to the right local item.
  Future<List<RemoteVaultBlobSnapshot>> _resolveSnapshotIds({
    required String userId,
    required List<RemoteVaultBlobChange> changes,
  }) async {
    final resolved = <RemoteVaultBlobSnapshot>[];
    for (final change in changes) {
      final base = RemoteVaultBlobSnapshot.fromChange(change);
      if (!change.isTombstone &&
          change.keyVersion >= SyncItemPayloadCodec.boundPayloadVersion) {
        final bound = SyncItemPayloadCodec.decode(change.ciphertext);
        if (bound == null) {
          _reportRejectedPayload(
            recordId: change.recordId,
            reason: 'malformed_binding',
          );
          continue;
        }
        final expectedRemoteId = _remoteRecordIdFor(
          userId: userId,
          localRecordId: bound.recordId,
        );
        if (expectedRemoteId != change.recordId) {
          _reportRejectedPayload(
            recordId: change.recordId,
            reason: 'record_binding_mismatch',
          );
          continue;
        }
        await _localStore.saveRecordIdMapping(
          userId: userId,
          localRecordId: bound.recordId,
          remoteRecordId: change.recordId,
        );
        resolved.add(_withRecordId(base, bound.recordId));
        continue;
      }

      final localId = await _localStore.resolveLocalRecordId(
        userId: userId,
        remoteRecordId: change.recordId,
      );
      resolved.add(
        localId == base.recordId ? base : _withRecordId(base, localId),
      );
    }

    return resolved;
  }

  RemoteVaultBlobSnapshot _withRecordId(
    RemoteVaultBlobSnapshot base,
    String recordId,
  ) {
    return RemoteVaultBlobSnapshot(
      recordId: recordId,
      version: base.version,
      keyVersion: base.keyVersion,
      ciphertext: base.ciphertext,
      nonce: base.nonce,
      gcmTag: base.gcmTag,
      itemKeySalt: base.itemKeySalt,
      itemKeyVersion: base.itemKeyVersion,
      deletedAt: base.deletedAt,
      updatedAt: base.updatedAt,
    );
  }

  void _reportRejectedPayload({
    required String recordId,
    required String reason,
  }) {
    const code = SyncStatusCodes.payloadRejected;
    emitSyncDiagnostic(
      scope: 'pull',
      operation: 'apply_snapshot',
      code: code,
      message: syncMessageForCode(code),
      retriable: false,
      timestamp: _now(),
      hook: diagnosticsHook,
      metadata: {'recordId': recordId, 'reason': reason},
    );
    syncDebugPrint('[sync][pull] rejected payload record=$recordId ($reason)');
  }

  Future<List<RemoteVaultBlobChange>?> _fetchWithRetry({
    required int afterOpId,
  }) async {
    if (_pullMaxRetryAttempts < 1) {
      return null;
    }

    Object? lastError;
    for (var attempt = 1; attempt <= _pullMaxRetryAttempts; attempt += 1) {
      try {
        return await _repository.fetchChangesSince(
          afterOpId: afterOpId,
          limit: _pullBatchSize,
        );
      } catch (error) {
        lastError = error;
        final disposition = classifySyncError(error);
        final code = syncErrorCode(error);
        final message = syncMessageForCode(
          code,
          fallback:
              'No se pudo obtener cambios remotos para el cursor $afterOpId.',
        );
        final retriable = disposition == SyncErrorDisposition.transient;
        emitSyncDiagnostic(
          scope: 'pull',
          operation: 'fetch_changes',
          code: code,
          message: message,
          retriable: retriable,
          timestamp: _now(),
          hook: diagnosticsHook,
          attempt: attempt,
          maxAttempts: _pullMaxRetryAttempts,
          error: error,
          metadata: {'afterOpId': afterOpId},
        );
        syncDebugPrint(
          '[sync][pull] fetch after=$afterOpId attempt=$attempt/$_pullMaxRetryAttempts failed: $error',
        );
        if (attempt >= _pullMaxRetryAttempts || !retriable) {
          break;
        }

        final delayMs = _pullBaseRetryDelay.inMilliseconds * (1 << (attempt - 1));
        await _delay(Duration(milliseconds: delayMs));
      }
    }

    syncDebugPrint(
      '[sync][pull] aborting pull after $_pullMaxRetryAttempts attempts (after=$afterOpId): ${lastError ?? 'unknown error'}',
    );
    return null;
  }

  Future<void> _triggerPush() async {
    if (_pushRunning) {
      _pushRerunRequested = true;
      return;
    }

    _pushRunning = true;
    try {
      do {
        _pushRerunRequested = false;
        await _runPushOnce();
      } while (_pushRerunRequested);
    } finally {
      _pushRunning = false;
    }
  }

  Future<void> _runPushOnce() async {
    final userId = await _repository.readCurrentUserId();
    if (userId == null || userId.isEmpty) {
      return;
    }

    final deviceId = await _readDeviceId();
    if (deviceId.isEmpty) {
      return;
    }

    final queue = await _localStore.readPushQueue(userId: userId);
    if (queue.isEmpty) {
      return;
    }

    final now = _now().toUtc();
    var processed = 0;
    var index = 0;
    while (index < queue.length && processed < _pushMaxItemsPerRun) {
      final item = queue[index];
      if (!_isDispatchable(item, now: now)) {
        index += 1;
        continue;
      }

      final prepared = await _prepareForDispatch(userId: userId, item: item);
      if (prepared.status == PushQueueStatus.failed) {
        queue[index] = prepared;
        processed += 1;
        index += 1;
        continue;
      }

      queue[index] = prepared;
      final result = await _dispatch(
        userId: userId,
        deviceId: deviceId,
        item: prepared,
      );
      if (result.removeFromQueue) {
        queue.removeAt(index);
      } else {
        queue[index] = result.item;
        index += 1;
      }

      if (result.appliedVersion != null) {
        await _updateSnapshotFromResult(
          userId: userId,
          item: prepared,
          appliedVersion: result.appliedVersion!,
          deletedAt: result.deletedAt,
        );
      }

      processed += 1;
    }

    await _localStore.savePushQueue(userId: userId, items: queue);
  }

  bool _isDispatchable(PushQueueItem item, {required DateTime now}) {
    if (item.status == PushQueueStatus.failed ||
        item.status == PushQueueStatus.conflict) {
      return false;
    }

    final nextAttemptAt = item.nextAttemptAt;
    if (nextAttemptAt != null && now.isBefore(nextAttemptAt)) {
      return false;
    }

    return true;
  }

  Future<PushQueueItem> _prepareForDispatch({
    required String userId,
    required PushQueueItem item,
  }) async {
    final updatedAt = _now().toUtc();
    var expectedVersion = item.expectedVersion;
    if (expectedVersion == null) {
      final snapshot = await _localStore.readSnapshot(
        userId: userId,
        recordId: item.remoteRecordId,
      );
      expectedVersion = snapshot?.version;
    }

    if (item.kind == PushQueueOperationKind.delete && expectedVersion == null) {
      return item.copyWith(
        status: PushQueueStatus.failed,
        expectedVersion: expectedVersion,
        lastResultCode: 'local_missing_expected_version',
        lastMessage: 'Delete requires known remote version.',
        updatedAt: updatedAt,
      );
    }

    if (item.idempotencyKey == null || item.idempotencyKey!.isEmpty) {
      return item.copyWith(
        status: PushQueueStatus.inFlight,
        expectedVersion: expectedVersion,
        idempotencyKey: _uuid.v4(),
        attemptCount: item.attemptCount + 1,
        retryCount: 0,
        nextAttemptAt: null,
        updatedAt: updatedAt,
      );
    }

    return item.copyWith(
      status: PushQueueStatus.inFlight,
      expectedVersion: expectedVersion,
      nextAttemptAt: null,
      updatedAt: updatedAt,
    );
  }

  Future<_DispatchResult> _dispatch({
    required String userId,
    required String deviceId,
    required PushQueueItem item,
  }) async {
    try {
      final response = await _sendToRemote(deviceId: deviceId, item: item);
      // 'await' is required here: without it the Future escapes the try
      // block and an async failure inside _interpretResponse would bypass
      // the catch below instead of being classified as a sync error.
      return await _interpretResponse(
        userId: userId,
        item: item,
        response: response,
      );
    } catch (error) {
      final disposition = classifySyncError(error);
      final code = syncErrorCode(error);
      final message = syncMessageForCode(
        code,
        fallback: 'Push failed before receiving RPC result.',
      );
      if (disposition == SyncErrorDisposition.definitive) {
        emitSyncDiagnostic(
          scope: 'push',
          operation: 'dispatch',
          code: code,
          message: message,
          retriable: false,
          timestamp: _now(),
          hook: diagnosticsHook,
          error: error,
        );
        return _DispatchResult(
          item: item.copyWith(
            status: PushQueueStatus.failed,
            lastResultCode: code,
            lastMessage: message,
            nextAttemptAt: null,
            updatedAt: _now().toUtc(),
          ),
          removeFromQueue: false,
        );
      }

      final retryCount = item.retryCount + 1;
      emitSyncDiagnostic(
        scope: 'push',
        operation: 'dispatch',
        code: code,
        message: message,
        retriable: true,
        timestamp: _now(),
        attempt: retryCount,
        hook: diagnosticsHook,
        error: error,
      );
      return _DispatchResult(
        item: item.copyWith(
          status: PushQueueStatus.retry,
          retryCount: retryCount,
          nextAttemptAt: _now().toUtc().add(_backoffFor(retryCount)),
          lastResultCode: code,
          lastMessage: message,
          updatedAt: _now().toUtc(),
        ),
        removeFromQueue: false,
      );
    }
  }

  Future<RemoteVaultPushResult> _sendToRemote({
    required String deviceId,
    required PushQueueItem item,
  }) {
    final idempotencyKey = item.idempotencyKey;
    if (idempotencyKey == null || idempotencyKey.isEmpty) {
      throw StateError('Missing idempotency key for in-flight item.');
    }

    return switch (item.kind) {
      PushQueueOperationKind.upsert => _repository.pushUpsertBlob(
        deviceId: deviceId,
        idempotencyKey: idempotencyKey,
        recordId: item.remoteRecordId,
        expectedVersion: item.expectedVersion,
        ciphertext: item.ciphertext ?? '',
        nonce: item.nonce ?? '',
        gcmTag: item.gcmTag,
        keyVersion: item.keyVersion ?? 1,
        itemKeySalt: item.itemKeySalt,
        itemKeyVersion: item.itemKeyVersion,
      ),
      PushQueueOperationKind.delete => _repository.pushDeleteBlob(
        deviceId: deviceId,
        idempotencyKey: idempotencyKey,
        recordId: item.remoteRecordId,
        expectedVersion: item.expectedVersion ?? -1,
      ),
    };
  }

  Future<_DispatchResult> _interpretResponse({
    required String userId,
    required PushQueueItem item,
    required RemoteVaultPushResult response,
  }) async {
    final updatedAt = _now().toUtc();
    if (response.code == RemoteVaultPushResultCode.applied ||
        response.code == RemoteVaultPushResultCode.idempotentReplay) {
      return _DispatchResult(
        item: item,
        removeFromQueue: true,
        appliedVersion: response.appliedVersion ?? response.currentVersion,
        deletedAt: response.deletedAt,
      );
    }

    if (response.code == RemoteVaultPushResultCode.casConflict) {
      await _registerConflict(userId: userId, item: item, response: response);
      const code = SyncStatusCodes.casConflict;
      final message = syncMessageForCode(code, fallback: response.message);
      emitSyncDiagnostic(
        scope: 'push',
        operation: 'dispatch',
        code: code,
        message: message,
        retriable: false,
        timestamp: _now(),
        hook: diagnosticsHook,
      );
      return _DispatchResult(
        item: item.copyWith(
          status: PushQueueStatus.conflict,
          lastResultCode: code,
          lastMessage: message,
          nextAttemptAt: null,
          updatedAt: updatedAt,
        ),
        removeFromQueue: false,
      );
    }

    if (response.code == RemoteVaultPushResultCode.idempotencyMismatch) {
      const code = SyncStatusCodes.idempotencyMismatch;
      final message = syncMessageForCode(code, fallback: response.message);
      emitSyncDiagnostic(
        scope: 'push',
        operation: 'dispatch',
        code: code,
        message: message,
        retriable: false,
        timestamp: _now(),
        hook: diagnosticsHook,
      );
      return _DispatchResult(
        item: item.copyWith(
          status: PushQueueStatus.failed,
          lastResultCode: code,
          lastMessage: message,
          nextAttemptAt: null,
          updatedAt: updatedAt,
        ),
        removeFromQueue: false,
      );
    }

    final unknownCode = _codeForUnknownResponse(response);
    final unknownMessage = syncMessageForCode(
      unknownCode,
      fallback: response.message,
    );
    if (unknownCode == SyncStatusCodes.revokedSessionOrDevice) {
      emitSyncDiagnostic(
        scope: 'push',
        operation: 'dispatch',
        code: unknownCode,
        message: unknownMessage,
        retriable: false,
        timestamp: _now(),
        hook: diagnosticsHook,
      );
      return _DispatchResult(
        item: item.copyWith(
          status: PushQueueStatus.failed,
          lastResultCode: unknownCode,
          lastMessage: unknownMessage,
          nextAttemptAt: null,
          updatedAt: updatedAt,
        ),
        removeFromQueue: false,
      );
    }

    final retryCount = item.retryCount + 1;
    emitSyncDiagnostic(
      scope: 'push',
      operation: 'dispatch',
      code: unknownCode,
      message: unknownMessage,
      retriable: true,
      timestamp: _now(),
      attempt: retryCount,
      hook: diagnosticsHook,
    );
    return _DispatchResult(
      item: item.copyWith(
        status: PushQueueStatus.retry,
        retryCount: retryCount,
        nextAttemptAt: _now().toUtc().add(_backoffFor(retryCount)),
        lastResultCode: unknownCode,
        lastMessage: unknownMessage,
        updatedAt: updatedAt,
      ),
      removeFromQueue: false,
    );
  }

  String _codeForUnknownResponse(RemoteVaultPushResult response) {
    final message = (response.message ?? '').toLowerCase();
    if (message.contains('revoked')) {
      return SyncStatusCodes.revokedSessionOrDevice;
    }
    if (message.contains('offline') || message.contains('network')) {
      return SyncStatusCodes.offlineNetworkError;
    }
    return SyncStatusCodes.unknown;
  }

  Future<void> _registerConflict({
    required String userId,
    required PushQueueItem item,
    required RemoteVaultPushResult response,
  }) async {
    final now = _now().toUtc();
    final snapshot = await _localStore.readSnapshot(
      userId: userId,
      recordId: item.remoteRecordId,
    );

    await _localStore.upsertPendingConflict(
      userId: userId,
      conflict: SyncConflictRecord(
        id: _uuid.v4(),
        opId: item.opId,
        localRecordId: item.localRecordId,
        remoteRecordId: item.remoteRecordId,
        kind: item.kind == PushQueueOperationKind.upsert
            ? SyncConflictOperationKind.upsert
            : SyncConflictOperationKind.delete,
        createdAt: now,
        updatedAt: now,
        lastResultCode: SyncStatusCodes.casConflict,
        message: syncMessageForCode(
          SyncStatusCodes.casConflict,
          fallback: response.message,
        ),
        expectedVersion: item.expectedVersion,
        currentVersion: response.currentVersion,
        localSnapshot: SyncConflictSnapshot(
          version: item.expectedVersion,
          keyVersion: item.keyVersion,
          ciphertext: item.ciphertext,
          nonce: item.nonce,
          gcmTag: item.gcmTag,
          itemKeySalt: item.itemKeySalt,
          itemKeyVersion: item.itemKeyVersion,
          updatedAt: item.updatedAt,
        ),
        remoteSnapshot: snapshot == null
            ? SyncConflictSnapshot(
                version: response.currentVersion,
                updatedAt: now,
              )
            : SyncConflictSnapshot(
                version: response.currentVersion ?? snapshot.version,
                keyVersion: snapshot.keyVersion,
                ciphertext: snapshot.ciphertext,
                nonce: snapshot.nonce,
                gcmTag: snapshot.gcmTag,
                itemKeySalt: snapshot.itemKeySalt,
                itemKeyVersion: snapshot.itemKeyVersion,
                deletedAt: snapshot.deletedAt,
                updatedAt: snapshot.updatedAt,
              ),
      ),
    );
  }

  Future<void> _updateSnapshotFromResult({
    required String userId,
    required PushQueueItem item,
    required int appliedVersion,
    required DateTime? deletedAt,
  }) {
    return _localStore.saveSnapshot(
      userId: userId,
      snapshot: RemoteVaultBlobSnapshot(
        recordId: item.remoteRecordId,
        version: appliedVersion,
        keyVersion: item.keyVersion ?? 1,
        ciphertext: deletedAt == null ? item.ciphertext : null,
        nonce: deletedAt == null ? item.nonce : null,
        gcmTag: deletedAt == null ? item.gcmTag : null,
        itemKeySalt: deletedAt == null ? item.itemKeySalt : null,
        itemKeyVersion: deletedAt == null ? item.itemKeyVersion : null,
        deletedAt: deletedAt,
        updatedAt: _now().toUtc(),
      ),
    );
  }

  Duration _backoffFor(int retryCount) {
    final multiplier = 1 << (retryCount - 1);
    final candidateMs = _pushBaseBackoff.inMilliseconds * multiplier;
    final boundedMs = candidateMs.clamp(
      _pushBaseBackoff.inMilliseconds,
      _pushMaxBackoff.inMilliseconds,
    );
    return Duration(milliseconds: boundedMs);
  }

  String _remoteRecordIdFor({
    required String userId,
    required String localRecordId,
  }) {
    final normalized = localRecordId.trim().toLowerCase();
    if (_uuidRegex.hasMatch(normalized)) {
      return normalized;
    }

    final source = '$userId:$localRecordId';
    final bytes = List<int>.filled(16, 0);
    for (var index = 0; index < source.length; index++) {
      final codeUnit = source.codeUnitAt(index);
      final slot = index % 16;
      bytes[slot] = (bytes[slot] + codeUnit + slot) & 0xFF;
    }

    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    return _toUuid(bytes);
  }

  String _toUuid(List<int> bytes) {
    String h(int value) => value.toRadixString(16).padLeft(2, '0');
    final b = bytes.map(h).toList(growable: false);
    return '${b[0]}${b[1]}${b[2]}${b[3]}-${b[4]}${b[5]}-${b[6]}${b[7]}-${b[8]}${b[9]}-${b[10]}${b[11]}${b[12]}${b[13]}${b[14]}${b[15]}';
  }

  static final _uuidRegex = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
}

@immutable
class _DispatchResult {
  const _DispatchResult({
    required this.item,
    required this.removeFromQueue,
    this.appliedVersion,
    this.deletedAt,
  });

  final PushQueueItem item;
  final bool removeFromQueue;
  final int? appliedVersion;
  final DateTime? deletedAt;
}
