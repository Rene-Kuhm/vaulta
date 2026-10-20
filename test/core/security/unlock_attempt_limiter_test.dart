import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/unlock_attempt_limiter.dart';

void main() {
  late _InMemorySecureStorageService storage;
  late _FakeClock clock;

  UnlockAttemptLimiter newLimiter() =>
      UnlockAttemptLimiter(storage: storage, clock: clock.call);

  Future<void> failTimes(UnlockAttemptLimiter limiter, int times) async {
    for (var i = 0; i < times; i++) {
      await limiter.recordFailure();
    }
  }

  setUp(() {
    storage = _InMemorySecureStorageService();
    clock = _FakeClock(DateTime.utc(2026, 10, 19, 12));
  });

  group('lockoutForFailureCount', () {
    test('first four failures are free', () {
      for (var n = 0; n <= 4; n++) {
        expect(UnlockAttemptLimiter.lockoutForFailureCount(n), Duration.zero);
      }
    });

    test('fifth failure locks for 30 s and each further one doubles', () {
      expect(
        UnlockAttemptLimiter.lockoutForFailureCount(5),
        const Duration(seconds: 30),
      );
      expect(
        UnlockAttemptLimiter.lockoutForFailureCount(6),
        const Duration(seconds: 60),
      );
      expect(
        UnlockAttemptLimiter.lockoutForFailureCount(7),
        const Duration(seconds: 120),
      );
      expect(
        UnlockAttemptLimiter.lockoutForFailureCount(9),
        const Duration(seconds: 480),
      );
    });

    test('caps at 15 minutes, even for huge counters', () {
      expect(
        UnlockAttemptLimiter.lockoutForFailureCount(10),
        const Duration(minutes: 15),
      );
      expect(
        UnlockAttemptLimiter.lockoutForFailureCount(1 << 30),
        const Duration(minutes: 15),
      );
    });
  });

  group('UnlockAttemptLimiter', () {
    test('allows the first four failures without a lockout', () async {
      final limiter = newLimiter();
      await limiter.load();

      await failTimes(limiter, 4);

      expect(limiter.failedCount, 4);
      expect(limiter.isLockedOut, isFalse);
      expect(limiter.remainingLockout(), isNull);
    });

    test('fifth failure imposes a 30 s lockout that then expires', () async {
      final limiter = newLimiter();
      await limiter.load();

      await failTimes(limiter, 5);

      expect(limiter.remainingLockout(), const Duration(seconds: 30));
      clock.advance(const Duration(seconds: 29));
      expect(limiter.remainingLockout(), const Duration(seconds: 1));
      clock.advance(const Duration(seconds: 1));
      expect(limiter.isLockedOut, isFalse);
    });

    test('lockout doubles per further failure', () async {
      final limiter = newLimiter();
      await limiter.load();
      await failTimes(limiter, 5);

      clock.advance(const Duration(seconds: 30));
      await limiter.recordFailure();
      expect(limiter.remainingLockout(), const Duration(seconds: 60));

      clock.advance(const Duration(seconds: 60));
      await limiter.recordFailure();
      expect(limiter.remainingLockout(), const Duration(seconds: 120));
    });

    test('lockout is capped at 15 minutes', () async {
      final limiter = newLimiter();
      await limiter.load();

      await failTimes(limiter, 20);

      expect(limiter.remainingLockout(), const Duration(minutes: 15));
    });

    test('success resets counter, lockout and persisted keys', () async {
      final limiter = newLimiter();
      await limiter.load();
      await failTimes(limiter, 6);
      clock.advance(const Duration(minutes: 1));

      final outcome = await limiter.runAttempt(() async => true);

      expect(outcome, UnlockAttemptOutcome.succeeded);
      expect(limiter.failedCount, 0);
      expect(limiter.isLockedOut, isFalse);
      expect(await storage.read(UnlockAttemptLimiter.failedCountKey), isNull);
      expect(await storage.read(UnlockAttemptLimiter.lockedUntilKey), isNull);
      expect(await storage.read(UnlockAttemptLimiter.lastFailureAtKey), isNull);

      // A fresh failure after the reset is free again.
      await limiter.recordFailure();
      expect(limiter.isLockedOut, isFalse);
    });

    test('state persists across a new instance (app restart)', () async {
      final first = newLimiter();
      await first.load();
      await failTimes(first, 6);
      clock.advance(const Duration(seconds: 10));

      final restarted = newLimiter();
      await restarted.load();

      expect(restarted.failedCount, 6);
      expect(restarted.lastFailureAt, first.lastFailureAt);
      expect(restarted.lockedUntil, first.lockedUntil);
      expect(restarted.lockedUntil!.isUtc, isTrue);
      expect(restarted.remainingLockout(), const Duration(seconds: 50));
      expect(
        await storage.read(UnlockAttemptLimiter.lockedUntilKey),
        endsWith('Z'),
      );
    });

    test('clock rollback keeps the device locked, never expired', () async {
      final limiter = newLimiter();
      await limiter.load();
      await failTimes(limiter, 5);

      // Attacker moves the device clock back a day.
      clock.advance(const Duration(days: -1));

      expect(limiter.isLockedOut, isTrue);
      expect(limiter.remainingLockout(), const Duration(seconds: 30));
      var verifyCalls = 0;
      final outcome = await limiter.runAttempt(() async {
        verifyCalls++;
        return true;
      });
      expect(outcome, UnlockAttemptOutcome.rejected);
      expect(verifyCalls, 0);

      // The lockout was re-anchored at the rolled-back "now", so it
      // still lasts its full duration in the new time frame.
      clock.advance(const Duration(seconds: 29));
      expect(limiter.isLockedOut, isTrue);
      clock.advance(const Duration(seconds: 1));
      expect(limiter.isLockedOut, isFalse);
    });

    test('clock rollback across a restart stays locked', () async {
      final first = newLimiter();
      await first.load();
      await failTimes(first, 7);

      clock.advance(const Duration(hours: -3));
      final restarted = newLimiter();
      await restarted.load();

      expect(restarted.remainingLockout(), const Duration(seconds: 120));
    });

    test('rejected attempt during lockout does not run verify', () async {
      final limiter = newLimiter();
      await limiter.load();
      await failTimes(limiter, 5);
      var verifyCalls = 0;

      final outcome = await limiter.runAttempt(() async {
        verifyCalls++;
        return true;
      });

      expect(outcome, UnlockAttemptOutcome.rejected);
      expect(verifyCalls, 0);
      // A rejected attempt is not a new failure.
      expect(limiter.failedCount, 5);
    });

    test('concurrent attempts cannot race past the counter', () async {
      final limiter = newLimiter();
      await limiter.load();
      await failTimes(limiter, 4);
      var verifyCalls = 0;
      Future<bool> wrong() async {
        verifyCalls++;
        await Future<void>.delayed(Duration.zero);
        return false;
      }

      final outcomes = await Future.wait([
        limiter.runAttempt(wrong),
        limiter.runAttempt(wrong),
        limiter.runAttempt(wrong),
      ]);

      expect(verifyCalls, 1);
      expect(
        outcomes.where((o) => o == UnlockAttemptOutcome.rejected),
        hasLength(2),
      );
      expect(limiter.isLockedOut, isTrue);
    });

    test('corrupt persisted state fails closed into a lockout', () async {
      await storage.save(UnlockAttemptLimiter.failedCountKey, 'garbage');

      final limiter = newLimiter();
      await limiter.load();

      expect(limiter.isLockedOut, isTrue);
      expect(limiter.remainingLockout(), const Duration(seconds: 30));
    });

    test('unreadable storage fails closed into a lockout', () async {
      final limiter = UnlockAttemptLimiter(
        storage: _ThrowingSecureStorageService(),
        clock: clock.call,
      );
      await limiter.load();

      expect(limiter.isLockedOut, isTrue);
    });

    test('a tampered far-future lockedUntil is bounded', () async {
      final limiter = newLimiter();
      await limiter.load();
      await failTimes(limiter, 5);
      await storage.save(
        UnlockAttemptLimiter.lockedUntilKey,
        DateTime.utc(2099).toIso8601String(),
      );

      final restarted = newLimiter();
      await restarted.load();

      expect(restarted.remainingLockout(), const Duration(seconds: 30));
    });
  });
}

class _FakeClock {
  _FakeClock(this.now);

  DateTime now;

  DateTime call() => now;

  void advance(Duration delta) => now = now.add(delta);
}

class _InMemorySecureStorageService implements SecureStorageService {
  final Map<String, String> _values = {};

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> save(String key, String value) async {
    _values[key] = value;
  }
}

class _ThrowingSecureStorageService implements SecureStorageService {
  @override
  Future<void> delete(String key) => throw StateError('keystore unavailable');

  @override
  Future<String?> read(String key) => throw StateError('keystore unavailable');

  @override
  Future<void> save(String key, String value) =>
      throw StateError('keystore unavailable');
}
