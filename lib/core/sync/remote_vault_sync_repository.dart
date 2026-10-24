import 'remote_vault_blob_change.dart';

/// Contract for the remote side of the sync loop. Implementations
/// talk to the backend (Supabase today, any future replacement) and
/// expose the four operations the local sync layer needs:
///
/// 1. discover the current user id,
/// 2. fetch changes since a given op id (pull),
/// 3. push an upsert blob (push, with CAS for conflict detection),
/// 4. push a delete blob (push, same CAS protocol).
///
/// The interface is shaped around the sync contract, not around the
/// underlying transport: see
/// `docs/architecture/ADR-002-sync.md` for the CAS + idempotency
/// rules.
abstract interface class RemoteVaultSyncRepository {
  /// Returns the currently authenticated user id, or `null` if the
  /// session is anonymous. Used by the sync layer to namespace the
  /// cursor, push queue, and conflict log per user.
  Future<String?> readCurrentUserId();

  /// Fetches the next batch of remote changes after [afterOpId],
  /// capped at [limit] (defaults to 200). Returns a possibly empty
  /// list; an empty list signals "you're caught up".
  Future<List<RemoteVaultBlobChange>> fetchChangesSince({
    required int afterOpId,
    int limit,
  });

  /// Pushes an upsert to the remote. [expectedVersion] drives the
  /// CAS check; a mismatch yields a [RemoteVaultPushResultCode.casConflict].
  /// [idempotencyKey] deduplicates retries within a single client.
  ///
  /// [itemKeySalt] and [itemKeyVersion] describe the per-item key of a
  /// payload at `SyncItemPayloadCodec.itemKeyPayloadVersion` or above;
  /// they are what lets the receiving device derive the same key. They
  /// must be null for older payloads and required by the backend for a
  /// new one, so a payload nobody can open is never stored.
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
  });

  /// Pushes a tombstone delete. Same CAS + idempotency contract as
  /// [pushUpsertBlob].
  Future<RemoteVaultPushResult> pushDeleteBlob({
    required String deviceId,
    required String idempotencyKey,
    required String recordId,
    required int expectedVersion,
  });
}

/// Discriminator for the [RemoteVaultPushResult.code] field. Models
/// the four outcomes the backend RPC can return plus an "unknown"
/// catch-all for unrecognized codes.
enum RemoteVaultPushResultCode {
  /// The remote applied the mutation. Caller should remove the item
  /// from the push queue and persist the new snapshot.
  applied,

  /// The remote recognized the [idempotencyKey] as a previous
  /// successful operation and returned the same result without
  /// applying again. Treated as success by the push service.
  idempotentReplay,

  /// The remote saw [expectedVersion] as stale; the conflict
  /// resolver should be invoked to decide between local and remote.
  casConflict,

  /// The remote saw a different [idempotencyKey] for an already
  /// processed mutation. Treated as definitive failure (must not be
  /// retried blindly).
  idempotencyMismatch,

  /// Catch-all for unrecognized [result_code] values from the
  /// backend. Treated as retriable by default unless the message
  /// contains explicit revocation language.
  unknown,
}

/// Result of a single push RPC. Carries the [code] discriminator plus
/// the full payload the backend returned so the caller can update
/// the local snapshot without a second round trip.
class RemoteVaultPushResult {
  /// Builds a [RemoteVaultPushResult] from a parsed RPC row or a
  /// test fixture. All three flags ([applied], [idempotentReplay],
  /// [conflict]) are required because the backend returns them as
  /// distinct booleans, not derived from [code].
  const RemoteVaultPushResult({
    required this.code,
    required this.applied,
    required this.idempotentReplay,
    required this.conflict,
    this.message,
    this.recordId,
    this.currentVersion,
    this.appliedVersion,
    this.deletedAt,
  });

  /// Coarse discriminator, see [RemoteVaultPushResultCode].
  final RemoteVaultPushResultCode code;

  /// True if the backend reports the mutation was applied.
  final bool applied;

  /// True if the backend recognized the [idempotencyKey] as a
  /// replay.
  final bool idempotentReplay;

  /// True if the backend rejected the push due to a CAS mismatch.
  final bool conflict;

  /// Human-readable backend message (often null on success). The
  /// push service uses this to classify unknown errors (revocation
  /// vs transient network).
  final String? message;

  /// Record id as the backend sees it (may differ from the local id
  /// if the backend remapped). Present when the backend returns it.
  final String? recordId;

  /// Version the remote currently holds for this record. Present
  /// on conflicts so the conflict resolver can show it.
  final int? currentVersion;

  /// Version the remote just assigned after applying the mutation.
  /// Present on success.
  final int? appliedVersion;

  /// If the mutation was a delete, the timestamp the remote set on
  /// the tombstone. Present on delete success.
  final DateTime? deletedAt;

  /// True when the push was effectively successful — applied for the
  /// first time or a benign replay. Used by the push service to
  /// decide whether to drop the queue item.
  bool get isSuccess => applied || idempotentReplay;

  /// Parses the standard backend RPC row shape. See
  /// `docs/setup/supabase-migrations.md` for the row contract.
  factory RemoteVaultPushResult.fromRpcRow(Map<String, dynamic> row) {
    final rawCode = row['result_code'] as String?;
    return RemoteVaultPushResult(
      code: _parseCode(rawCode),
      applied: row['applied'] as bool? ?? false,
      idempotentReplay: row['idempotent_replay'] as bool? ?? false,
      conflict: row['conflict'] as bool? ?? false,
      message: row['message'] as String?,
      recordId: row['record_id'] as String?,
      currentVersion: _readNullableInt(row['current_version']),
      appliedVersion: _readNullableInt(row['applied_version']),
      deletedAt: _readNullableDateTime(row['deleted_at']),
    );
  }

  static RemoteVaultPushResultCode _parseCode(String? value) {
    return switch (value) {
      'applied' => RemoteVaultPushResultCode.applied,
      'idempotent_replay' => RemoteVaultPushResultCode.idempotentReplay,
      'cas_conflict' => RemoteVaultPushResultCode.casConflict,
      'idempotency_mismatch' => RemoteVaultPushResultCode.idempotencyMismatch,
      _ => RemoteVaultPushResultCode.unknown,
    };
  }

  static int? _readNullableInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return null;
  }

  static DateTime? _readNullableDateTime(Object? value) {
    if (value is! String || value.isEmpty) {
      return null;
    }
    return DateTime.parse(value).toUtc();
  }
}
