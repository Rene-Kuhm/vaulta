// ignore_for_file: avoid_dynamic_calls

import 'package:flutter/foundation.dart';

/// Callback signature that receives a [SyncDiagnosticEvent] when the
/// sync layer emits one. The vault lifecycle wires this to surface
/// sync issues in the settings screen; tests pass a recorder.
typedef SyncDiagnosticsHook = void Function(SyncDiagnosticEvent event);

/// Toggle for the `debugPrint` line emitted with each diagnostic
/// event. Disabled by default to keep release builds quiet; enable
/// during local development by running with
/// `--dart-define=VAULTA_SYNC_DIAGNOSTICS_LOGS=true`.
const bool syncDiagnosticsLoggingEnabled = bool.fromEnvironment(
  'VAULTA_SYNC_DIAGNOSTICS_LOGS',
);

/// Conditionally prints a sync diagnostic line. No-op when
/// [syncDiagnosticsLoggingEnabled] is false.
void syncDebugPrint(String message) {
  if (!syncDiagnosticsLoggingEnabled) {
    return;
  }

  debugPrint(message);
}

/// One structured event emitted by the sync layer when something
/// goes wrong (or is about to be retried). Carries enough context
/// for the lifecycle to render a useful message in the settings
/// screen without re-fetching from the backend.
class SyncDiagnosticEvent {
  /// Builds a [SyncDiagnosticEvent]. The metadata map is shallow-
  /// copied at the call site (no need to wrap it).
  const SyncDiagnosticEvent({
    required this.scope,
    required this.operation,
    required this.code,
    required this.message,
    required this.retriable,
    required this.timestamp,
    this.attempt,
    this.maxAttempts,
    this.errorType,
    this.metadata = const <String, Object?>{},
  });

  /// Coarse area: `pull`, `push`, `session`, `revocation`, etc.
  final String scope;

  /// Specific operation within the scope: `fetch_changes`,
  /// `dispatch`, `read_access_status`, etc.
  final String operation;

  /// Stable status code from [SyncStatusCodes].
  final String code;

  /// Human-readable, already-localized message.
  final String message;

  /// True when the sync layer will retry on its own. False when the
  /// failure is definitive and requires user intervention.
  final bool retriable;

  /// When the event was emitted (UTC).
  final DateTime timestamp;

  /// Retry attempt number (1-based) when applicable.
  final int? attempt;

  /// Maximum number of attempts configured for this operation.
  final int? maxAttempts;

  /// `runtimeType` of the originating error, useful for triage.
  final String? errorType;

  /// Free-form structured context (e.g. `afterOpId`, `recordId`).
  final Map<String, Object?> metadata;
}

/// Stable status codes returned by [classifySyncError] and
/// [syncErrorCode]. Stored verbatim in [SyncDiagnosticEvent.code].
final class SyncStatusCodes {
  /// Backend rejected the push because `expectedVersion` was stale.
  static const casConflict = 'cas_conflict';

  /// Backend saw a different `idempotencyKey` for the same op.
  static const idempotencyMismatch = 'idempotency_mismatch';

  /// Session or device was revoked remotely; the user must
  /// re-authenticate.
  static const revokedSessionOrDevice = 'revoked_session_or_device';

  /// Network is down or the server is unreachable.
  static const offlineNetworkError = 'offline_network_error';

  /// Generic transport-level failure (timeout, socket reset, etc.).
  static const transportError = 'transport_error';

  /// A pulled payload was refused before reaching the vault: its
  /// record binding did not match the row, it was a v1/v2 payload for
  /// a vault already migrated to v3, or it failed authentication.
  static const payloadRejected = 'payload_rejected';

  /// Catch-all for unclassified failures.
  static const unknown = 'unknown';
}

/// Maps a [SyncStatusCodes] value to its localized, user-facing
/// message. Falls back to [fallback] (or a generic phrase) when the
/// code is unrecognized.
String syncMessageForCode(String code, {String? fallback}) {
  return switch (code) {
    SyncStatusCodes.casConflict =>
      'Conflicto de version detectado. Se requiere resolucion manual.',
    SyncStatusCodes.idempotencyMismatch =>
      'La operacion remota no coincide con la llave de idempotencia y se freno para evitar corrupcion.',
    SyncStatusCodes.revokedSessionOrDevice =>
      'La sesion o dispositivo fue revocado remotamente.',
    SyncStatusCodes.offlineNetworkError =>
      'No hay conectividad con el servidor de sync.',
    SyncStatusCodes.payloadRejected =>
      'Se descarto un cambio remoto con cifrado invalido o de una version anterior no permitida.',
    SyncStatusCodes.transportError =>
      fallback ?? 'Fallo de transporte durante sync.',
    _ => fallback ?? 'Fallo de sincronizacion no clasificado.',
  };
}

/// Coarse classification of a sync error. Drives whether the layer
/// retries, surfaces to the UI, or both.
enum SyncErrorDisposition {
  /// Worth retrying (network blip, server 5xx, 429, etc.).
  transient,

  /// Will not succeed on retry without user intervention (auth
  /// expired, device revoked, idempotency mismatch, etc.).
  definitive,
}

/// Classifies an arbitrary error as [SyncErrorDisposition.transient]
/// or [SyncErrorDisposition.definitive]. The heuristic inspects the
/// HTTP status code (if any) and the error text/type for known
/// transient hints ("offline", "network", "timeout", ...).
SyncErrorDisposition classifySyncError(Object error) {
  if (_looksDefinitive(error)) {
    return SyncErrorDisposition.definitive;
  }
  if (_looksTransient(error)) {
    return SyncErrorDisposition.transient;
  }
  return SyncErrorDisposition.definitive;
}

/// Maps an arbitrary error to a [SyncStatusCodes] value. The
/// classification is the same as [classifySyncError] but the output
/// is a stable string suitable for diagnostics and the UI.
String syncErrorCode(Object error) {
  if (_looksRevocation(error)) {
    return SyncStatusCodes.revokedSessionOrDevice;
  }
  if (_looksTransient(error)) {
    return SyncStatusCodes.offlineNetworkError;
  }
  return SyncStatusCodes.transportError;
}

/// Emits a [SyncDiagnosticEvent] via the optional [hook] and prints
/// a one-line `debugPrint` when [syncDiagnosticsLoggingEnabled] is
/// true. The [metadata] map is shallow-copied; callers can pass
/// read-only maps.
void emitSyncDiagnostic({
  required String scope,
  required String operation,
  required String code,
  required String message,
  required bool retriable,
  required DateTime timestamp,
  SyncDiagnosticsHook? hook,
  int? attempt,
  int? maxAttempts,
  Object? error,
  Map<String, Object?> metadata = const <String, Object?>{},
}) {
  final event = SyncDiagnosticEvent(
    scope: scope,
    operation: operation,
    code: code,
    message: message,
    retriable: retriable,
    timestamp: timestamp.toUtc(),
    attempt: attempt,
    maxAttempts: maxAttempts,
    errorType: error?.runtimeType.toString(),
    metadata: metadata,
  );

  final payload = <String, Object?>{
    'scope': event.scope,
    'operation': event.operation,
    'code': event.code,
    'retriable': event.retriable,
    'attempt': event.attempt,
    'maxAttempts': event.maxAttempts,
    'errorType': event.errorType,
    'message': event.message,
    'metadata': event.metadata,
  };
  syncDebugPrint('[sync][diag] $payload');
  hook?.call(event);
}

bool _looksTransient(Object error) {
  final text = _errorText(error);
  final statusCode = _statusCodeFrom(error);
  if (statusCode != null) {
    if (statusCode == 408 || statusCode == 429 || statusCode >= 500) {
      return true;
    }
    if (statusCode == 401 || statusCode == 403 || statusCode == 409) {
      return false;
    }
  }

  if (_containsAny(text, _transientHints)) {
    return true;
  }

  final type = error.runtimeType.toString().toLowerCase();
  return _containsAny(type, _transientTypeHints);
}

bool _looksDefinitive(Object error) {
  final text = _errorText(error);
  final statusCode = _statusCodeFrom(error);
  if (statusCode != null &&
      (statusCode == 401 || statusCode == 403 || statusCode == 409)) {
    return true;
  }

  return _containsAny(text, _definitiveHints);
}

bool _looksRevocation(Object error) {
  final text = _errorText(error);
  return _containsAny(text, _revocationHints);
}

int? _statusCodeFrom(Object error) {
  final dynamic dynamicError = error;
  final candidates = <Object?>[
    _safeRead(() => dynamicError.statusCode),
    _safeRead(() => dynamicError.status),
  ];
  for (final candidate in candidates) {
    if (candidate is int) {
      return candidate;
    }
    if (candidate is num) {
      return candidate.toInt();
    }
    if (candidate is String) {
      final parsed = int.tryParse(candidate);
      if (parsed != null) {
        return parsed;
      }
    }
  }
  return null;
}

String _errorText(Object error) {
  final dynamic dynamicError = error;
  final parts = <String>[
    error.toString(),
    _safeRead(() => dynamicError.message)?.toString() ?? '',
    _safeRead(() => dynamicError.code)?.toString() ?? '',
    _safeRead(() => dynamicError.details)?.toString() ?? '',
    _safeRead(() => dynamicError.hint)?.toString() ?? '',
  ];
  return parts.join(' ').toLowerCase();
}

T? _safeRead<T>(T Function() reader) {
  try {
    return reader();
  } catch (_) {
    return null;
  }
}

bool _containsAny(String source, List<String> needles) {
  for (final needle in needles) {
    if (source.contains(needle)) {
      return true;
    }
  }
  return false;
}

const _transientHints = <String>[
  'offline',
  'network',
  'socket',
  'connection reset',
  'connection refused',
  'timed out',
  'timeout',
  'temporarily unavailable',
  'temporary failure',
  'too many requests',
  'rate limit',
  'service unavailable',
  'gateway timeout',
];

const _transientTypeHints = <String>[
  'timeout',
  'socket',
  'network',
  'clientexception',
  'postgrestexception',
];

const _definitiveHints = <String>[
  'unauth',
  'forbidden',
  'access denied',
  'invalid device',
  'idempotency_mismatch',
  'cas_conflict',
  'version mismatch',
  'revoked',
];

const _revocationHints = <String>[
  'revoked_device',
  'revoked_all',
  'session_revoked',
  'device_revoked',
  'revoked',
];
