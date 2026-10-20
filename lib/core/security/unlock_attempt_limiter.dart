import 'secure_storage_service.dart';

/// Returns the current wall-clock time. Injected into
/// [UnlockAttemptLimiter] so tests can drive the lockout schedule
/// deterministically.
typedef UnlockAttemptClock = DateTime Function();

/// Outcome of [UnlockAttemptLimiter.runAttempt].
enum UnlockAttemptOutcome {
  /// The guarded check ran and the password matched. The counter was
  /// reset.
  succeeded,

  /// The guarded check ran and the password did not match. The
  /// failure was recorded (and may have started a lockout).
  failed,

  /// The attempt was refused before the guarded check ran, either
  /// because a lockout is active or because another attempt is
  /// already in flight. No KDF work happened.
  rejected,
}

/// Throttles master-password guesses on the lock screen.
///
/// Schedule: the first [freeAttempts] failures are free. Every failure
/// from the `freeAttempts + 1`-th on imposes a lockout before the next
/// attempt is allowed, starting at [baseLockout] and doubling per
/// further failure, capped at [maxLockout] (30 s, 60 s, 120 s, ...,
/// 15 min).
///
/// State (`failedCount`, `lockedUntil`, `lastFailureAt`, all
/// timestamps UTC) is persisted in [SecureStorageService] so killing
/// the app does not reset it. Call [load] once before using the
/// limiter.
///
/// Clock rollback defense: if the current time is earlier than the
/// last recorded failure, the device is treated as still locked out
/// and the lockout is re-anchored at "now" for its full duration. A
/// rollback can therefore never make a lockout expire early.
///
/// The limiter never wipes the vault: users have no export path yet,
/// so an auto-wipe would be silent data loss.
class UnlockAttemptLimiter {
  /// Builds a limiter backed by [storage]. [clock] defaults to
  /// [DateTime.now]; tests inject a fake.
  UnlockAttemptLimiter({
    required SecureStorageService storage,
    UnlockAttemptClock? clock,
  }) : _storage = storage,
       _clock = clock ?? DateTime.now;

  /// Secure storage key for the consecutive failure counter.
  static const failedCountKey = 'vault_unlock_failed_count';

  /// Secure storage key for the lockout expiry (UTC, ISO-8601).
  static const lockedUntilKey = 'vault_unlock_locked_until';

  /// Secure storage key for the last failure timestamp (UTC, ISO-8601).
  static const lastFailureAtKey = 'vault_unlock_last_failure_at';

  /// Number of failures tolerated before lockouts start.
  static const freeAttempts = 4;

  /// Lockout imposed after the first failure past [freeAttempts].
  static const baseLockout = Duration(seconds: 30);

  /// Upper bound of any single lockout.
  static const maxLockout = Duration(minutes: 15);

  final SecureStorageService _storage;
  final UnlockAttemptClock _clock;

  int _failedCount = 0;
  DateTime? _lockedUntil;
  DateTime? _lastFailureAt;
  bool _attemptInFlight = false;

  /// Consecutive failed master-password attempts since the last
  /// success.
  int get failedCount => _failedCount;

  /// Lockout expiry (UTC), or `null` when no lockout was ever imposed
  /// since the last success.
  DateTime? get lockedUntil => _lockedUntil;

  /// Timestamp (UTC) of the most recent failure, or `null`.
  DateTime? get lastFailureAt => _lastFailureAt;

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
  /// attempt is allowed right now.
  Duration? remainingLockout() {
    final lockout = lockoutForFailureCount(_failedCount);
    if (lockout == Duration.zero) {
      return null;
    }
    final now = _now();
    final lastFailureAt = _lastFailureAt;
    if (lastFailureAt == null) {
      // Counter past the threshold without a timestamp: inconsistent
      // state. Fail closed with the full lockout.
      return lockout;
    }
    if (now.isBefore(lastFailureAt)) {
      // Clock rollback: never treat the lockout as expired.
      return lockout;
    }
    var until = lastFailureAt.add(lockout);
    final storedUntil = _lockedUntil;
    if (storedUntil != null && storedUntil.isAfter(until)) {
      // Keep whichever expiry is later, but never beyond one full
      // lockout from now (a tampered far-future value must not brick
      // the vault).
      final cap = now.add(lockout);
      until = storedUntil.isAfter(cap) ? cap : storedUntil;
    }
    if (!now.isBefore(until)) {
      return null;
    }
    return until.difference(now);
  }

  /// True while a lockout is active.
  bool get isLockedOut => remainingLockout() != null;

  /// Reads persisted state. Missing keys mean a clean slate. Corrupt
  /// or unreadable state fails closed: the limiter starts at the
  /// first lockout tier anchored at "now".
  Future<void> load() async {
    try {
      final rawCount = await _storage.read(failedCountKey);
      final rawUntil = await _storage.read(lockedUntilKey);
      final rawLast = await _storage.read(lastFailureAtKey);

      if (rawCount == null && rawUntil == null && rawLast == null) {
        _resetInMemory();
        return;
      }

      final count = rawCount == null ? null : int.tryParse(rawCount);
      final until = rawUntil == null ? null : DateTime.tryParse(rawUntil);
      final last = rawLast == null ? null : DateTime.tryParse(rawLast);
      final corrupt =
          count == null ||
          count < 0 ||
          (rawUntil != null && until == null) ||
          (rawLast != null && last == null) ||
          (count > 0 && last == null);
      if (corrupt) {
        await _failClosed();
        return;
      }

      _failedCount = count;
      _lockedUntil = until?.toUtc();
      _lastFailureAt = last?.toUtc();
      await _reanchorIfClockRolledBack();
    } catch (_) {
      await _failClosed();
    }
  }

  /// Runs [verify] only when an attempt is currently allowed, and
  /// records the outcome. Returns [UnlockAttemptOutcome.rejected]
  /// without calling [verify] while a lockout is active or while
  /// another attempt is still in flight (so concurrent submissions
  /// cannot race past the counter).
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
      await _reanchorIfClockRolledBack();
      if (isLockedOut) {
        return UnlockAttemptOutcome.rejected;
      }

      final matches = await verify();
      if (matches) {
        await recordSuccess();
        return UnlockAttemptOutcome.succeeded;
      }
      await recordFailure();
      return UnlockAttemptOutcome.failed;
    } finally {
      _attemptInFlight = false;
    }
  }

  /// Records a failed master-password attempt and persists the new
  /// state.
  Future<void> recordFailure() async {
    final now = _now();
    _failedCount += 1;
    _lastFailureAt = now;
    final lockout = lockoutForFailureCount(_failedCount);
    _lockedUntil = lockout == Duration.zero ? null : now.add(lockout);
    await _persist();
  }

  /// Clears the counter and lockout after a successful unlock
  /// (master password or biometric).
  Future<void> recordSuccess() async {
    if (_failedCount == 0 && _lockedUntil == null && _lastFailureAt == null) {
      return;
    }
    _resetInMemory();
    try {
      await _storage.delete(failedCountKey);
      await _storage.delete(lockedUntilKey);
      await _storage.delete(lastFailureAtKey);
    } catch (_) {
      // The in-memory reset already applies to this session; a stale
      // persisted counter only costs the user a lockout after restart.
    }
  }

  DateTime _now() => _clock().toUtc();

  void _resetInMemory() {
    _failedCount = 0;
    _lockedUntil = null;
    _lastFailureAt = null;
  }

  Future<void> _reanchorIfClockRolledBack() async {
    final last = _lastFailureAt;
    if (last == null) {
      return;
    }
    final now = _now();
    if (!now.isBefore(last)) {
      return;
    }
    final lockout = lockoutForFailureCount(_failedCount);
    _lastFailureAt = now;
    _lockedUntil = lockout == Duration.zero ? null : now.add(lockout);
    await _persist();
  }

  Future<void> _failClosed() async {
    final now = _now();
    _failedCount = freeAttempts + 1;
    _lastFailureAt = now;
    _lockedUntil = now.add(lockoutForFailureCount(_failedCount));
    await _persist();
  }

  Future<void> _persist() async {
    try {
      await _storage.save(failedCountKey, _failedCount.toString());
      await _storage.save(lastFailureAtKey, _lastFailureAt!.toIso8601String());
      final until = _lockedUntil;
      if (until == null) {
        await _storage.delete(lockedUntilKey);
      } else {
        await _storage.save(lockedUntilKey, until.toIso8601String());
      }
    } catch (_) {
      // Storage unavailable: the in-memory state still throttles this
      // session. Nothing secret is involved, so there is nothing to
      // log beyond what the caller already surfaces.
    }
  }
}
