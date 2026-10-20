import 'dart:convert';

import '../security/secure_storage_service.dart';
import 'local_vault_mutation.dart';
import 'remote_vault_blob_change.dart';
import 'sync_conflict.dart';

/// Persistent on-device state for the sync layer. Backed by
/// [SecureStorageService] (so it goes through Android Keystore /
/// Windows Credential Manager / etc.) and namespaced per
/// `(userId, deviceId)`. Owns:
///
/// * the per-(user, device) pull cursor and last-pull timestamp;
/// * the per-user map of remote record id → blob snapshot;
/// * the per-user push queue;
/// * the per-user pending conflict log;
/// * the per-user local→remote record id mapping.
class LocalRemoteVaultStore {
  /// Builds a [LocalRemoteVaultStore] on top of the supplied
  /// secure [storage].
  LocalRemoteVaultStore({required SecureStorageService storage})
    : _storage = storage;

  /// Secure storage key prefix for the per-(user, device) pull
  /// cursor.
  static const _cursorPrefix = 'vault_sync_pull_cursor_v1';

  /// Secure storage key prefix for the per-(user, device) last
  /// pull timestamp.
  static const _lastPullPrefix = 'vault_sync_pull_last_at_v1';

  /// Secure storage key prefix for the per-user map of remote
  /// record id → blob snapshot.
  static const _blobPrefix = 'vault_sync_remote_blobs_v1';

  /// Secure storage key prefix for the per-user push queue.
  static const _pushQueuePrefix = 'vault_sync_push_queue_v1';

  /// Secure storage key prefix for the per-user conflict log.
  static const _conflictPrefix = 'vault_sync_conflicts_v1';

  /// Secure storage key prefix for the per-user record id mapping
  /// (remote → local).
  static const _recordIdMapPrefix = 'vault_sync_record_id_map_v1';

  final SecureStorageService _storage;

  /// Returns the persisted pull cursor for (user, device), or 0 if
  /// no pull has run yet. The cursor is the `vault_ops.id` value
  /// the pull service has consumed up to.
  Future<int> readCursor({
    required String userId,
    required String deviceId,
  }) async {
    final raw = await _storage.read(
      _cursorKey(userId: userId, deviceId: deviceId),
    );
    if (raw == null || raw.isEmpty) {
      return 0;
    }

    final parsed = int.tryParse(raw);
    return parsed ?? 0;
  }

  /// Persists the pull cursor for (user, device). Call after a
  /// successful pull cycle.
  Future<void> saveCursor({
    required String userId,
    required String deviceId,
    required int cursor,
  }) {
    return _storage.save(
      _cursorKey(userId: userId, deviceId: deviceId),
      cursor.toString(),
    );
  }

  /// Returns the timestamp of the last successful pull for (user,
  /// device), or null if there has been no pull yet. Used by the
  /// pull service's throttle window.
  Future<DateTime?> readLastPullAt({
    required String userId,
    required String deviceId,
  }) async {
    final raw = await _storage.read(
      _lastPullKey(userId: userId, deviceId: deviceId),
    );
    if (raw == null || raw.isEmpty) {
      return null;
    }

    return DateTime.tryParse(raw)?.toUtc();
  }

  /// Persists the last-pull timestamp for (user, device). Call
  /// after a successful pull cycle.
  Future<void> saveLastPullAt({
    required String userId,
    required String deviceId,
    required DateTime lastPullAt,
  }) {
    return _storage.save(
      _lastPullKey(userId: userId, deviceId: deviceId),
      lastPullAt.toUtc().toIso8601String(),
    );
  }

  /// Returns all remote snapshots the pull path has written for
  /// [userId]. The map is keyed by remote record id.
  Future<Map<String, RemoteVaultBlobSnapshot>> readSnapshots({
    required String userId,
  }) async {
    final raw = await _storage.read(_blobKey(userId: userId));
    if (raw == null || raw.isEmpty) {
      return {};
    }

    final payload = jsonDecode(raw) as Map<String, dynamic>;
    final snapshots = <String, RemoteVaultBlobSnapshot>{};
    for (final entry in payload.entries) {
      snapshots[entry.key] = RemoteVaultBlobSnapshot.fromJson(
        entry.value as Map<String, dynamic>,
      );
    }
    return snapshots;
  }

  /// Applies a batch of [changes] from the pull cycle to the
  /// snapshot map, advancing the cursor to [newCursor]. Stale
  /// changes (lower version or older `updatedAt` than what we
  /// already have) are silently dropped.
  Future<void> applyChanges({
    required String userId,
    required String deviceId,
    required List<RemoteVaultBlobChange> changes,
    required int newCursor,
  }) async {
    final snapshots = await readSnapshots(userId: userId);
    for (final change in changes) {
      final existing = snapshots[change.recordId];
      if (!_shouldApply(existing: existing, incoming: change)) {
        continue;
      }

      snapshots[change.recordId] = RemoteVaultBlobSnapshot.fromChange(change);
    }

    final encoded = <String, dynamic>{
      for (final entry in snapshots.entries) entry.key: entry.value.toJson(),
    };
    await _storage.save(_blobKey(userId: userId), jsonEncode(encoded));
    await saveCursor(userId: userId, deviceId: deviceId, cursor: newCursor);
  }

  /// Overwrites a single snapshot. Used by the push service after a
  /// successful upsert RPC to reflect the new version the backend
  /// returned.
  Future<void> saveSnapshot({
    required String userId,
    required RemoteVaultBlobSnapshot snapshot,
  }) async {
    final snapshots = await readSnapshots(userId: userId);
    snapshots[snapshot.recordId] = snapshot;
    final encoded = <String, dynamic>{
      for (final entry in snapshots.entries) entry.key: entry.value.toJson(),
    };
    await _storage.save(_blobKey(userId: userId), jsonEncode(encoded));
  }

  /// Returns the snapshot for a single [recordId], or null when the
  /// record has never been pulled.
  Future<RemoteVaultBlobSnapshot?> readSnapshot({
    required String userId,
    required String recordId,
  }) async {
    final snapshots = await readSnapshots(userId: userId);
    return snapshots[recordId];
  }

  /// Returns the per-user push queue. Returns an empty list when
  /// the user has never enqueued a mutation.
  Future<List<PushQueueItem>> readPushQueue({required String userId}) async {
    final raw = await _storage.read(_pushQueueKey(userId: userId));
    if (raw == null || raw.isEmpty) {
      return [];
    }

    final payload = jsonDecode(raw) as List<dynamic>;
    return payload
        .cast<Map<String, dynamic>>()
        .map(PushQueueItem.fromJson)
        .toList(growable: true);
  }

  /// Persists the per-user push queue, overwriting whatever was
  /// there before.
  Future<void> savePushQueue({
    required String userId,
    required List<PushQueueItem> items,
  }) async {
    final encoded = items.map((item) => item.toJson()).toList(growable: false);
    await _storage.save(_pushQueueKey(userId: userId), jsonEncode(encoded));
  }

  /// Appends [item] to the push queue, de-duplicating against any
  /// existing non-`inFlight` item for the same `localRecordId`.
  Future<void> enqueuePushMutation({
    required String userId,
    required PushQueueItem item,
  }) async {
    final queue = await readPushQueue(userId: userId);
    queue.removeWhere(
      (existing) =>
          existing.localRecordId == item.localRecordId &&
          existing.status != PushQueueStatus.inFlight,
    );
    queue.add(item);
    await savePushQueue(userId: userId, items: queue);
  }

  /// Returns the per-user pending conflict log. Returns an empty
  /// list when the user has no conflicts pending resolution.
  Future<List<SyncConflictRecord>> readPendingConflicts({
    required String userId,
  }) async {
    final raw = await _storage.read(_conflictKey(userId: userId));
    if (raw == null || raw.isEmpty) {
      return [];
    }

    final payload = jsonDecode(raw) as List<dynamic>;
    return payload
        .cast<Map<String, dynamic>>()
        .map(SyncConflictRecord.fromJson)
        .toList(growable: true);
  }

  /// Persists the per-user conflict log, overwriting whatever was
  /// there before.
  Future<void> savePendingConflicts({
    required String userId,
    required List<SyncConflictRecord> conflicts,
  }) async {
    final encoded = conflicts
        .map((conflict) => conflict.toJson())
        .toList(growable: false);
    await _storage.save(_conflictKey(userId: userId), jsonEncode(encoded));
  }

  /// Inserts a new conflict or updates an existing one in place
  /// (matched by `opId`).
  Future<void> upsertPendingConflict({
    required String userId,
    required SyncConflictRecord conflict,
  }) async {
    final conflicts = await readPendingConflicts(userId: userId);
    final index = conflicts.indexWhere((item) => item.opId == conflict.opId);
    if (index == -1) {
      conflicts.add(conflict);
    } else {
      conflicts[index] = conflict;
    }

    await savePendingConflicts(userId: userId, conflicts: conflicts);
  }

  /// Removes the conflict identified by [conflictId] from the
  /// per-user conflict log.
  Future<void> removePendingConflict({
    required String userId,
    required String conflictId,
  }) async {
    final conflicts = await readPendingConflicts(userId: userId);
    conflicts.removeWhere((item) => item.id == conflictId);
    await savePendingConflicts(userId: userId, conflicts: conflicts);
  }

  /// Records that [localRecordId] is the local projection of
  /// [remoteRecordId]. No-op when the two ids are already equal
  /// (the common case for UUIDs minted locally).
  Future<void> saveRecordIdMapping({
    required String userId,
    required String localRecordId,
    required String remoteRecordId,
  }) async {
    if (localRecordId == remoteRecordId) {
      return;
    }

    final raw = await _storage.read(_recordIdMapKey(userId: userId));
    final map = raw == null || raw.isEmpty
        ? <String, String>{}
        : (jsonDecode(raw) as Map<String, dynamic>).cast<String, String>();
    map[remoteRecordId] = localRecordId;
    await _storage.save(_recordIdMapKey(userId: userId), jsonEncode(map));
  }

  /// Returns the local record id that [remoteRecordId] maps to,
  /// or [remoteRecordId] itself when no mapping is recorded.
  Future<String> resolveLocalRecordId({
    required String userId,
    required String remoteRecordId,
  }) async {
    final raw = await _storage.read(_recordIdMapKey(userId: userId));
    if (raw != null && raw.isNotEmpty) {
      final map = (jsonDecode(raw) as Map<String, dynamic>)
          .cast<String, String>();
      final localId = map[remoteRecordId];
      if (localId != null) {
        return localId;
      }
    }

    return remoteRecordId;
  }

  /// Returns true when [incoming] should overwrite [existing] in the
  /// snapshot map. The rule is: no existing → always apply;
  /// incoming has higher version → apply; equal version and
  /// `updatedAt` is later → apply. Otherwise drop.
  bool _shouldApply({
    required RemoteVaultBlobSnapshot? existing,
    required RemoteVaultBlobChange incoming,
  }) {
    if (existing == null) {
      return true;
    }

    if (incoming.version > existing.version) {
      return true;
    }

    if (incoming.version < existing.version) {
      return false;
    }

    return incoming.updatedAt.isAfter(existing.updatedAt);
  }

  String _cursorKey({required String userId, required String deviceId}) {
    return '$_cursorPrefix:$userId:$deviceId';
  }

  String _lastPullKey({required String userId, required String deviceId}) {
    return '$_lastPullPrefix:$userId:$deviceId';
  }

  String _blobKey({required String userId}) {
    return '$_blobPrefix:$userId';
  }

  String _pushQueueKey({required String userId}) {
    return '$_pushQueuePrefix:$userId';
  }

  String _conflictKey({required String userId}) {
    return '$_conflictPrefix:$userId';
  }

  String _recordIdMapKey({required String userId}) {
    return '$_recordIdMapPrefix:$userId';
  }
}

/// Lifecycle state of a [PushQueueItem] inside the queue.
enum PushQueueStatus {
  /// Just enqueued, never attempted.
  pending,

  /// Currently being dispatched (in the push RPC). Cleared on next
  /// drain.
  inFlight,

  /// Last attempt failed transiently. Has [PushQueueItem.nextAttemptAt]
  /// set; the drain loop will retry after that timestamp.
  retry,

  /// Last attempt failed definitively (auth expired, idempotency
  /// mismatch, etc.). The drain loop will NOT retry; the user must
  /// intervene.
  failed,

  /// The push RPC returned `casConflict`. The conflict resolver is
  /// responsible for picking `keepLocal` / `keepRemote`. The drain
  /// loop will NOT retry.
  conflict,
}

/// Whether the local mutation was an upsert or a delete. Carried in
/// [PushQueueItem.kind] so the drain loop dispatches the right RPC.
enum PushQueueOperationKind {
  /// Local side created or updated a record.
  upsert,

  /// Local side deleted a record.
  delete,
}

/// One entry in the per-user push queue. Created from a
/// [LocalVaultMutation] emitted by the vault repository, updated by
/// the push service as dispatch progresses, removed when the
/// mutation is applied (or abandoned) on the backend.
class PushQueueItem {
  /// Builds a [PushQueueItem]. [opId], [localRecordId],
  /// [remoteRecordId], [kind], [status], [createdAt] and [updatedAt]
  /// are required. The rest default to zero/empty/null and are
  /// filled in by the push service as dispatch progresses.
  const PushQueueItem({
    required this.opId,
    required this.localRecordId,
    required this.remoteRecordId,
    required this.kind,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.expectedVersion,
    this.ciphertext,
    this.nonce,
    this.gcmTag,
    this.keyVersion,
    this.itemKeySalt,
    this.itemKeyVersion,
    this.idempotencyKey,
    this.attemptCount = 0,
    this.retryCount = 0,
    this.nextAttemptAt,
    this.lastResultCode,
    this.lastMessage,
  });

  /// UUID identifying this specific push attempt. Stable across
  /// retries (the same logical mutation keeps the same `opId`).
  final String opId;

  /// Local vault record id.
  final String localRecordId;

  /// Remote record id (after the local→remote mapping).
  final String remoteRecordId;

  /// Upsert or delete.
  final PushQueueOperationKind kind;

  /// Current lifecycle state.
  final PushQueueStatus status;

  /// Version the push RPC claims the record has. CAS-checked on
  /// the backend; a mismatch yields a `casConflict` and the
  /// conflict resolver is invoked.
  final int? expectedVersion;

  /// Base64 ciphertext. Null for deletes.
  final String? ciphertext;

  /// Base64 nonce. Null for deletes.
  final String? nonce;

  /// Base64 GCM auth tag. Null for deletes.
  final String? gcmTag;

  /// DEK version. Used by the backend to know whether a rekey is
  /// in flight.
  final int? keyVersion;

  /// Base64 salt of the per-item key, from the backend
  /// `item_key_salt` column. Null unless [keyVersion] is an item-keyed
  /// payload version (see `SyncItemPayloadCodec.itemKeyPayloadVersion`).
  ///
  /// Persisted with the queue because a retry after a process restart
  /// must ship the same salt: the receiver derives the item key from it,
  /// and a v4 payload without it is a payload nobody can open.
  final String? itemKeySalt;

  /// Item key version bound into the v4 associated data. Null unless
  /// [keyVersion] is an item-keyed payload version.
  final int? itemKeyVersion;

  /// Stable per-mutation dedup key. Re-generated after a
  /// `keepLocal` resolution so the re-attempt is treated as a new
  /// logical operation.
  final String? idempotencyKey;

  /// Total number of dispatch attempts (including retries).
  final int attemptCount;

  /// Number of transient-failed retries. Reset to 0 after a
  /// `keepLocal` resolution.
  final int retryCount;

  /// Earliest timestamp at which the drain loop may retry this item.
  /// Only meaningful when [status] is [PushQueueStatus.retry].
  final DateTime? nextAttemptAt;

  /// Most recent backend result code (e.g. `cas_conflict`,
  /// `idempotency_mismatch`). Useful for the conflict-resolver UI
  /// and for triage.
  final String? lastResultCode;

  /// Most recent backend message.
  final String? lastMessage;

  /// When the item was first enqueued.
  final DateTime createdAt;

  /// When the item was last touched (every dispatch bumps this).
  final DateTime updatedAt;

  /// Returns a copy with the supplied fields replaced. The
  /// [createdAt] is preserved (immutable after creation); [updatedAt]
  /// is preserved unless explicitly supplied.
  PushQueueItem copyWith({
    PushQueueStatus? status,
    int? expectedVersion,
    String? idempotencyKey,
    int? attemptCount,
    int? retryCount,
    DateTime? nextAttemptAt,
    String? lastResultCode,
    String? lastMessage,
    DateTime? updatedAt,
  }) {
    return PushQueueItem(
      opId: opId,
      localRecordId: localRecordId,
      remoteRecordId: remoteRecordId,
      kind: kind,
      status: status ?? this.status,
      expectedVersion: expectedVersion ?? this.expectedVersion,
      ciphertext: ciphertext,
      nonce: nonce,
      gcmTag: gcmTag,
      keyVersion: keyVersion,
      itemKeySalt: itemKeySalt,
      itemKeyVersion: itemKeyVersion,
      idempotencyKey: idempotencyKey ?? this.idempotencyKey,
      attemptCount: attemptCount ?? this.attemptCount,
      retryCount: retryCount ?? this.retryCount,
      nextAttemptAt: nextAttemptAt,
      lastResultCode: lastResultCode ?? this.lastResultCode,
      lastMessage: lastMessage ?? this.lastMessage,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Builds a [PushQueueItem] from a [LocalVaultMutation]. Sets
  /// [PushQueueItem.status] to [PushQueueStatus.pending] and copies
  /// the encryption material from the mutation.
  factory PushQueueItem.fromMutation({
    required String opId,
    required String remoteRecordId,
    required LocalVaultMutation mutation,
  }) {
    return PushQueueItem(
      opId: opId,
      localRecordId: mutation.localRecordId,
      remoteRecordId: remoteRecordId,
      kind: mutation.kind == LocalVaultMutationKind.upsert
          ? PushQueueOperationKind.upsert
          : PushQueueOperationKind.delete,
      status: PushQueueStatus.pending,
      ciphertext: mutation.ciphertext,
      nonce: mutation.nonce,
      gcmTag: mutation.gcmTag,
      keyVersion: mutation.keyVersion,
      itemKeySalt: mutation.itemKeySalt,
      itemKeyVersion: mutation.itemKeyVersion,
      createdAt: mutation.occurredAt,
      updatedAt: mutation.occurredAt,
    );
  }

  /// Inverse of [toJson]. Accepts the legacy `aad` field name as
  /// a fallback for [gcmTag] so old persisted items keep loading.
  /// Queue entries written before item-keyed payloads existed carry
  /// neither item key field and load with both null.
  factory PushQueueItem.fromJson(Map<String, dynamic> json) {
    return PushQueueItem(
      opId: json['opId'] as String,
      localRecordId: json['localRecordId'] as String,
      remoteRecordId: json['remoteRecordId'] as String,
      kind: _kindFromString(json['kind'] as String),
      status: _statusFromString(json['status'] as String),
      expectedVersion: json['expectedVersion'] as int?,
      ciphertext: json['ciphertext'] as String?,
      nonce: json['nonce'] as String?,
      gcmTag: (json['gcmTag'] ?? json['aad']) as String?,
      keyVersion: json['keyVersion'] as int?,
      itemKeySalt: json['itemKeySalt'] as String?,
      itemKeyVersion: json['itemKeyVersion'] as int?,
      idempotencyKey: json['idempotencyKey'] as String?,
      attemptCount: json['attemptCount'] as int? ?? 0,
      retryCount: json['retryCount'] as int? ?? 0,
      nextAttemptAt: json['nextAttemptAt'] == null
          ? null
          : DateTime.parse(json['nextAttemptAt'] as String).toUtc(),
      lastResultCode: json['lastResultCode'] as String?,
      lastMessage: json['lastMessage'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
    );
  }

  /// Serializes the item for persistence in the push queue.
  Map<String, dynamic> toJson() {
    return {
      'opId': opId,
      'localRecordId': localRecordId,
      'remoteRecordId': remoteRecordId,
      'kind': kind.name,
      'status': status.name,
      'expectedVersion': expectedVersion,
      'ciphertext': ciphertext,
      'nonce': nonce,
      'gcmTag': gcmTag,
      'keyVersion': keyVersion,
      'itemKeySalt': itemKeySalt,
      'itemKeyVersion': itemKeyVersion,
      'idempotencyKey': idempotencyKey,
      'attemptCount': attemptCount,
      'retryCount': retryCount,
      'nextAttemptAt': nextAttemptAt?.toUtc().toIso8601String(),
      'lastResultCode': lastResultCode,
      'lastMessage': lastMessage,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
    };
  }

  static PushQueueOperationKind _kindFromString(String raw) {
    return switch (raw) {
      'upsert' => PushQueueOperationKind.upsert,
      'delete' => PushQueueOperationKind.delete,
      _ => PushQueueOperationKind.upsert,
    };
  }

  static PushQueueStatus _statusFromString(String raw) {
    return switch (raw) {
      'pending' => PushQueueStatus.pending,
      'inFlight' => PushQueueStatus.inFlight,
      'retry' => PushQueueStatus.retry,
      'failed' => PushQueueStatus.failed,
      'conflict' => PushQueueStatus.conflict,
      _ => PushQueueStatus.pending,
    };
  }
}
