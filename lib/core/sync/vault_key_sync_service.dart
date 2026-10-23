import '../security/master_password_record.dart';
import 'vault_key_sync_repository.dart';

/// Reconciles the local vault key with the remote one.
///
/// The vault key is the serialized [MasterPasswordRecord]: the wrapped DEK
/// plus everything a second device needs to re-derive the DEK from the master
/// password. There are exactly two states that matter:
///
/// - this device has a local record → it is the newest key this device knows,
///   so push it (idempotent upsert);
/// - this device has no local record but the backend has one → adopt it, so
///   the onboarding screen becomes the unlock screen and the user's existing
///   master password opens the synced vault.
///
/// A stale device racing a rekey can push an older key over a newer one; that
/// race is out of scope for the first cut and is documented in
/// `odd/tasks/vault-key-cross-device-sync.md`.
class VaultKeySyncService {
  /// Builds the service. [readLocalRecordJson] returns the locally persisted
  /// `record_json`, or `null` when this device has not created or adopted a
  /// vault. [adoptRemoteRecord] persists a remote `record_json` locally.
  VaultKeySyncService({
    required VaultKeySyncRepository repository,
    required Future<String?> Function() readLocalRecordJson,
    required Future<void> Function(String recordJson) adoptRemoteRecord,
  }) : _repository = repository,
       _readLocalRecordJson = readLocalRecordJson,
       _adoptRemoteRecord = adoptRemoteRecord;

  final VaultKeySyncRepository _repository;
  final Future<String?> Function() _readLocalRecordJson;
  final Future<void> Function(String recordJson) _adoptRemoteRecord;

  /// Runs one reconcile cycle. Safe to call repeatedly: both branches are
  /// idempotent, and neither throws for a null local/remote state.
  Future<void> syncOnce() async {
    final remote = await _repository.readRemoteKey();
    final local = await _readLocalRecordJson();

    if (local != null && local.isNotEmpty) {
      final keyId = _keyIdFromRecordJson(local);
      if (keyId != null) {
        await _repository.putRemoteKey(keyId: keyId, recordJson: local);
      }
      return;
    }

    if (remote != null && remote.isNotEmpty) {
      await _adoptRemoteRecord(remote);
    }
  }

  String? _keyIdFromRecordJson(String recordJson) {
    try {
      return MasterPasswordRecord.decode(recordJson).keyId;
    } on Object {
      return null;
    }
  }
}
