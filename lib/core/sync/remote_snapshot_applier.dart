import 'remote_vault_blob_change.dart';

/// Applies pulled remote snapshots into the local store.
///
/// The pull path of sync used to take the concrete blob repository, which coupled
/// the sync layer to one storage implementation. This narrow port is the only
/// thing sync needs, so a second storage can implement it without sync knowing
/// what it is.
///
/// Both storages implement it: `LocalEncryptedVaultRepository` over the encrypted
/// blob and `LazySqliteVaultRepository` over the database (ADR-007), so a pulled
/// change reaches the vault whichever storage the build flag selects.
abstract interface class RemoteSnapshotApplier {
  /// Applies [snapshots] locally and returns the record ids that were rejected,
  /// typically because a payload failed its binding check.
  Future<List<String>> applyRemoteSnapshots({
    required Iterable<RemoteVaultBlobSnapshot> snapshots,
  });
}
