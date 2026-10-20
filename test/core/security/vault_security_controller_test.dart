import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:local_auth/local_auth.dart';

import 'package:cryptography/cryptography.dart';
import 'package:gestor_contrasenas/core/security/biometric_auth_service.dart';
import 'package:gestor_contrasenas/core/security/biometric_key_envelope_service.dart';
import 'package:gestor_contrasenas/core/security/biometric_unlock_service.dart';
import 'package:gestor_contrasenas/core/security/master_password_record.dart';
import 'package:gestor_contrasenas/core/security/master_password_service.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/unlock_attempt_limiter.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';
import 'package:gestor_contrasenas/core/security/vault_session.dart';

void main() {
  group('VaultSecurityController', () {
    test('creates and verifies master password flow', () async {
      final storage = _InMemorySecureStorageService();
      final controller = VaultSecurityController(
        storage: storage,
        masterPasswordService: MasterPasswordService.test(),
        biometricAuthService: const _FakeBiometricAuthService(),
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      final created = await controller.createMasterPassword(
        password: 'StrongPass!2026',
        confirmation: 'StrongPass!2026',
        enableBiometrics: true,
      );

      expect(created, isTrue);
      expect(controller.isUnlocked, isTrue);
      expect(
        await storage.read(VaultSecurityController.masterPasswordRecordKey),
        isNotNull,
      );

      await controller.lock();

      final unlocked = await controller.unlockWithPassword('StrongPass!2026');

      expect(unlocked, isTrue);
      expect(controller.isUnlocked, isTrue);
    });

    test(
      'biometric unlock reports unavailable when no envelope is enrolled',
      () async {
        final controller = VaultSecurityController(
          storage: _InMemorySecureStorageService(),
          masterPasswordService: MasterPasswordService.test(),
          biometricAuthService: const _FakeBiometricAuthService(),
        );
        addTearDown(controller.dispose);

        await controller.initialize();
        await controller.createMasterPassword(
          password: 'StrongPass!2026',
          confirmation: 'StrongPass!2026',
          enableBiometrics: true,
        );
        await controller.lock();

        final unlocked = await controller.unlockWithBiometrics();

        expect(unlocked, isFalse);
        expect(controller.stage, VaultSecurityStage.locked);
        expect(controller.vaultSession, isNull);
        expect(controller.message, contains('biometr'));
      },
    );

    test('change master password invalidates a previously enrolled envelope',
        () async {
      final storage = _InMemorySecureStorageService();
      final controller = VaultSecurityController(
        storage: storage,
        masterPasswordService: MasterPasswordService.test(),
        biometricAuthService: const _FakeBiometricAuthService(),
        rekeyEntries: ({required sourceSession, required targetSession}) async {
          // No-op: the test does not need to rekey real items.
        },
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createMasterPassword(
        password: 'StrongPass!2026',
        confirmation: 'StrongPass!2026',
        enableBiometrics: true,
      );
      await storage.save(
        'vault_biometric_envelope_v1',
        '{"version":1,"alg":"AES-256-GCM","salt_b64":"AA==",'
        '"nonce_b64":"AA==","ciphertext_b64":"AA==","tag_b64":"AA=="}',
      );

      final changed = await controller.changeMasterPassword(
        currentPassword: 'StrongPass!2026',
        newPassword: 'AnotherStrong!2027',
        confirmation: 'AnotherStrong!2027',
      );

      expect(changed, isTrue);
      expect(
        await storage.read('vault_biometric_envelope_v1'),
        isNull,
      );
    });

    test('rejects weak master passwords', () async {
      final controller = VaultSecurityController(
        storage: _InMemorySecureStorageService(),
        masterPasswordService: MasterPasswordService.test(),
        biometricAuthService: const _FakeBiometricAuthService(),
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      final created = await controller.createMasterPassword(
        password: 'weak',
        confirmation: 'weak',
        enableBiometrics: false,
      );

      expect(created, isFalse);
      expect(controller.stage, VaultSecurityStage.onboarding);
      expect(controller.message, contains('12'));
    });

    test('locks on lifecycle background states when enabled', () async {
      final controller = VaultSecurityController(
        storage: _InMemorySecureStorageService(),
        masterPasswordService: MasterPasswordService.test(),
        biometricAuthService: const _FakeBiometricAuthService(),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createMasterPassword(
        password: 'StrongPass!2026',
        confirmation: 'StrongPass!2026',
        enableBiometrics: false,
      );

      expect(controller.isUnlocked, isTrue);

      await controller.handleAppLifecycleState(AppLifecycleState.paused);

      expect(controller.stage, VaultSecurityStage.locked);
      expect(
        controller.message,
        contains('bloqueada automaticamente al salir de primer plano'),
      );
    });

    test(
      'does not lock on lifecycle when background auto-lock disabled',
      () async {
        final controller = VaultSecurityController(
          storage: _InMemorySecureStorageService(),
          masterPasswordService: MasterPasswordService.test(),
          biometricAuthService: const _FakeBiometricAuthService(),
        );
        addTearDown(controller.dispose);

        await controller.initialize();
        await controller.createMasterPassword(
          password: 'StrongPass!2026',
          confirmation: 'StrongPass!2026',
          enableBiometrics: false,
        );
        await controller.setAutoLockOnBackgroundEnabled(false);

        await controller.handleAppLifecycleState(AppLifecycleState.paused);

        expect(controller.stage, VaultSecurityStage.unlocked);
      },
    );

    test('locks after idle timeout and resets countdown on activity', () async {
      final controller = VaultSecurityController(
        storage: _InMemorySecureStorageService(),
        masterPasswordService: MasterPasswordService.test(),
        biometricAuthService: const _FakeBiometricAuthService(),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createMasterPassword(
        password: 'StrongPass!2026',
        confirmation: 'StrongPass!2026',
        enableBiometrics: false,
      );
      await controller.setIdleTimeoutSeconds(1);

      await Future<void>.delayed(const Duration(milliseconds: 800));
      controller.registerUserInteraction();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(controller.stage, VaultSecurityStage.unlocked);

      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(controller.stage, VaultSecurityStage.locked);
      expect(controller.message, contains('inactividad'));
    });

    test('does not lock on idle when idle auto-lock is disabled', () async {
      final controller = VaultSecurityController(
        storage: _InMemorySecureStorageService(),
        masterPasswordService: MasterPasswordService.test(),
        biometricAuthService: const _FakeBiometricAuthService(),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createMasterPassword(
        password: 'StrongPass!2026',
        confirmation: 'StrongPass!2026',
        enableBiometrics: false,
      );
      await controller.setIdleTimeoutSeconds(0);

      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(controller.stage, VaultSecurityStage.unlocked);
    });

    test('changes master password and keeps session unlocked', () async {
      var rekeyCalls = 0;
      String? sourceKeyId;
      String? targetKeyId;

      final storage = _InMemorySecureStorageService();
      final controller = VaultSecurityController(
        storage: storage,
        masterPasswordService: MasterPasswordService.test(),
        biometricAuthService: const _FakeBiometricAuthService(),
        rekeyEntries: ({required sourceSession, required targetSession}) async {
          rekeyCalls += 1;
          sourceKeyId = sourceSession.keyId;
          targetKeyId = targetSession.keyId;
        },
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createMasterPassword(
        password: 'StrongPass!2026',
        confirmation: 'StrongPass!2026',
        enableBiometrics: false,
      );

      final changed = await controller.changeMasterPassword(
        currentPassword: 'StrongPass!2026',
        newPassword: 'AnotherStrong!2027',
        confirmation: 'AnotherStrong!2027',
      );

      expect(changed, isTrue);
      expect(rekeyCalls, 1);
      expect(sourceKeyId, isNotNull);
      expect(targetKeyId, isNotNull);
      expect(targetKeyId, isNot(equals(sourceKeyId)));
      expect(controller.isUnlocked, isTrue);

      await controller.lock();
      final oldUnlock = await controller.unlockWithPassword('StrongPass!2026');
      final newUnlock = await controller.unlockWithPassword(
        'AnotherStrong!2027',
      );

      expect(oldUnlock, isFalse);
      expect(newUnlock, isTrue);
    });

    test('rejects change when current master password is wrong', () async {
      var rekeyCalls = 0;
      final controller = VaultSecurityController(
        storage: _InMemorySecureStorageService(),
        masterPasswordService: MasterPasswordService.test(),
        biometricAuthService: const _FakeBiometricAuthService(),
        rekeyEntries: ({required sourceSession, required targetSession}) async {
          rekeyCalls += 1;
        },
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createMasterPassword(
        password: 'StrongPass!2026',
        confirmation: 'StrongPass!2026',
        enableBiometrics: false,
      );

      final changed = await controller.changeMasterPassword(
        currentPassword: 'WrongPass!2026',
        newPassword: 'AnotherStrong!2027',
        confirmation: 'AnotherStrong!2027',
      );

      expect(changed, isFalse);
      expect(rekeyCalls, 0);
      expect(controller.message, contains('actual no coincide'));
    });
  });

  group('VaultSecurityController unlock throttling', () {
    late _InMemorySecureStorageService storage;
    late _CountingMasterPasswordService passwords;
    late DateTime now;

    VaultSecurityController buildController({
      BiometricUnlockService? biometricUnlockService,
    }) {
      final controller = VaultSecurityController(
        storage: storage,
        masterPasswordService: passwords,
        biometricAuthService: const _FakeBiometricAuthService(),
        biometricUnlockService: biometricUnlockService,
        unlockAttemptLimiter: UnlockAttemptLimiter(
          storage: storage,
          clock: () => now,
          // Real time passing moves both clocks in these tests.
          monotonicClock: () => now.difference(DateTime.utc(2026)),
        ),
      );
      addTearDown(controller.dispose);
      return controller;
    }

    Future<VaultSecurityController> lockedVault({
      BiometricUnlockService? biometricUnlockService,
    }) async {
      final controller = buildController(
        biometricUnlockService: biometricUnlockService,
      );
      await controller.initialize();
      await controller.createMasterPassword(
        password: 'StrongPass!2026',
        confirmation: 'StrongPass!2026',
        enableBiometrics: false,
      );
      await controller.lock();
      return controller;
    }

    setUp(() {
      storage = _InMemorySecureStorageService();
      passwords = _CountingMasterPasswordService();
      now = DateTime.utc(2026, 10, 19, 12);
    });

    test('locks out after the fifth failure without running KDF', () async {
      final controller = await lockedVault();

      for (var i = 0; i < 5; i++) {
        expect(await controller.unlockWithPassword('WrongPass!2026'), isFalse);
      }
      expect(passwords.verifyCalls, 5);
      expect(controller.failedUnlockAttempts, 5);
      expect(controller.unlockLockoutRemaining, const Duration(seconds: 30));

      // Even the correct password is rejected during the lockout, and
      // no Argon2id verification runs.
      expect(await controller.unlockWithPassword('StrongPass!2026'), isFalse);
      expect(passwords.verifyCalls, 5);
      expect(controller.isUnlocked, isFalse);

      now = now.add(const Duration(seconds: 30));
      expect(await controller.unlockWithPassword('StrongPass!2026'), isTrue);
      expect(controller.failedUnlockAttempts, 0);
      expect(controller.isUnlockLockedOut, isFalse);
    });

    test('lockout survives a controller restart', () async {
      final controller = await lockedVault();
      for (var i = 0; i < 5; i++) {
        await controller.unlockWithPassword('WrongPass!2026');
      }

      final restarted = buildController();
      await restarted.initialize();

      expect(restarted.stage, VaultSecurityStage.locked);
      expect(restarted.isUnlockLockedOut, isTrue);
      final callsBefore = passwords.verifyCalls;
      expect(await restarted.unlockWithPassword('StrongPass!2026'), isFalse);
      expect(passwords.verifyCalls, callsBefore);
    });

    test('biometric setup on the lock screen is throttled too', () async {
      final controller = await lockedVault();
      for (var i = 0; i < 5; i++) {
        await controller.unlockWithPassword('WrongPass!2026');
      }

      expect(
        await controller.setupBiometricFromPassword('StrongPass!2026'),
        isFalse,
      );
      expect(passwords.verifyCalls, 5);
    });

    test('changeMasterPassword shares the throttle', () async {
      final controller = buildController();
      await controller.initialize();
      await controller.createMasterPassword(
        password: 'StrongPass!2026',
        confirmation: 'StrongPass!2026',
        enableBiometrics: false,
      );

      for (var i = 0; i < 5; i++) {
        expect(
          await controller.changeMasterPassword(
            currentPassword: 'WrongPass!2026',
            newPassword: 'AnotherStrong!2027',
            confirmation: 'AnotherStrong!2027',
          ),
          isFalse,
        );
      }
      expect(passwords.verifyCalls, 5);
      expect(controller.isUnlockLockedOut, isTrue);

      expect(
        await controller.changeMasterPassword(
          currentPassword: 'StrongPass!2026',
          newPassword: 'AnotherStrong!2027',
          confirmation: 'AnotherStrong!2027',
        ),
        isFalse,
      );
      expect(passwords.verifyCalls, 5);
      expect(controller.message, isNull);
    });

    test('storage failure rejects without verify and flags it', () async {
      final controller = await lockedVault();
      storage.failSaves = true;

      expect(await controller.unlockWithPassword('StrongPass!2026'), isFalse);

      expect(passwords.verifyCalls, 0);
      expect(controller.isUnlocked, isFalse);
      expect(controller.unlockAttemptStateUnavailable, isTrue);
      expect(controller.message, isNull);

      storage.failSaves = false;
      expect(await controller.unlockWithPassword('StrongPass!2026'), isTrue);
      expect(controller.unlockAttemptStateUnavailable, isFalse);
    });

    test('successful biometric unlock resets the counter', () async {
      final unlocker = _SucceedingBiometricUnlockService(storage);
      final controller = await lockedVault(biometricUnlockService: unlocker);
      for (var i = 0; i < 6; i++) {
        await controller.unlockWithPassword('WrongPass!2026');
      }
      expect(controller.isUnlockLockedOut, isTrue);

      expect(await controller.unlockWithBiometrics(), isTrue);

      expect(controller.failedUnlockAttempts, 0);
      expect(controller.isUnlockLockedOut, isFalse);
      expect(
        await storage.read(UnlockAttemptLimiter.stateKey),
        isNull,
      );
    });
  });
}

class _CountingMasterPasswordService extends MasterPasswordService {
  _CountingMasterPasswordService()
    : super(
        verifierIterations: 1,
        encryptionIterations: 1,
        argon2MemoryKiB: 1024,
        useFastTestKdf: true,
      );

  int verifyCalls = 0;

  @override
  Future<bool> verify({
    required MasterPasswordRecord record,
    required String password,
  }) {
    verifyCalls++;
    return super.verify(record: record, password: password);
  }
}

class _SucceedingBiometricUnlockService extends BiometricUnlockService {
  _SucceedingBiometricUnlockService(SecureStorageService storage)
    : super(
        storage: storage,
        biometricAuthService: const _FakeBiometricAuthService(),
        envelopeService: BiometricKeyEnvelopeService(storage: storage),
      );

  @override
  Future<BiometricUnlockOutcome> unlock({
    required MasterPasswordRecord record,
  }) async {
    return BiometricUnlockSuccess(
      VaultSession(
        keyId: record.keyId,
        secretKey: SecretKey(List.filled(32, 7)),
      ),
    );
  }
}

class _InMemorySecureStorageService implements SecureStorageService {
  final Map<String, String> _values = {};

  /// When true, writes of the unlock attempt state throw, simulating
  /// an unavailable keystore.
  bool failSaves = false;

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> save(String key, String value) async {
    if (failSaves && key == UnlockAttemptLimiter.stateKey) {
      throw StateError('keystore unavailable');
    }
    _values[key] = value;
  }
}

class _FakeBiometricAuthService implements BiometricAuthService {
  const _FakeBiometricAuthService();

  @override
  Future<bool> authenticateForUnlock() async => true;

  @override
  Future<BiometricAvailability> getAvailability() async {
    return const BiometricAvailability(
      deviceSupported: true,
      canCheckBiometrics: true,
      availableBiometrics: [BiometricType.strong],
    );
  }
}
