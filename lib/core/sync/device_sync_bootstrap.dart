import '../security/secure_storage_service.dart';
import 'bidirectional_sync_service.dart';
import 'device_registration_repository.dart';
import 'device_registration_service.dart';
import 'device_session_revocation_service.dart';
import 'local_remote_vault_store.dart';
import 'local_vault_mutation.dart';
import 'supabase_device_registration_repository.dart';
import 'supabase_remote_vault_sync_repository.dart';
import 'sync_conflict_resolver.dart';
import 'remote_snapshot_applier.dart';
import 'supabase_client_resolver.dart';

/// Builds a fully-wired [DeviceSyncLifecycle] for the Supabase
/// backend. Returns `null` when the `SUPABASE_URL` or
/// `SUPABASE_ANON_KEY` dart-defines are missing, so the rest of the
/// app can degrade to "no sync" without conditionals at every
/// call site.
///
/// When non-null, the returned lifecycle is fully operational:
/// device registration, heartbeat, push/pull sync (via the single
/// [BidirectionalSyncService]), conflict resolution, and revocation
/// RPCs are all wired.
Future<DeviceSyncLifecycle?> buildDeviceSyncLifecycle({
  /// Backing store for the local device id and the local sync state
  /// (cursor, last-pull timestamp, push queue, conflict log).
  required SecureStorageService storage,

  /// Vault repository the pull path forwards decrypted snapshots to.
  /// When `null`, pull still runs but only updates the local sync
  /// state (no vault items changed).
  RemoteSnapshotApplier? vaultRepository,

  /// Local sink that the controller attaches to the sync service so
  /// local mutations get drained. Pass-through is intentional: the
  /// sink has a slot for the delegate and the bootstrap wires the
  /// sync service into it.
  RelayLocalVaultMutationSink? mutationSink,

  /// Called when the backend reports the current device has been
  /// revoked. The controller typically uses this to lock the vault
  /// and surface a "device revoked, sign in again" message.
  Future<void> Function(DeviceAccessStatus status)? onCurrentDeviceRevoked,
}) async {
  final client = await resolveSupabaseClient(
    url: const String.fromEnvironment('SUPABASE_URL'),
    anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'),
  );
  if (client == null) {
    return null;
  }

  final repository = SupabaseDeviceRegistrationRepository(client: client);
  final pullRepository = SupabaseRemoteVaultSyncRepository(client: client);
  final identityService = LocalDeviceIdentityService(storage: storage);
  final localStore = LocalRemoteVaultStore(storage: storage);
  final service = DeviceRegistrationService(
    repository: repository,
    identityService: identityService,
    appVersionProvider: PackageInfoAppVersionProvider(),
  );
  final revocationService = DeviceSessionRevocationService(
    repository: repository,
    identityService: identityService,
  );
  // Single bidirectional sync service replaces the previous split
  // pull + push pair (T4 of ADR-004). The service implements
  // `LocalVaultMutationSink` so the mutationSink wiring targets it
  // directly, and exposes `runNow` for the conflict resolver's
  // post-resolution drain.
  final syncService = BidirectionalSyncService(
    repository: pullRepository,
    localStore: localStore,
    readDeviceId: identityService.getOrCreateDeviceId,
    applyLocalSnapshots: vaultRepository == null
        ? null
        : (snapshots) =>
              vaultRepository.applyRemoteSnapshots(snapshots: snapshots),
  );
  final conflictResolver = SyncConflictResolver(
    repository: pullRepository,
    localStore: localStore,
    triggerPushSync: syncService.runNow,
  );
  mutationSink?.attach(syncService);

  return DeviceSyncLifecycle(
    service: service,
    revocationService: revocationService,
    syncService: syncService,
    conflictResolver: conflictResolver,
    mutationSink: mutationSink,
    onCurrentDeviceRevoked: onCurrentDeviceRevoked,
  );
}
