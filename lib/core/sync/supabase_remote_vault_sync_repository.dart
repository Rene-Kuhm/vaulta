import 'package:supabase_flutter/supabase_flutter.dart';

import 'remote_vault_blob_change.dart';
import 'remote_vault_sync_repository.dart';

/// Supabase-backed implementation of [RemoteVaultSyncRepository].
/// Reads from the `vault_ops` + `vault_blobs` tables (pull) and
/// writes via the `rpc_vault_upsert_blob` / `rpc_vault_delete_blob`
/// RPCs (push). The pull path is two-step on purpose: fetch the
/// latest op id per record, then fetch the current blob for each of
/// those records. This avoids fetching a long history of tombstones
/// for records that have since been re-inserted.
class SupabaseRemoteVaultSyncRepository implements RemoteVaultSyncRepository {
  /// Wires the repository to a Supabase [client].
  SupabaseRemoteVaultSyncRepository({required SupabaseClient client})
    : _client = client;

  final SupabaseClient _client;

  @override
  Future<String?> readCurrentUserId() async {
    return _client.auth.currentUser?.id;
  }

  @override
  Future<List<RemoteVaultBlobChange>> fetchChangesSince({
    required int afterOpId,
    int limit = 200,
  }) async {
    final opsResponse = await _client
        .from('vault_ops')
        .select('id,record_id')
        .gt('id', afterOpId)
        .order('id')
        .limit(limit);

    final opRows = (opsResponse as List<dynamic>).cast<Map<String, dynamic>>();
    if (opRows.isEmpty) {
      return const [];
    }

    final latestOpByRecord = <String, Map<String, dynamic>>{};
    for (final row in opRows) {
      final recordId = row['record_id'] as String?;
      if (recordId == null || recordId.isEmpty) {
        continue;
      }
      latestOpByRecord[recordId] = row;
    }

    if (latestOpByRecord.isEmpty) {
      return const [];
    }

    final recordIds = latestOpByRecord.keys.toList(growable: false);
    final blobsResponse = await _client
        .from('vault_blobs')
        .select(
          'record_id,version,ciphertext,nonce,gcm_tag,aad,key_version,'
          'item_key_salt,item_key_version,deleted_at,updated_at',
        )
        .inFilter('record_id', recordIds);
    final blobRows = (blobsResponse as List<dynamic>)
        .cast<Map<String, dynamic>>();

    final blobByRecord = <String, Map<String, dynamic>>{};
    for (final row in blobRows) {
      final recordId = row['record_id'] as String?;
      if (recordId == null || recordId.isEmpty) {
        continue;
      }
      blobByRecord[recordId] = row;
    }

    final sortedOps = latestOpByRecord.values.toList(growable: false)
      ..sort((left, right) {
        final leftId = (left['id'] as num).toInt();
        final rightId = (right['id'] as num).toInt();
        return leftId.compareTo(rightId);
      });

    final changes = <RemoteVaultBlobChange>[];
    for (final opRow in sortedOps) {
      final recordId = opRow['record_id'] as String;
      final blobRow = blobByRecord[recordId];
      if (blobRow == null) {
        continue;
      }
      changes.add(
        RemoteVaultBlobChange.fromSupabaseRows(opRow: opRow, blobRow: blobRow),
      );
    }

    return changes;
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
    final response = await _client.rpc(
      'rpc_vault_upsert_blob',
      params: {
        'p_device_id': deviceId,
        'p_idempotency_key': idempotencyKey,
        'p_record_id': recordId,
        'p_expected_version': expectedVersion,
        'p_ciphertext': ciphertext,
        'p_nonce': nonce,
        'p_gcm_tag': gcmTag,
        'p_key_version': keyVersion,
        'p_item_key_salt': itemKeySalt,
        'p_item_key_version': itemKeyVersion,
      },
    );

    final row = _readSingleRpcRow(response);
    return RemoteVaultPushResult.fromRpcRow(row);
  }

  @override
  Future<RemoteVaultPushResult> pushDeleteBlob({
    required String deviceId,
    required String idempotencyKey,
    required String recordId,
    required int expectedVersion,
  }) async {
    final response = await _client.rpc(
      'rpc_vault_delete_blob',
      params: {
        'p_device_id': deviceId,
        'p_idempotency_key': idempotencyKey,
        'p_record_id': recordId,
        'p_expected_version': expectedVersion,
      },
    );

    final row = _readSingleRpcRow(response);
    return RemoteVaultPushResult.fromRpcRow(row);
  }

  Map<String, dynamic> _readSingleRpcRow(dynamic response) {
    if (response is! List || response.isEmpty) {
      throw const FormatException('RPC response is empty.');
    }

    final first = response.first;
    if (first is! Map<String, dynamic>) {
      throw const FormatException('RPC response row has invalid format.');
    }

    return first;
  }
}
