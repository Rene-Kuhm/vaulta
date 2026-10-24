import 'local_remote_vault_store.dart';
import 'remote_vault_sync_repository.dart';
import 'sync_conflict.dart';
import 'sync_runtime_hardening.dart';

/// Outcome of a user-driven conflict resolution. Returned by
/// [SyncConflictResolver.resolve] and rendered by the
/// conflict-resolver UI.
class SyncConflictResolveResult {
  /// Builds a [SyncConflictResolveResult]. [ok] is true when the
  /// resolution was applied; [message] is the localized, user-facing
  /// outcome (suitable for a toast or a status line).
  const SyncConflictResolveResult({required this.ok, required this.message});

  /// True when the resolution was applied.
  final bool ok;

  /// Localized, user-facing outcome of the resolution.
  final String message;
}

/// Orchestrates the user side of the conflict resolution flow:
/// reads pending conflicts from the local log, applies the user's
/// choice (keep local / keep remote), updates the push queue
/// accordingly, and removes the resolved conflict.
///
/// What this resolver does NOT do: detect new conflicts (that's
/// the push service's job) or fetch remote snapshots (the push
/// service attaches them when registering a conflict).
class SyncConflictResolver {
  /// Builds a [SyncConflictResolver]. [repository] is needed to
  /// resolve the current user id; [localStore] is the conflict log
  /// + push queue; [triggerPushSync] is an optional callback invoked
  /// after a `keepLocal` resolution to drain the re-queued item
  /// immediately instead of waiting for the next pull/push trigger.
  SyncConflictResolver({
    required RemoteVaultSyncRepository repository,
    required LocalRemoteVaultStore localStore,
    Future<void> Function()? triggerPushSync,
    DateTime Function()? now,
  }) : _repository = repository,
       _localStore = localStore,
       _triggerPushSync = triggerPushSync,
       _now = now ?? DateTime.now;

  final RemoteVaultSyncRepository _repository;
  final LocalRemoteVaultStore _localStore;
  final Future<void> Function()? _triggerPushSync;
  final DateTime Function() _now;

  /// Returns the current user's pending conflicts, sorted newest
  /// first. Returns an empty list when the user is unauthenticated
  /// or there are no conflicts.
  Future<List<SyncConflictRecord>> readPendingConflicts() async {
    final userId = await _readUserId();
    if (userId == null) {
      return const [];
    }

    final conflicts = await _localStore.readPendingConflicts(userId: userId);
    conflicts.sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return conflicts;
  }

  /// Applies the user's [resolution] to the conflict identified by
  /// [conflictId]. For [SyncConflictResolution.keepRemote] the local
  /// mutation is dropped and the remote version is accepted. For
  /// [SyncConflictResolution.keepLocal] the push queue item is
  /// rebuilt with the remote version as the new `expectedVersion`
  /// (so the next push RPC passes CAS) and the push service is
  /// triggered to drain it immediately.
  Future<SyncConflictResolveResult> resolve({
    required String conflictId,
    required SyncConflictResolution resolution,
  }) async {
    final userId = await _readUserId();
    if (userId == null) {
      syncDebugPrint('[sync][conflict] resolve failed: unauthenticated user.');
      return const SyncConflictResolveResult(
        ok: false,
        message:
            'Sync conflict could not be resolved because the user is not authenticated.',
      );
    }

    final conflicts = await _localStore.readPendingConflicts(userId: userId);
    final conflictIndex = conflicts.indexWhere((item) => item.id == conflictId);
    if (conflictIndex == -1) {
      syncDebugPrint(
        '[sync][conflict] conflict=$conflictId missing before resolve.',
      );
      return const SyncConflictResolveResult(
        ok: false,
        message: 'Sync conflict is already resolved or missing.',
      );
    }

    final conflict = conflicts[conflictIndex];
    final queue = await _localStore.readPushQueue(userId: userId);
    final queueIndex = queue.indexWhere((item) => item.opId == conflict.opId);

    if (resolution == SyncConflictResolution.keepRemote) {
      if (queueIndex != -1) {
        queue.removeAt(queueIndex);
        await _localStore.savePushQueue(userId: userId, items: queue);
      }
      await _localStore.removePendingConflict(
        userId: userId,
        conflictId: conflict.id,
      );
      syncDebugPrint(
        '[sync][conflict] conflict=${conflict.id} resolved as keep_remote.',
      );
      return const SyncConflictResolveResult(
        ok: true,
        message:
            'Remote version accepted. Local mutation was discarded safely.',
      );
    }

    if (queueIndex == -1) {
      syncDebugPrint(
        '[sync][conflict] conflict=${conflict.id} missing queue mutation.',
      );
      return const SyncConflictResolveResult(
        ok: false,
        message:
            'Sync conflict could not be retried because the local mutation is missing.',
      );
    }

    final queueItem = queue[queueIndex];
    final remoteVersion =
        conflict.currentVersion ?? conflict.remoteSnapshot?.version;
    if (queueItem.kind == PushQueueOperationKind.delete &&
        remoteVersion == null) {
      syncDebugPrint(
        '[sync][conflict] conflict=${conflict.id} delete retry missing remote version.',
      );
      return const SyncConflictResolveResult(
        ok: false,
        message: 'Delete conflict requires a remote version before retrying.',
      );
    }

    queue[queueIndex] = PushQueueItem(
      opId: queueItem.opId,
      localRecordId: queueItem.localRecordId,
      remoteRecordId: queueItem.remoteRecordId,
      kind: queueItem.kind,
      status: PushQueueStatus.pending,
      createdAt: queueItem.createdAt,
      updatedAt: _now().toUtc(),
      expectedVersion: remoteVersion,
      ciphertext: queueItem.ciphertext,
      nonce: queueItem.nonce,
      gcmTag: queueItem.gcmTag,
      keyVersion: queueItem.keyVersion,
      // The re-push must ship the same salt: without it the other
      // device derives a different item key and cannot open the payload.
      itemKeySalt: queueItem.itemKeySalt,
      itemKeyVersion: queueItem.itemKeyVersion,
      idempotencyKey: null,
      attemptCount: queueItem.attemptCount,
      retryCount: 0,
      nextAttemptAt: null,
      lastResultCode: 'manual_keep_local',
      lastMessage: 'Retry scheduled after manual conflict resolution.',
    );

    await _localStore.savePushQueue(userId: userId, items: queue);
    await _localStore.removePendingConflict(
      userId: userId,
      conflictId: conflict.id,
    );
    await _triggerPushSync?.call();
    syncDebugPrint(
      '[sync][conflict] conflict=${conflict.id} resolved as keep_local.',
    );

    return const SyncConflictResolveResult(
      ok: true,
      message:
          'Local version kept. Mutation re-queued with remote base version.',
    );
  }

  Future<String?> _readUserId() async {
    final userId = await _repository.readCurrentUserId();
    if (userId == null || userId.isEmpty) {
      return null;
    }

    return userId;
  }
}
