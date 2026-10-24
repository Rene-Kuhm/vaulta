import 'package:supabase_flutter/supabase_flutter.dart';

import 'vault_key_sync_repository.dart';

/// Supabase-backed implementation of [VaultKeySyncRepository].
///
/// Maps the two operations to `rpc_vault_get_key` and `rpc_vault_put_key`.
/// The row is one-per-user and owner-scoped by the backend's RLS policies, so
/// no foreign user can read or write another user's wrapped DEK.
class SupabaseVaultKeySyncRepository implements VaultKeySyncRepository {
  /// Wires the repository to a Supabase [client].
  SupabaseVaultKeySyncRepository({required SupabaseClient client})
    : _client = client;

  final SupabaseClient _client;

  @override
  Future<String?> readRemoteKey() async {
    final response = await _client.rpc('rpc_vault_get_key');
    if (response is! List || response.isEmpty) {
      return null;
    }

    final row = response.first;
    if (row is! Map<String, dynamic>) {
      return null;
    }

    final recordJson = row['record_json'];
    return recordJson is String && recordJson.isNotEmpty ? recordJson : null;
  }

  @override
  Future<void> putRemoteKey({
    required String keyId,
    required String recordJson,
  }) async {
    await _client.rpc(
      'rpc_vault_put_key',
      params: {'p_key_id': keyId, 'p_record_json': recordJson},
    );
  }
}
