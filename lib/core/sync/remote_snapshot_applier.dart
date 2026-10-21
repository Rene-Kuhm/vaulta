import 'remote_vault_blob_change.dart';

/// Applies pulled remote snapshots into the local store.
///
/// The pull path of sync used to take the concrete blob repository, which coupled
/// the sync layer to one storage implementation. This narrow port is the only
/// thing sync needs, so a second storage can implement it without sync knowing
/// what it is.
///
/// Still unimplemented by the SQLite storage (ADR-007): until it is, the bootstrap
/// passes `null`, which is a documented mode of `buildDeviceSyncLifecycle` — pull
/// runs and only the local sync state advances, no vault item changes. That gap is
/// recorded in the ADR rather than hidden behind a silently half-working sync.
abstract interface class RemoteSnapshotApplier {
  /// Applies [snapshots] locally and returns the record ids that were rejected,
  /// typically because a payload failed its binding check.
  Future<List<String>> applyRemoteSnapshots({
    required Iterable<RemoteVaultBlobSnapshot> snapshots,
  });
}
