import 'dart:convert';

import 'secure_storage_service.dart';

/// Returns the current wall-clock time. Injected into
/// [UnlockAttemptLimiter] so tests can drive the lockout schedule
/// deterministically.
typedef UnlockAttemptClock = DateTime Function();

/// Returns the elapsed time on a monotonic, in-process timeline (one
/// that the user cannot move by changing the device clock). Only
/// differences between two readings are meaningful.
typedef UnlockAttemptMonotonicClock = Duration Function();

/// Outcome of [UnlockAttemptLimiter.runAttempt].
enum UnlockAttemptOutcome {
  /// The guarded check ran and the password matched. The counter was
  /// reset.
  succeeded,

  /// The guarded check ran and the password did not match. The
  /// failure had already been recorded before the check ran.
  failed,

  /// The attempt was refused before the guarded check ran, either
  /// because a lockout is active or because another attempt is
  /// already in flight in this process. No KDF work happened.
  rejected,

  /// The attempt was refused before the guarded check ran because the
  /// attempt counter could not be read from or written to secure
  /// storage. Fails closed: without a durable record of the attempt,
  /// no KDF work happens.
  storageFailure,
}

/// Throttles master-password guesses.
///
/// Schedule: the first [freeAttempts] failures are free. Every failure
/// from the `freeAttempts + 1`-th on imposes a lockout before the next
/// attempt is allowed, starting at [baseLockout] and doubling per
/// further failure, capped at [maxLockout] (30 s, 60 s, 120 s, ...,
/// 15 min).
///
/// State (`failedCount`, `lockedUntil`, `lastFailureAt`, timestamps in
/// UTC) is persisted as one JSON value under [stateKey] in
/// [SecureStorageService], so it is written atomically and killing the
/// app between writes cannot leave a half-updated record. Persisted
/// state is authoritative: [runAttempt] re-reads it before every
/// attempt and merges it with the in-memory view (highest count,
/// latest timestamps), so several app instances sharing the same
/// storage (desktop runners are not single-instance) cannot reset each
/// other's counter.
///
/// Every attempt is counted *before* the password is checked
/// (pre-increment): the failure is persisted first, then the verifier
/// runs, and a match resets the state. Killing the process mid-KDF
/// therefore still costs the attacker an attempt.
///
/// Clock defenses:
/// - Rollback: if the current time is earlier than the last recorded
///   failure, the device is treated as still locked out and the
///   lockout is re-anchored at "now" for its full duration.
/// - Forward jump: within one process, a lockout also has to elapse
///   on a monotonic clock, so moving the device clock forward does not
///   end it early. Across restarts only the persisted wall-clock
///   timestamps survive, so that protection does not carry over.
///
/// The limiter never wipes the vault: users have no export path yet,
/// so an auto-wipe would be silent data loss.
class UnlockAttemptLimiter {
  /// Builds a limiter backed by [storage]. [clock] defaults to
  /// [DateTime.now] and [monotonicClock] to a process-wide
  /// [Stopwatch]; tests inject fakes.
  UnlockAttemptLimiter({
    required SecureStorageService storage,
    UnlockAttemptClock? clock,
    UnlockAttemptMonotonicClock? monotonicClock,
  }) : _storage = storage,
       _clock = clock ?? DateTime.now,
       _monotonicClock = monotonicClock ?? _processElapsed;

  /// Secure storage key holding the JSON-encoded attempt state.
  static const stateKey = 'vault_unlock_attempt_state';

  /// Number of failures tolerated before lockouts start.
  static const freeAttempts = 4;

  /// Lockout imposed after the first failure past [freeAttempts].
  static const baseLockout = Duration(seconds: 30);

  /// Upper bound of any single lockout.
  static const maxLockout = Duration(minutes: 15);

  static final Stopwatch _processStopwatch = Stopwatch()..start();
  static Duration _processElapsed() => _processStopwatch.elapsed;

  final SecureStorageService _storage;
  final UnlockAttemptClock _clock;
  final UnlockAttemptMonotonicClock _monotonicClock;

  _AttemptState _state = _AttemptState.clean;

  /// Point on the monotonic timeline before which the current lockout
  /// cannot end, regardless of the wall clock. `null` when no lockout
  /// was started (or loaded) in this process.
  Duration? _monotonicDeadline;
  bool _attemptInFlight = false;

  /// Consecutive failed master-password attempts since the last
  /// success.
  int get failedCount => _state.failedCount;

  /// Lockout expiry (UTC), or `null` when no lockout was imposed since
  /// the last success.
  DateTime? get lockedUntil => _state.lockedUntil;

  /// Timestamp (UTC) of the most recent failure, or `null`.
  DateTime? get lastFailureAt => _state.lastFailureAt;

  /// Lockout imposed after the [failedCount]-th consecutive failure,
  /// or [Duration.zero] while still inside the free attempts. Pure.
  static Duration lockoutForFailureCount(int failedCount) {
    if (failedCount <= freeAttempts) {
      return Duration.zero;
    }
    final doublings = failedCount - freeAttempts - 1;
    // 30 s << 5 already exceeds 15 min, so clamp the exponent to keep
    // the shift tiny no matter how large the persisted counter is.
    final shift = doublings > 10 ? 10 : doublings;
    final lockout = baseLockout * (1 << shift);
    return lockout > maxLockout ? maxLockout : lockout;
  }

  /// Time left before the next attempt is allowed, or `null` when an
  /// attempt is allowed right now. The longer of the wall-clock and
  /// the monotonic remaining time wins.
  Duration? remainingLockout() {
    if (lockoutForFailureCount(_state.failedCount) == Duration.zero) {
      return null;
    }
    final wall = _wallRemaining(_now()) ?? Duration.zero;
    final deadline = _monotonicDeadline;
    final monotonic = deadline == null
        ? Duration.zero
        : deadline - _monotonicClock();
    final remaining = wall > monotonic ? wall : monotonic;
    return remaining > Duration.zero ? remaining : null;
  }

  /// True while a lockout is active.
  bool get isLockedOut => remainingLockout() != null;

  /// Reads persisted state. A missing value means a clean slate.
  /// Corrupt or unreadable state fails closed: the limiter starts at
  /// the first lockout tier anchored at "now".
  Future<void> load() async {
    try {
      _state = await _readPersisted() ?? _AttemptState.clean;
    } catch (_) {
      // FormatException (corrupt value) or a storage read error.
      await _failClosed();
      return;
    }
    _monotonicDeadline = null;
    _reanchorIfClockRolledBack();
    _extendMonotonicDeadlineToWallClock();
  }

  /// Runs [verify] only when an attempt is currently allowed.
  ///
  /// Order: re-read and merge persisted state, check the lockout,
  /// persist the attempt as a failure, run [verify], and reset on a
  /// match. Returns [UnlockAttemptOutcome.rejected] without calling
  /// [verify] while a lockout is active or another attempt is in
  /// flight, and [UnlockAttemptOutcome.storageFailure] without calling
  /// [verify] when the state cannot be read or persisted.
  Future<UnlockAttemptOutcome> runAttempt(
    Future<bool> Function() verify,
  ) async {
    if (_attemptInFlight) {
      return UnlockAttemptOutcome.rejected;
    }
    // Claim the slot synchronously, before the first await, so a
    // second call that starts while this one is suspended is rejected.
    _attemptInFlight = true;
    try {
      try {
        await _mergePersisted();
      } catch (_) {
        return UnlockAttemptOutcome.storageFailure;
      }
      _reanchorIfClockRolledBack();
      if (isLockedOut) {
        return UnlockAttemptOutcome.rejected;
      }

      final previousState = _state;
      final previousDeadline = _monotonicDeadline;
      _applyFailure();
      try {
        await _writePersisted();
      } catch (_) {
        // The attempt was never durably recorded, so it must not run.
        _state = previousState;
        _monotonicDeadline = previousDeadline;
        return UnlockAttemptOutcome.storageFailure;
      }

      // If verify throws, the pre-recorded failure stands.
      final matches = await verify();
      if (matches) {
        await recordSuccess();
        return UnlockAttemptOutcome.succeeded;
      }
      return UnlockAttemptOutcome.failed;
    } finally {
      _attemptInFlight = false;
    }
  }

  /// Clears the counter and lockout after a successful unlock
  /// (master password or biometric).
  Future<void> recordSuccess() async {
    _state = _AttemptState.clean;
    _monotonicDeadline = null;
    try {
      await _storage.delete(stateKey);
    } catch (_) {
      // The in-memory reset already applies to this session; a stale
      // persisted counter only costs the user a lockout after restart.
    }
  }

  DateTime _now() => _clock().toUtc();

  Duration? _wallRemaining(DateTime now) {
    final lockout = lockoutForFailureCount(_state.failedCount);
    if (lockout == Duration.zero) {
      return null;
    }
    final lastFailureAt = _state.lastFailureAt;
    if (lastFailureAt == null || now.isBefore(lastFailureAt)) {
      // Missing timestamp past the threshold, or clock rollback:
      // never treat the lockout as expired.
      return lockout;
    }
    var until = lastFailureAt.add(lockout);
    final storedUntil = _state.lockedUntil;
    if (storedUntil != null && storedUntil.isAfter(until)) {
      // Keep whichever expiry is later, but never beyond one full
      // lockout from now (a tampered far-future value must not brick
      // the vault).
      final cap = now.add(lockout);
      until = storedUntil.isAfter(cap) ? cap : storedUntil;
    }
    return now.isBefore(until) ? until.difference(now) : null;
  }

  void _applyFailure() {
    final now = _now();
    final count = _state.failedCount + 1;
    final lockout = lockoutForFailureCount(count);
    _state = _AttemptState(
      failedCount: count,
      lastFailureAt: now,
      lockedUntil: lockout == Duration.zero ? null : now.add(lockout),
    );
    _monotonicDeadline = lockout == Duration.zero
        ? null
        : _monotonicClock() + lockout;
  }

  /// Re-reads persisted state and merges it into memory. Throws when
  /// storage cannot be read; corrupt values merge as a fail-closed
  /// state.
  Future<void> _mergePersisted() async {
    _AttemptState? persisted;
    try {
      persisted = await _readPersisted();
    } on FormatException {
      persisted = _failClosedState();
      await _tryWritePersisted(persisted);
    }
    if (persisted == null) {
      // Absent (never written, or cleared by a success elsewhere).
      // Keep the in-memory view: never weaker than what we know.
      return;
    }
    _state = _state.merge(persisted);
    _extendMonotonicDeadlineToWallClock();
  }

  void _extendMonotonicDeadlineToWallClock() {
    final wall = _wallRemaining(_now());
    if (wall == null) {
      return;
    }
    final candidate = _monotonicClock() + wall;
    final current = _monotonicDeadline;
    if (current == null || candidate > current) {
      _monotonicDeadline = candidate;
    }
  }

  void _reanchorIfClockRolledBack() {
    final last = _state.lastFailureAt;
    if (last == null) {
      return;
    }
    final now = _now();
    if (!now.isBefore(last)) {
      return;
    }
    final lockout = lockoutForFailureCount(_state.failedCount);
    _state = _AttemptState(
      failedCount: _state.failedCount,
      lastFailureAt: now,
      lockedUntil: lockout == Duration.zero ? null : now.add(lockout),
    );
    if (lockout != Duration.zero) {
      final candidate = _monotonicClock() + lockout;
      final current = _monotonicDeadline;
      if (current == null || candidate > current) {
        _monotonicDeadline = candidate;
      }
    }
  }

  _AttemptState _failClosedState() {
    final now = _now();
    const count = freeAttempts + 1;
    return _AttemptState(
      failedCount: count,
      lastFailureAt: now,
      lockedUntil: now.add(lockoutForFailureCount(count)),
    );
  }

  Future<void> _failClosed() async {
    _state = _failClosedState();
    _monotonicDeadline =
        _monotonicClock() + lockoutForFailureCount(_state.failedCount);
    // Overwrite the corrupt value so later merges read sane state.
    await _tryWritePersisted(_state);
  }

  Future<_AttemptState?> _readPersisted() async {
    final raw = await _storage.read(stateKey);
    if (raw == null) {
      return null;
    }
    return _AttemptState.decode(raw);
  }

  Future<void> _writePersisted() => _storage.save(stateKey, _state.encode());

  Future<void> _tryWritePersisted(_AttemptState state) async {
    try {
      await _storage.save(stateKey, state.encode());
    } catch (_) {
      // Best effort: the in-memory state still throttles this session.
    }
  }
}

/// Immutable snapshot of the persisted attempt state.
class _AttemptState {
  const _AttemptState({
    required this.failedCount,
    required this.lastFailureAt,
    required this.lockedUntil,
  });

  static const clean = _AttemptState(
    failedCount: 0,
    lastFailureAt: null,
    lockedUntil: null,
  );

  final int failedCount;
  final DateTime? lastFailureAt;
  final DateTime? lockedUntil;

  /// Conservative merge: highest count, latest timestamps.
  _AttemptState merge(_AttemptState other) => _AttemptState(
    failedCount: failedCount > other.failedCount
        ? failedCount
        : other.failedCount,
    lastFailureAt: _later(lastFailureAt, other.lastFailureAt),
    lockedUntil: _later(lockedUntil, other.lockedUntil),
  );

  static DateTime? _later(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  String encode() => jsonEncode({
    'failedCount': failedCount,
    'lastFailureAt': lastFailureAt?.toUtc().toIso8601String(),
    'lockedUntil': lockedUntil?.toUtc().toIso8601String(),
  });

  /// Throws [FormatException] on anything that is not a well-formed
  /// state record.
  static _AttemptState decode(String raw) {
    final Object? json = jsonDecode(raw);
    if (json is! Map<String, Object?>) {
      throw const FormatException('attempt state is not an object');
    }
    final count = json['failedCount'];
    final last = json['lastFailureAt'];
    final until = json['lockedUntil'];
    if (count is! int || count < 0) {
      throw const FormatException('invalid failedCount');
    }
    DateTime? parse(Object? value, String field) {
      if (value == null) return null;
      if (value is! String) throw FormatException('invalid $field');
      final parsed = DateTime.tryParse(value);
      if (parsed == null) throw FormatException('invalid $field');
      return parsed.toUtc();
    }

    final lastFailureAt = parse(last, 'lastFailureAt');
    if (count > 0 && lastFailureAt == null) {
      throw const FormatException('failedCount without lastFailureAt');
    }
    return _AttemptState(
      failedCount: count,
      lastFailureAt: lastFailureAt,
      lockedUntil: parse(until, 'lockedUntil'),
    );
  }
}
