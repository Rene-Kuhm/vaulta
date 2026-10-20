import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/unlock_attempt_limiter.dart';

void main() {
  late _InMemorySecureStorageService storage;
  late _FakeClocks clocks;

  UnlockAttemptLimiter newLimiter({SecureStorageService? backing}) =>
      UnlockAttemptLimiter(
        storage: backing ?? storage,
        clock: clocks.wall,
        monotonicClock: clocks.monotonic,
      );

  Future<bool> wrong() async => false;

  /// Records [times] failed attempts, waiting out any lockout in
  /// between (on both clocks) so every attempt actually runs.
  Future<void> failTimes(UnlockAttemptLimiter limiter, int times) async {
    for (var i = 0; i < times; i++) {
      final remaining = limiter.remainingLockout();
      if (remaining != null) {
        clocks.advance(remaining);
      }
      expect(await limiter.runAttempt(wrong), UnlockAttemptOutcome.failed);
    }
  }

  Map<String, Object?> persisted() =>
      jsonDecode(storage.values[UnlockAttemptLimiter.stateKey]!)
          as Map<String, Object?>;

  setUp(() {
    storage = _InMemorySecureStorageService();
    clocks = _FakeClocks(DateTime.utc(2026, 10, 19, 12));
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
      clocks.advance(const Duration(seconds: 29));
      expect(limiter.remainingLockout(), const Duration(seconds: 1));
      clocks.advance(const Duration(seconds: 1));
      expect(limiter.isLockedOut, isFalse);
    });

    test('lockout doubles per further failure', () async {
      final limiter = newLimiter();
      await limiter.load();
      await failTimes(limiter, 6);
      expect(limiter.remainingLockout(), const Duration(seconds: 60));

      await failTimes(limiter, 1);
      expect(limiter.remainingLockout(), const Duration(seconds: 120));
    });

    test('lockout is capped at 15 minutes', () async {
      final limiter = newLimiter();
      await limiter.load();

      await failTimes(limiter, 12);

      expect(limiter.failedCount, 12);
      expect(limiter.remainingLockout(), const Duration(minutes: 15));
    });

    test('success resets counter, lockout and the persisted value', () async {
      final limiter = newLimiter();
      await limiter.load();
      await failTimes(limiter, 6);
      clocks.advance(const Duration(minutes: 1));

      final outcome = await limiter.runAttempt(() async => true);

      expect(outcome, UnlockAttemptOutcome.succeeded);
      expect(limiter.failedCount, 0);
      expect(limiter.isLockedOut, isFalse);
      expect(storage.values, isNot(contains(UnlockAttemptLimiter.stateKey)));

      // A fresh failure after the reset is free again.
      await failTimes(limiter, 1);
      expect(limiter.isLockedOut, isFalse);
    });

    test('state persists as one JSON value across a new instance', () async {
      final first = newLimiter();
      await first.load();
      await failTimes(first, 6);
      clocks.advance(const Duration(seconds: 10));

      // Single key: there is no intermediate state a kill could leave.
      expect(storage.values.keys, [UnlockAttemptLimiter.stateKey]);
      expect(persisted()['failedCount'], 6);
      expect(persisted()['lockedUntil'], endsWith('Z'));

      final restarted = newLimiter();
      await restarted.load();

      expect(restarted.failedCount, 6);
      expect(restarted.lastFailureAt, first.lastFailureAt);
      expect(restarted.lockedUntil, first.lockedUntil);
      expect(restarted.lockedUntil!.isUtc, isTrue);
      expect(restarted.remainingLockout(), const Duration(seconds: 50));
    });

    test('attempt is persisted before verify runs (pre-increment)', () async {
      final limiter = newLimiter();
      await limiter.load();
      await failTimes(limiter, 2);

      Object? countSeenByVerify;
      final outcome = await limiter.runAttempt(() async {
        countSeenByVerify = persisted()['failedCount'];
        return false;
      });

      expect(countSeenByVerify, 3);
      expect(outcome, UnlockAttemptOutcome.failed);
      expect(persisted()['failedCount'], 3);
    });

    test('a verify that throws still counts as an attempt', () async {
      final limiter = newLimiter();
      await limiter.load();

      await expectLater(
        limiter.runAttempt(() async => throw StateError('kdf crashed')),
        throwsStateError,
      );

      expect(limiter.failedCount, 1);
      expect(persisted()['failedCount'], 1);
    });

    test('storage write failure rejects without running verify', () async {
      final failing = _InMemorySecureStorageService()..failSaves = true;
      final limiter = newLimiter(backing: failing);
      await limiter.load();
      var verifyCalls = 0;

      final outcome = await limiter.runAttempt(() async {
        verifyCalls++;
        return true;
      });

      expect(outcome, UnlockAttemptOutcome.storageFailure);
      expect(verifyCalls, 0);
      // The attempt that never ran is not counted.
      expect(limiter.failedCount, 0);
    });

    test('storage read failure rejects without running verify', () async {
      final failing = _InMemorySecureStorageService();
      final limiter = newLimiter(backing: failing);
      await limiter.load();
      failing.failReads = true;
      var verifyCalls = 0;

      final outcome = await limiter.runAttempt(() async {
        verifyCalls++;
        return true;
      });

      expect(outcome, UnlockAttemptOutcome.storageFailure);
      expect(verifyCalls, 0);
    });

    test('two instances sharing storage cannot reset each other', () async {
      // Desktop runners allow several app processes at once; each one
      // gets its own limiter over the same secure storage.
      final a = newLimiter();
      final b = newLimiter();
      await a.load();
      await b.load();

      await failTimes(a, 2);
      await failTimes(b, 2);
      await failTimes(a, 1);

      // b has only seen its own 2 failures in memory, but merges the
      // persisted 5 on its next attempt and is rejected.
      var verifyCalls = 0;
      final outcome = await b.runAttempt(() async {
        verifyCalls++;
        return true;
      });
      expect(outcome, UnlockAttemptOutcome.rejected);
      expect(verifyCalls, 0);
      expect(b.failedCount, 5);
      expect(persisted()['failedCount'], 5);

      // b's stale lower in-memory count never overwrites a's higher one.
      clocks.advance(const Duration(seconds: 30));
      await failTimes(b, 1);
      expect(persisted()['failedCount'], 6);
    });

    test('clock rollback keeps the device locked, never expired', () async {
      final limiter = newLimiter();
      await limiter.load();
      await failTimes(limiter, 5);

      // Attacker moves the device clock back a day.
      clocks.advanceWallOnly(const Duration(days: -1));

      expect(limiter.isLockedOut, isTrue);
      var verifyCalls = 0;
      final outcome = await limiter.runAttempt(() async {
        verifyCalls++;
        return true;
      });
      expect(outcome, UnlockAttemptOutcome.rejected);
      expect(verifyCalls, 0);

      // The lockout was re-anchored at the rolled-back "now", so it
      // still lasts its full duration in the new time frame.
      clocks.advance(const Duration(seconds: 29));
      expect(limiter.isLockedOut, isTrue);
      clocks.advance(const Duration(seconds: 1));
      expect(limiter.isLockedOut, isFalse);
    });

    test('clock rollback across a restart stays locked', () async {
      final first = newLimiter();
      await first.load();
      await failTimes(first, 7);

      clocks.advanceWallOnly(const Duration(hours: -3));
      final restarted = newLimiter();
      await restarted.load();

      expect(restarted.remainingLockout(), const Duration(seconds: 120));
    });

    group('clock ahead, then corrected backwards (e.g. by NTP)', () {
      // Ported from the security re-review repro: a future
      // lastFailureAt used to win every merge and lock the user out
      // until the wall clock caught up (months).
      Future<UnlockAttemptLimiter> lockedWhileClockAhead() async {
        clocks = _FakeClocks(DateTime.utc(2027, 1, 1));
        final limiter = newLimiter();
        await limiter.load();
        for (var i = 0; i < 5; i++) {
          expect(await limiter.runAttempt(wrong), UnlockAttemptOutcome.failed);
        }
        // NTP corrects the clock back to real time. No real time
        // passes on the monotonic clock.
        clocks.advanceWallOnly(
          DateTime.utc(2026, 10, 19, 12).difference(DateTime.utc(2027, 1, 1)),
        );
        return limiter;
      }

      Future<UnlockAttemptOutcome> correctPassword(UnlockAttemptLimiter l) =>
          l.runAttempt(() async => true);

      test(
        'locked now, unlocks after one lockout on the corrected clock',
        () async {
          final limiter = await lockedWhileClockAhead();

          expect(await correctPassword(limiter), UnlockAttemptOutcome.rejected);
          clocks.advance(const Duration(seconds: 29));
          expect(await correctPassword(limiter), UnlockAttemptOutcome.rejected);
          clocks.advance(const Duration(seconds: 1));
          expect(
            await correctPassword(limiter),
            UnlockAttemptOutcome.succeeded,
          );
        },
      );

      test(
        'the re-anchored state is persisted, not left in the future',
        () async {
          final limiter = await lockedWhileClockAhead();

          expect(limiter.isLockedOut, isTrue);
          await correctPassword(limiter);

          final stored = DateTime.parse(
            persisted()['lastFailureAt']! as String,
          );
          final storedUntil = DateTime.parse(
            persisted()['lockedUntil']! as String,
          );
          expect(stored, DateTime.utc(2026, 10, 19, 12));
          expect(storedUntil, DateTime.utc(2026, 10, 19, 12, 0, 30));
        },
      );

      test('an idle lock screen (no attempts) also unlocks in time', () async {
        final limiter = await lockedWhileClockAhead();

        // The unlock button is disabled while locked, so only
        // remainingLockout() is polled by the countdown.
        expect(limiter.remainingLockout(), const Duration(seconds: 30));
        clocks.advance(const Duration(seconds: 30));
        expect(limiter.isLockedOut, isFalse);
      });

      test('survives a restart with the same result', () async {
        await lockedWhileClockAhead();

        final restarted = newLimiter();
        await restarted.load();

        expect(restarted.remainingLockout(), const Duration(seconds: 30));
        expect(await correctPassword(restarted), UnlockAttemptOutcome.rejected);
        clocks.advance(const Duration(seconds: 30));
        expect(
          await correctPassword(restarted),
          UnlockAttemptOutcome.succeeded,
        );
      });

      test('a far-future stored lockedUntil is clamped on read', () async {
        final limiter = newLimiter();
        await limiter.load();
        await failTimes(limiter, 5);
        final state = persisted()
          ..['lastFailureAt'] = DateTime.utc(2099).toIso8601String()
          ..['lockedUntil'] = DateTime.utc(2099, 1, 2).toIso8601String();
        storage.values[UnlockAttemptLimiter.stateKey] = jsonEncode(state);

        expect(await correctPassword(limiter), UnlockAttemptOutcome.rejected);
        clocks.advance(const Duration(seconds: 30));
        expect(await correctPassword(limiter), UnlockAttemptOutcome.succeeded);
      });
    });

    test('forward clock jump does not end a lockout in-process', () async {
      final limiter = newLimiter();
      await limiter.load();
      await failTimes(limiter, 5);

      // Attacker moves the device clock forward a day; no real time
      // has passed on the monotonic clock.
      clocks.advanceWallOnly(const Duration(days: 1));

      expect(limiter.remainingLockout(), const Duration(seconds: 30));
      var verifyCalls = 0;
      final outcome = await limiter.runAttempt(() async {
        verifyCalls++;
        return true;
      });
      expect(outcome, UnlockAttemptOutcome.rejected);
      expect(verifyCalls, 0);

      clocks.advanceMonotonicOnly(const Duration(seconds: 30));
      expect(limiter.isLockedOut, isFalse);
    });

    test('loaded lockout is also enforced on the monotonic clock', () async {
      final first = newLimiter();
      await first.load();
      await failTimes(first, 5);
      clocks.advance(const Duration(seconds: 10));

      final restarted = newLimiter();
      await restarted.load();
      clocks.advanceWallOnly(const Duration(days: 1));

      expect(restarted.remainingLockout(), const Duration(seconds: 20));
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
      Future<bool> slowWrong() async {
        verifyCalls++;
        await Future<void>.delayed(Duration.zero);
        return false;
      }

      final outcomes = await Future.wait([
        limiter.runAttempt(slowWrong),
        limiter.runAttempt(slowWrong),
        limiter.runAttempt(slowWrong),
      ]);

      expect(verifyCalls, 1);
      expect(
        outcomes.where((o) => o == UnlockAttemptOutcome.rejected),
        hasLength(2),
      );
      expect(limiter.isLockedOut, isTrue);
    });

    test('corrupt persisted state fails closed into a lockout', () async {
      storage.values[UnlockAttemptLimiter.stateKey] = 'garbage';

      final limiter = newLimiter();
      await limiter.load();

      expect(limiter.isLockedOut, isTrue);
      expect(limiter.remainingLockout(), const Duration(seconds: 30));
      // The corrupt value was replaced so later merges read sane state.
      expect(persisted()['failedCount'], 5);
    });

    test('corrupt state written mid-session fails closed too', () async {
      final limiter = newLimiter();
      await limiter.load();
      storage.values[UnlockAttemptLimiter.stateKey] = '{"failedCount":"lots"}';

      final outcome = await limiter.runAttempt(() async => true);

      expect(outcome, UnlockAttemptOutcome.rejected);
      expect(limiter.isLockedOut, isTrue);
    });

    test('unreadable storage fails closed into a lockout', () async {
      final failing = _InMemorySecureStorageService()..failReads = true;
      final limiter = newLimiter(backing: failing);
      await limiter.load();

      expect(limiter.isLockedOut, isTrue);
    });

    test('a tampered far-future lockedUntil is bounded', () async {
      final limiter = newLimiter();
      await limiter.load();
      await failTimes(limiter, 5);
      final state = persisted()
        ..['lockedUntil'] = DateTime.utc(2099).toIso8601String();
      storage.values[UnlockAttemptLimiter.stateKey] = jsonEncode(state);
      clocks.advance(const Duration(seconds: 10));

      final restarted = newLimiter();
      await restarted.load();

      // Clamped to lastFailureAt + the scheduled 30 s, not 2099.
      expect(restarted.remainingLockout(), const Duration(seconds: 20));
    });
  });
}

class _FakeClocks {
  _FakeClocks(this._wall);

  DateTime _wall;
  Duration _monotonic = const Duration(hours: 1);

  DateTime wall() => _wall;

  Duration monotonic() => _monotonic;

  /// Real time passing: both clocks move.
  void advance(Duration delta) {
    _wall = _wall.add(delta);
    _monotonic += delta;
  }

  /// The user changed the device clock.
  void advanceWallOnly(Duration delta) => _wall = _wall.add(delta);

  void advanceMonotonicOnly(Duration delta) => _monotonic += delta;
}

class _InMemorySecureStorageService implements SecureStorageService {
  final Map<String, String> values = {};
  bool failSaves = false;
  bool failReads = false;

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('keystore unavailable');
    return values[key];
  }

  @override
  Future<void> save(String key, String value) async {
    if (failSaves) throw StateError('keystore unavailable');
    values[key] = value;
  }
}
