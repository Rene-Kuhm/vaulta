// ignore_for_file: prefer_const_declarations

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../security/secure_storage_service.dart';
import 'bidirectional_sync_service.dart';
import 'local_vault_mutation.dart';
import 'device_registration_repository.dart';
import 'device_session_revocation_service.dart';
import 'sync_conflict_resolver.dart';
import 'sync_runtime_hardening.dart';
import 'vault_key_sync_service.dart';

/// Abstraction over "what version of the app is running?". Lets
/// tests substitute a stub without pulling in `package_info_plus`.
abstract interface class AppVersionProvider {
  /// Returns the user-visible app version string, e.g. `1.0.21+22`.
  Future<String> readAppVersion();
}

/// Production [AppVersionProvider] backed by `package_info_plus`.
/// Returns `'unknown'` when the platform channel fails so the
/// device-registration call can still go through with a sentinel.
class PackageInfoAppVersionProvider implements AppVersionProvider {
  @override
  Future<String> readAppVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (packageInfo.version.isEmpty) {
      return 'unknown';
    }

    if (packageInfo.buildNumber.isEmpty) {
      return packageInfo.version;
    }

    return '${packageInfo.version}+${packageInfo.buildNumber}';
  }
}

/// Abstraction over "who is this device?". Lets tests substitute
/// deterministic device ids without touching secure storage.
abstract interface class DeviceIdentityService {
  /// Returns the locally-persisted device id, generating and storing
  /// a new UUID v4 the first time it is called.
  Future<String> getOrCreateDeviceId();

  /// Returns the user-visible device name (`Vaulta-<platform>-<id6>`).
  Future<String> readDeviceName();

  /// Returns the platform string (`android`, `ios`, `windows`, etc.).
  /// Synchronous because it just maps `defaultTargetPlatform`.
  String readPlatform();
}

/// Production [DeviceIdentityService] backed by secure storage.
class LocalDeviceIdentityService implements DeviceIdentityService {
  /// Builds a [LocalDeviceIdentityService]. The optional [uuid] is
  /// for tests; production code uses the default secure source.
  LocalDeviceIdentityService({
    required SecureStorageService storage,
    Uuid? uuid,
  }) : _storage = storage,
       _uuid = uuid ?? const Uuid();

  /// Secure storage key for the locally-persisted device id.
  static const deviceIdKey = 'vault_sync_device_id';

  final SecureStorageService _storage;
  final Uuid _uuid;

  @override
  Future<String> getOrCreateDeviceId() async {
    final existing = await _storage.read(deviceIdKey);
    final normalized = existing?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      return normalized;
    }

    final generated = _uuid.v4();
    await _storage.save(deviceIdKey, generated);
    return generated;
  }

  @override
  Future<String> readDeviceName() async {
    final deviceId = await getOrCreateDeviceId();
    final suffixLength = deviceId.length >= 6 ? 6 : deviceId.length;
    final suffix = deviceId.substring(deviceId.length - suffixLength);
    return 'Vaulta-${readPlatform()}-$suffix';
  }

  @override
  String readPlatform() {
    if (kIsWeb) {
      return 'web';
    }

    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }
}

/// Service that adapts the [DeviceRegistrationRepository] (low-level
/// RPCs) to the lifecycle's vocabulary (register, heartbeat,
/// read-status). The lifecycle calls these three methods at well-
/// defined moments.
class DeviceRegistrationService {
  /// Builds a [DeviceRegistrationService]. [repository] is the
  /// backend adapter; [identityService] resolves the device id;
  /// [appVersionProvider] reads the running app version.
  DeviceRegistrationService({
    required DeviceRegistrationRepository repository,
    required DeviceIdentityService identityService,
    required AppVersionProvider appVersionProvider,
    DateTime Function()? now,
  }) : _repository = repository,
       _identityService = identityService,
       _appVersionProvider = appVersionProvider,
       _now = now ?? DateTime.now;

  final DeviceRegistrationRepository _repository;
  final DeviceIdentityService _identityService;
  final AppVersionProvider _appVersionProvider;
  final DateTime Function() _now;

  /// Registers the current device with the backend. Idempotent
  /// server-side; safe to call repeatedly. Returns the resulting
  /// [DeviceAccessStatus] so the lifecycle can decide whether to
  /// gate the unlock.
  Future<DeviceAccessStatus> registerCurrentDevice() async {
    final metadata = await _readMetadata();
    return _repository.registerDevice(
      deviceId: metadata.deviceId,
      deviceName: metadata.deviceName,
      platform: metadata.platform,
      appVersion: metadata.appVersion,
      lastSeenAt: metadata.lastSeenAt,
    );
  }

  /// Sends a heartbeat to refresh the device's `lastSeenAt`. Returns
  /// the resulting [DeviceAccessStatus]; the lifecycle watches for
  /// revocations in the response and reacts.
  Future<DeviceAccessStatus> sendHeartbeat() async {
    final metadata = await _readMetadata();
    return _repository.sendHeartbeat(
      deviceId: metadata.deviceId,
      deviceName: metadata.deviceName,
      platform: metadata.platform,
      appVersion: metadata.appVersion,
      lastSeenAt: metadata.lastSeenAt,
    );
  }

  /// Reads the current device's [DeviceAccessStatus] without
  /// performing any mutation. Used by the lifecycle to gate the
  /// unlock flow.
  Future<DeviceAccessStatus> readCurrentDeviceAccessStatus() async {
    final deviceId = await _identityService.getOrCreateDeviceId();
    return _repository.readDeviceAccessStatus(deviceId: deviceId);
  }

  Future<_DeviceRegistrationMetadata> _readMetadata() async {
    final deviceId = await _identityService.getOrCreateDeviceId();
    final deviceName = await _identityService.readDeviceName();
    final appVersion = await _appVersionProvider.readAppVersion();

    return _DeviceRegistrationMetadata(
      deviceId: deviceId,
      deviceName: deviceName,
      platform: _identityService.readPlatform(),
      appVersion: appVersion,
      lastSeenAt: _now().toUtc(),
    );
  }
}

/// Higher-level orchestrator that ties together device registration,
/// heartbeat, push/pull sync (via the single [BidirectionalSyncService]),
/// conflict resolution, and revocation. The app constructs one of
/// these at startup and calls [onSessionStarted] / [onAppResumed]
/// from the app-lifecycle hook.
class DeviceSyncLifecycle {
  /// Builds a [DeviceSyncLifecycle]. All collaborators are
  /// required except the optional [syncService] (when omitted, the
  /// sync paths are a no-op), [conflictResolver] (when omitted,
  /// conflicts are still persisted but not exposed in the UI),
  /// [mutationSink] (when omitted, local mutations are not enqueued
  /// for push), and [onCurrentDeviceRevoked] (when omitted,
  /// revocation is logged but does not trigger any user-facing
  /// action).
  DeviceSyncLifecycle({
    required DeviceRegistrationService service,
    required this.revocationService,
    BidirectionalSyncService? syncService,
    this.conflictResolver,
    RelayLocalVaultMutationSink? mutationSink,
    this.onCurrentDeviceRevoked,
    this.maxRetryAttempts = 2,
    this.baseRetryDelay = const Duration(seconds: 1),
    this.heartbeatInterval = const Duration(minutes: 5),
    this.diagnosticsHook,
    this.vaultKeySync,
    Future<void> Function(Duration delay)? delay,
    DateTime Function()? now,
  }) : _service = service,
       _syncService = syncService,
       _mutationSink = mutationSink,
       _delay = delay ?? Future<void>.delayed,
       _now = now ?? DateTime.now;

  final DeviceRegistrationService _service;

  /// Service that owns the device-management screen and the
  /// "log out everywhere else" flow.
  final DeviceSessionRevocationService revocationService;

  /// Single bidirectional sync service. Replaces the previous
  /// split `IncrementalPullSyncService` + `IncrementalPushSyncService`
  /// pair (removed in T5 of ADR-004; see T4 for the consumer
  /// migration). When `null`, the sync paths in [onSessionStarted] /
  /// [onAppResumed] are no-ops.
  final BidirectionalSyncService? _syncService;

  /// Resolver exposed to the UI for the user to pick
  /// `keepLocal` / `keepRemote` on a conflict.
  final SyncConflictResolver? conflictResolver;
  final RelayLocalVaultMutationSink? _mutationSink;

  /// Callback invoked when the backend reports the current device
  /// was revoked. The app uses this to lock the vault and surface
  /// a "device revoked" message.
  final Future<void> Function(DeviceAccessStatus status)?
  onCurrentDeviceRevoked;

  /// Maximum number of retry attempts for the session-validation
  /// RPCs. 0 disables retries entirely.
  final int maxRetryAttempts;

  /// Initial backoff between retries. Doubles on each attempt.
  final Duration baseRetryDelay;

  /// How often [onAppResumed] sends a heartbeat (when the device is
  /// idle in the foreground).
  final Duration heartbeatInterval;

  /// Optional hook that receives a [SyncDiagnosticEvent] for every
  /// session-related failure. Used by the settings screen.
  final SyncDiagnosticsHook? diagnosticsHook;

  /// Reconciles the local vault key (wrapped DEK) with the remote one.
  /// `null` on builds or sessions where vault-key sync is not wired.
  final VaultKeySyncService? vaultKeySync;
  final Future<void> Function(Duration delay) _delay;
  final DateTime Function() _now;

  DateTime? _lastHeartbeatAt;
  bool _registered = false;

  /// Hook for the app's session-start lifecycle event. Validates
  /// the device with the backend, registers it if needed, and
  /// triggers the first pull/push via the [syncService]. Safe to
  /// call multiple times: subsequent calls within the same session
  /// short-circuit the registration step.
  Future<void> onSessionStarted() async {
    if (!await _ensureCurrentDeviceAccess()) {
      return;
    }

    final registrationStatus = await _runWithRetry(
      operationName: 'register_device',
      action: _service.registerCurrentDevice,
    );
    if (registrationStatus == null) {
      return;
    }

    if (!await _ensureAccessAllowed(registrationStatus)) {
      return;
    }

    _registered = true;
    _lastHeartbeatAt = _now();
    final syncService = _syncService;
    final mutationSink = _mutationSink;
    if (syncService != null && mutationSink != null) {
      mutationSink.attach(syncService);
    }
    await syncService?.onSessionStarted();
    await syncVaultKey();
  }

  /// Reconciles the vault key (wrapped DEK) with the remote, so a second
  /// device can adopt an existing vault and this device pushes its key
  /// after a fresh vault or a rekey. No-op when [vaultKeySync] is null.
  Future<void> syncVaultKey() async {
    await vaultKeySync?.syncOnce();
  }

  /// Hook for the app's foreground-resume lifecycle event. Sends
  /// a heartbeat if [heartbeatInterval] has elapsed, and triggers
  /// a fresh pull/push via the [syncService].
  Future<void> onAppResumed() async {
    if (!await _ensureCurrentDeviceAccess()) {
      return;
    }

    if (!_registered) {
      await onSessionStarted();
      return;
    }

    final lastHeartbeatAt = _lastHeartbeatAt;
    final shouldSendHeartbeat =
        lastHeartbeatAt == null ||
        _now().difference(lastHeartbeatAt) >= heartbeatInterval;
    if (shouldSendHeartbeat) {
      final heartbeatStatus = await _runWithRetry(
        operationName: 'send_heartbeat',
        action: _service.sendHeartbeat,
      );
      if (heartbeatStatus == null) {
        return;
      }

      if (!await _ensureAccessAllowed(heartbeatStatus)) {
        return;
      }
      _lastHeartbeatAt = _now();
    }

    await _syncService?.onAppResumed();
  }

  Future<bool> _ensureCurrentDeviceAccess() async {
    final status = await _runWithRetry(
      operationName: 'read_access_status',
      action: _service.readCurrentDeviceAccessStatus,
    );
    if (status == null) {
      return false;
    }

    return _ensureAccessAllowed(status);
  }

  Future<bool> _ensureAccessAllowed(DeviceAccessStatus status) async {
    if (!status.isRevoked) {
      return true;
    }

    _registered = false;
    final code = SyncStatusCodes.revokedSessionOrDevice;
    final message = syncMessageForCode(
      code,
      fallback: status.message ?? status.userFacingReason(),
    );
    emitSyncDiagnostic(
      scope: 'session',
      operation: 'ensure_access',
      code: code,
      message: message,
      retriable: false,
      timestamp: _now(),
      hook: diagnosticsHook,
      metadata: {'reason': status.reason?.name ?? 'unknown'},
    );
    syncDebugPrint(
      '[sync][session][revoked] reason=${status.reason?.name ?? 'unknown'} message=$message',
    );
    if (onCurrentDeviceRevoked case final callback?) {
      await callback(status);
    }
    return false;
  }

  Future<T?> _runWithRetry<T>({
    required String operationName,
    required Future<T> Function() action,
  }) async {
    if (maxRetryAttempts < 1) {
      return null;
    }

    Object? lastError;
    for (var attempt = 1; attempt <= maxRetryAttempts; attempt += 1) {
      try {
        return await action();
      } catch (error) {
        lastError = error;
        final disposition = classifySyncError(error);
        final code = syncErrorCode(error);
        final message = syncMessageForCode(
          code,
          fallback:
              'No se pudo ejecutar $operationName para validar sesion remota.',
        );
        final retriable = disposition == SyncErrorDisposition.transient;
        emitSyncDiagnostic(
          scope: 'session',
          operation: operationName,
          code: code,
          message: message,
          retriable: retriable,
          timestamp: _now(),
          hook: diagnosticsHook,
          attempt: attempt,
          maxAttempts: maxRetryAttempts,
          error: error,
        );
        syncDebugPrint(
          '[sync][session][$operationName] attempt=$attempt/$maxRetryAttempts failed: $error',
        );
        if (attempt >= maxRetryAttempts || !retriable) {
          break;
        }

        final delayMs = baseRetryDelay.inMilliseconds * (1 << (attempt - 1));
        await _delay(Duration(milliseconds: delayMs));
      }
    }

    syncDebugPrint(
      '[sync][session][$operationName] aborted after $maxRetryAttempts attempts: ${lastError ?? 'unknown error'}',
    );
    return null;
  }
}

class _DeviceRegistrationMetadata {
  const _DeviceRegistrationMetadata({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.appVersion,
    required this.lastSeenAt,
  });

  final String deviceId;
  final String deviceName;
  final String platform;
  final String appVersion;
  final DateTime lastSeenAt;
}
