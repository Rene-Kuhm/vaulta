import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:local_auth/local_auth.dart';

import 'package:cryptography/cryptography.dart';
import 'package:gestor_contrasenas/core/security/android_keystore_envelope_key_provider.dart';
import 'package:gestor_contrasenas/core/security/biometric_auth_service.dart';
import 'package:gestor_contrasenas/core/security/biometric_key_envelope_service.dart';
import 'package:gestor_contrasenas/core/security/biometric_unlock_service.dart';
import 'package:gestor_contrasenas/core/security/master_password_record.dart';
import 'package:gestor_contrasenas/core/security/master_password_service.dart';
import 'package:gestor_contrasenas/core/security/native_biometric_auth_service.dart';
import 'package:gestor_contrasenas/core/security/platform_security_plan.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/unlock_attempt_limiter.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';
import 'package:gestor_contrasenas/core/security/vault_security_message.dart';
import 'package:gestor_contrasenas/core/security/vault_session.dart';

void main() {
  // The capability probe tests below stand in fake `MethodChannel`s for the
  // Android KeyStore and BiometricPrompt sides of the app, which needs the
  // test binding. Plain async tests are unaffected by it.
  TestWidgetsFlutterBinding.ensureInitialized();

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

    test('runs the item payload migration after each unlock', () async {
      final sessionsSeen = <VaultSession?>[];
      late final VaultSecurityController controller;
      controller = VaultSecurityController(
        storage: _InMemorySecureStorageService(),
        masterPasswordService: MasterPasswordService.test(),
        biometricAuthService: const _FakeBiometricAuthService(),
        migrateEntries: () async => sessionsSeen.add(controller.vaultSession),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createMasterPassword(
        password: 'StrongPass!2026',
        confirmation: 'StrongPass!2026',
        enableBiometrics: false,
      );
      await controller.lock();
      final unlocked = await controller.unlockWithPassword('StrongPass!2026');

      expect(unlocked, isTrue);
      expect(sessionsSeen, hasLength(2));
      // The hook runs against the freshly activated session.
      expect(sessionsSeen, everyElement(isNotNull));
    });

    test('stays locked when the item payload migration fails', () async {
      var failMigration = false;
      final controller = VaultSecurityController(
        storage: _InMemorySecureStorageService(),
        masterPasswordService: MasterPasswordService.test(),
        biometricAuthService: const _FakeBiometricAuthService(),
        migrateEntries: () async {
          if (failMigration) {
            throw StateError('storage unavailable');
          }
        },
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createMasterPassword(
        password: 'StrongPass!2026',
        confirmation: 'StrongPass!2026',
        enableBiometrics: false,
      );
      await controller.lock();
      failMigration = true;

      final unlocked = await controller.unlockWithPassword('StrongPass!2026');

      expect(unlocked, isFalse);
      expect(controller.stage, VaultSecurityStage.locked);
      expect(controller.vaultSession, isNull);
      expect(
        controller.message?.code,
        VaultSecurityMessageCode.itemsMigrationFailed,
      );

      failMigration = false;
      expect(await controller.unlockWithPassword('StrongPass!2026'), isTrue);
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
        expect(
          controller.message?.code,
          VaultSecurityMessageCode.biometricUnlockNotWired,
        );
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
      expect(
        controller.message?.code,
        VaultSecurityMessageCode.masterPasswordTooShort,
      );
      expect(controller.message?.detail, '12');
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
        controller.message?.code,
        VaultSecurityMessageCode.vaultLockedOnBackground,
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
      expect(
        controller.message?.code,
        VaultSecurityMessageCode.vaultLockedOnIdle,
      );
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
      expect(
        controller.message?.code,
        VaultSecurityMessageCode.currentPasswordMismatch,
      );
    });

    // The three failure branches below share [_rekeyThenPersistRecord]
    // with the v2 rewrite path, so they are pinned here to prove the
    // extraction did not change what changeMasterPassword does.
    group('change master password failure branches', () {
      const current = 'StrongPass!2026';
      const replacement = 'AnotherStrong!2027';

      /// Unlocks a fresh vault with [current] as the master password and
      /// [onRekey] wired as the repository rekey hook.
      Future<VaultSecurityController> unlockedVault({
        required Future<void> Function({
          required VaultSession sourceSession,
          required VaultSession targetSession,
        }) onRekey,
        required _InMemorySecureStorageService store,
      }) async {
        final controller = VaultSecurityController(
          storage: store,
          masterPasswordService: MasterPasswordService.test(),
          biometricAuthService: const _FakeBiometricAuthService(),
          rekeyEntries:
              ({required sourceSession, required targetSession}) =>
                  onRekey(
                    sourceSession: sourceSession,
                    targetSession: targetSession,
                  ),
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        await controller.createMasterPassword(
          password: current,
          confirmation: current,
          enableBiometrics: false,
        );
        return controller;
      }

      test('a failed rekey keeps the vault unlocked on the old key',
          () async {
        final store = _InMemorySecureStorageService();
        final controller = await unlockedVault(
          store: store,
          onRekey:
              ({required sourceSession, required targetSession}) async =>
                  throw StateError('keystore unavailable'),
        );
        final keyIdBefore = controller.vaultSession!.keyId;

        final changed = await controller.changeMasterPassword(
          currentPassword: current,
          newPassword: replacement,
          confirmation: replacement,
        );

        expect(changed, isFalse);
        expect(controller.isUnlocked, isTrue);
        expect(controller.vaultSession!.keyId, keyIdBefore);
        expect(
          controller.message?.code,
          VaultSecurityMessageCode.rekeyFailed,
        );
        // Nothing was persisted, so the old password still opens it.
        expect(await controller.unlockWithPassword(current), isTrue);
      });

      test('a failed record write rolls back and keeps the old key',
          () async {
        final store = _InMemorySecureStorageService();
        final rekeyed = <String>[];
        final controller = await unlockedVault(
          store: store,
          onRekey:
              ({required sourceSession, required targetSession}) async {
                rekeyed.add(targetSession.keyId);
              },
        );
        final keyIdBefore = controller.vaultSession!.keyId;
        store.failRecordSaves = true;

        final changed = await controller.changeMasterPassword(
          currentPassword: current,
          newPassword: replacement,
          confirmation: replacement,
        );

        expect(changed, isFalse);
        expect(controller.isUnlocked, isTrue);
        expect(controller.vaultSession!.keyId, keyIdBefore);
        expect(
          controller.message?.code,
          VaultSecurityMessageCode.recordSaveFailed,
        );
        expect(rekeyed, hasLength(2));
        expect(rekeyed.last, keyIdBefore, reason: 'the undo targets the old key');
        store.failRecordSaves = false;
        expect(await controller.unlockWithPassword(current), isTrue);
        expect(
          await controller.unlockWithPassword(replacement),
          isFalse,
          reason: 'the new password was never persisted',
        );
      });

      test('a failed rollback locks the vault by design', () async {
        final store = _InMemorySecureStorageService();
        var calls = 0;
        final controller = await unlockedVault(
          store: store,
          onRekey: ({required sourceSession, required targetSession}) async {
            calls += 1;
            if (calls == 2) {
              // The forward rewrite committed; the undo does not.
              throw StateError('keystore unavailable');
            }
          },
        );
        store.failRecordSaves = true;

        final changed = await controller.changeMasterPassword(
          currentPassword: current,
          newPassword: replacement,
          confirmation: replacement,
        );

        expect(changed, isFalse);
        expect(controller.stage, VaultSecurityStage.locked);
        expect(controller.vaultSession, isNull);
        expect(
          controller.message?.code,
          VaultSecurityMessageCode.rekeyRollbackFailed,
        );
      });
    });

    test('an already-current record is not rewritten on unlock', () async {
      var rekeyCalls = 0;
      final storage = _InMemorySecureStorageService();
      final controller = VaultSecurityController(
        storage: storage,
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
      final keyId = controller.vaultSession!.keyId;
      await controller.lock();

      expect(await controller.unlockWithPassword('StrongPass!2026'), isTrue);

      expect(rekeyCalls, 0, reason: 'a v3 record has nothing to migrate');
      expect(controller.vaultSession!.keyId, keyId);
      expect(
        controller.message?.code,
        VaultSecurityMessageCode.vaultUnlocked,
      );
      expect(controller.messageIsError, isFalse);
    });
  });


  group('VaultSecurityController cannot-open-vault reporting', () {
    const password = 'StrongPass!2026';

    /// Creates a vault and leaves the controller locked, returning the stored
    /// record so a test can damage one field of it.
    Future<(VaultSecurityController, _InMemorySecureStorageService)>
    buildLockedVault() async {
      final storage = _InMemorySecureStorageService();
      final controller = VaultSecurityController(
        storage: storage,
        masterPasswordService: MasterPasswordService.test(),
        biometricAuthService: const _FakeBiometricAuthService(),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createMasterPassword(
        password: password,
        confirmation: password,
        enableBiometrics: false,
      );
      await controller.lock();
      return (controller, storage);
    }

    Future<MasterPasswordRecord> storedRecord(
      _InMemorySecureStorageService storage,
    ) async {
      final raw = await storage.read(
        VaultSecurityController.masterPasswordRecordKey,
      );
      return MasterPasswordRecord.decode(raw!);
    }

    /// Rewrites the stored record, keeping the verifier intact so the
    /// password check still passes and only the DEK wrap is damaged.
    Future<void> damageStoredRecord(
      _InMemorySecureStorageService storage,
      Map<String, dynamic> Function(Map<String, dynamic> wrap) damage,
    ) async {
      final record = await storedRecord(storage);
      final damaged = MasterPasswordRecord(
        version: record.version,
        verifierIterations: record.verifierIterations,
        verifierSalt: record.verifierSalt,
        verifier: record.verifier,
        encryptionIterations: record.encryptionIterations,
        encryptionSalt: record.encryptionSalt,
        keyId: record.keyId,
        createdAt: record.createdAt,
        kdf: record.kdf,
        dekWrap: damage(Map<String, dynamic>.from(record.dekWrap!)),
        pwNorm: record.pwNorm,
      );
      await storage.save(
        VaultSecurityController.masterPasswordRecordKey,
        damaged.encode(),
      );
    }

    test(
      'a corrupt wrapped DEK reports a typed error instead of throwing',
      () async {
        final (controller, storage) = await buildLockedVault();
        // The tag is the AEAD authenticator: replacing it makes the unwrap
        // fail the way a tampered or truncated record does on a real device.
        await damageStoredRecord(
          storage,
          (wrap) => {...wrap, 'tag_b64': base64Encode(List<int>.filled(16, 7))},
        );

        // The whole point: the old code threw out of unlockWithPassword here,
        // so the widget layer rendered a raw crypto exception.
        final unlocked = await controller.unlockWithPassword(password);

        expect(unlocked, isFalse);
        expect(controller.stage, VaultSecurityStage.locked);
        expect(controller.vaultSession, isNull);
        expect(
          controller.message?.code,
          VaultSecurityMessageCode.vaultCannotBeOpened,
        );
        expect(controller.messageIsError, isTrue);
      },
    );

    test(
      'a record with no wrapped DEK at all reports the same typed error',
      () async {
        final (controller, storage) = await buildLockedVault();
        final record = await storedRecord(storage);
        final stripped = MasterPasswordRecord(
          version: record.version,
          verifierIterations: record.verifierIterations,
          verifierSalt: record.verifierSalt,
          verifier: record.verifier,
          encryptionIterations: record.encryptionIterations,
          encryptionSalt: record.encryptionSalt,
          keyId: record.keyId,
          createdAt: record.createdAt,
          kdf: record.kdf,
          pwNorm: record.pwNorm,
        );
        await storage.save(
          VaultSecurityController.masterPasswordRecordKey,
          stripped.encode(),
        );

        final unlocked = await controller.unlockWithPassword(password);

        expect(unlocked, isFalse);
        expect(controller.stage, VaultSecurityStage.locked);
        expect(
          controller.message?.code,
          VaultSecurityMessageCode.vaultCannotBeOpened,
        );
      },
    );

    test('a damaged record still refuses a wrong password as a mismatch',
        () async {
      // The corruption must not turn every attempt into "cannot be opened":
      // a wrong password has to keep being reported as a wrong password, or
      // the throttled path would stop distinguishing them.
      final (controller, storage) = await buildLockedVault();
      await damageStoredRecord(
        storage,
        (wrap) => {...wrap, 'tag_b64': base64Encode(List<int>.filled(16, 7))},
      );

      final unlocked = await controller.unlockWithPassword('WrongPass!2026');

      expect(unlocked, isFalse);
      expect(
        controller.message?.code,
        VaultSecurityMessageCode.passwordMismatch,
      );
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

  group('v2 record rewrite on unlock', () {
    // A v2 master-password record is what the previous release wrote:
    // Argon2id over the RAW password bytes, the 32-byte KDF output used
    // directly as the KEK (no HKDF split), and a DEK wrapped under it.
    // `pwNorm` is absent, so `isCurrentFormat` is false and the unlock
    // path has to rewrite it. The records here are real — real Argon2id,
    // real AES-GCM wrap — because the whole point of the boundary is
    // that the derived DEK has to match byte for byte.
    const password = 'StrongPass!2026';
    const v2Salt = [11, 22, 33, 44, 55, 66, 77, 88, 1, 2, 3, 4, 5, 6, 7, 8];

    /// Real Argon2id with tiny parameters. `MasterPasswordService.test()`
    /// uses a stub KDF that cannot interoperate with a record written by
    /// real Argon2id, so a test that hands a real v2 record to the
    /// controller must hand it a real-KDF service too.
    final realKdf = MasterPasswordService(
      encryptionIterations: 1,
      argon2MemoryKiB: 1024,
      argon2Parallelism: 1,
    );

    late _InMemorySecureStorageService storage;
    late List<int> legacyDek;

    Future<MasterPasswordRecord> buildV2Record() async {
      final kek = await Argon2id(
        memory: 1024,
        parallelism: 1,
        iterations: 1,
        hashLength: 32,
      ).deriveKeyFromPassword(password: password, nonce: v2Salt);
      final verifier = await Argon2id(
        memory: 1024,
        parallelism: 1,
        iterations: 1,
        hashLength: 32,
      ).deriveKeyFromPassword(password: password, nonce: v2Salt);
      final box = await AesGcm.with256bits().encrypt(
        legacyDek,
        secretKey: kek,
      );
      return MasterPasswordRecord(
        version: 2,
        verifierIterations: 1,
        verifierSalt: base64Encode(v2Salt),
        verifier: base64Encode(await verifier.extractBytes()),
        encryptionIterations: 1,
        encryptionSalt: base64Encode(v2Salt),
        keyId: 'legacy-v2-key',
        createdAt: DateTime.utc(2025),
        kdf: {
          'name': 'argon2id',
          'salt_b64': base64Encode(v2Salt),
          'memory_kib': 1024,
          'iterations': 1,
          'parallelism': 1,
          'dk_len': 32,
        },
        dekWrap: {
          'alg': 'AES-256-GCM',
          'nonce_b64': base64Encode(box.nonce),
          'ciphertext_b64': base64Encode(box.cipherText),
          'tag_b64': base64Encode(box.mac.bytes),
        },
      );
    }

    setUp(() async {
      storage = _InMemorySecureStorageService();
      legacyDek = List<int>.generate(32, (i) => i + 1);
      await storage.save(
        VaultSecurityController.masterPasswordRecordKey,
        (await buildV2Record()).encode(),
      );
    });

    /// Builds a controller whose repository rekey hook records every
    /// call instead of touching storage, plus the record on disk after
    /// each unlock so tests can assert on what was persisted.
    ({VaultSecurityController controller, List<({String from, String to})> rekeys})
        buildLockedVault({
      Future<void> Function({
        required VaultSession sourceSession,
        required VaultSession targetSession,
      })? onRekey,
      BiometricUnlockService? unlocker,
      MasterPasswordService? passwords,
    }) {
      final rekeys = <({String from, String to})>[];
      final controller = VaultSecurityController(
        storage: storage,
        masterPasswordService: passwords ?? realKdf,
        biometricAuthService: const _FakeBiometricAuthService(),
        biometricUnlockService: unlocker,
        rekeyEntries:
            ({required sourceSession, required targetSession}) async {
          rekeys.add((from: sourceSession.keyId, to: targetSession.keyId));
          await onRekey?.call(
            sourceSession: sourceSession,
            targetSession: targetSession,
          );
        },
      );
      addTearDown(controller.dispose);
      return (controller: controller, rekeys: rekeys);
    }

    Future<MasterPasswordRecord> readPersistedRecord() async {
      final raw = await storage.read(
        VaultSecurityController.masterPasswordRecordKey,
      );
      return MasterPasswordRecord.decode(raw!);
    }

    test('the v2 record on disk is not in the current format', () async {
      // Sanity: the premise of every other test in this group. If this
      // ever stops holding, the rewrite assertions below prove nothing.
      final record = await readPersistedRecord();

      expect(record.version, 2);
      expect(record.pwNorm, isNull);
      expect(record.isCurrentFormat, isFalse);
    });

    test('unlocking with the password rewrites the record as v3',
        () async {
      final vault = buildLockedVault();
      await vault.controller.initialize();

      expect(await vault.controller.unlockWithPassword(password), isTrue);

      final rewritten = await readPersistedRecord();
      expect(rewritten.version, 3);
      expect(rewritten.isCurrentFormat, isTrue);
      expect(rewritten.pwNorm, MasterPasswordRecord.nfcMarker);
      expect(rewritten.kdf!['split'], 'hkdf-sha256-v3');
      expect(rewritten.kdf!['dk_len'], 64);
      // One Argon2id run now feeds both halves, so all three salts are
      // the same value — the structural proof of the v3 split.
      expect(rewritten.verifierSalt, rewritten.kdf!['salt_b64']);
      expect(rewritten.encryptionSalt, rewritten.kdf!['salt_b64']);
      expect(rewritten.keyId, isNot('legacy-v2-key'));
    });

    test('the same password still unlocks the rewritten record', () async {
      final vault = buildLockedVault();
      await vault.controller.initialize();

      expect(await vault.controller.unlockWithPassword(password), isTrue);
      await vault.controller.lock();

      // Second unlock reads the *rewritten* record off disk, so this
      // proves the persisted v3 record is self-consistent rather than
      // just that a migration ran.
      final restarted = buildLockedVault();
      await restarted.controller.initialize();
      expect(await restarted.controller.unlockWithPassword(password), isTrue);
      expect(restarted.rekeys, isEmpty, reason: 'already v3: nothing to rekey');
    });

    test('the entries are rekeyed from the old key to the new one', () async {
      final vault = buildLockedVault();
      await vault.controller.initialize();

      expect(await vault.controller.unlockWithPassword(password), isTrue);

      expect(vault.rekeys, hasLength(1));
      expect(vault.rekeys.single.from, 'legacy-v2-key');
      expect(
        (await readPersistedRecord()).keyId,
        vault.rekeys.single.to,
      );
    });

    test('the session that opens the vault carries the new DEK', () async {
      final vault = buildLockedVault();
      await vault.controller.initialize();

      expect(await vault.controller.unlockWithPassword(password), isTrue);

      final session = vault.controller.vaultSession!;
      final rewritten = await readPersistedRecord();
      expect(session.keyId, rewritten.keyId);
      // The DEK is the v3 one: re-deriving it from the rewritten record
      // with the same password must reproduce the in-memory bytes.
      expect(
        await session.secretKey.extractBytes(),
        await (await realKdf.deriveVaultKey(
          record: rewritten,
          password: password,
        )).extractBytes(),
      );
      expect(
        await session.secretKey.extractBytes(),
        isNot(legacyDek),
        reason: 'a rewritten record wraps a fresh DEK, not the v2 one',
      );
    });

    test('a wrong password rewrites nothing at all', () async {
      final before = await readPersistedRecord();
      final vault = buildLockedVault();
      await vault.controller.initialize();

      expect(await vault.controller.unlockWithPassword('WrongPass!2026'),
          isFalse);

      expect(vault.rekeys, isEmpty);
      expect((await readPersistedRecord()).version, 2);
      expect((await readPersistedRecord()).keyId, before.keyId);
      expect(vault.controller.vaultSession, isNull);
    });

    test('a failed rekey leaves the v2 record on disk and still unlocks',
        () async {
      // Fail-safe: not migrating is a strictly better outcome than a
      // half-migrated vault. The v2 scheme still works, so a failed
      // rewrite must be invisible to the user's unlock.
      final vault = buildLockedVault(
        onRekey: ({required sourceSession, required targetSession}) async {
          throw StateError('keystore unavailable');
        },
      );
      await vault.controller.initialize();

      expect(await vault.controller.unlockWithPassword(password), isTrue);

      expect((await readPersistedRecord()).version, 2);
      expect(vault.controller.isUnlocked, isTrue);
      expect(vault.controller.vaultSession!.keyId, 'legacy-v2-key');
      // The unlock succeeded on the legacy scheme, so the message must
      // not render in the error tone even though a rewrite was skipped.
      expect(
        vault.controller.message?.code,
        VaultSecurityMessageCode.vaultUnlockedMigrationDeferred,
      );
      expect(vault.controller.messageIsError, isFalse);
    });

    test('a failed record write rolls the entries back to the old key',
        () async {
      final rekeys = <String>[];
      storage.failRecordSaves = true;
      final vault = buildLockedVault(
        onRekey: ({required sourceSession, required targetSession}) async {
          rekeys.add(targetSession.keyId);
        },
      );
      await vault.controller.initialize();

      expect(await vault.controller.unlockWithPassword(password), isTrue);

      // Items were rewritten under the new DEK, so the rollback has to
      // put them back under the v2 DEK before the old record can open
      // them again. The two calls therefore target different keys: the
      // forward rewrite under the fresh one, the undo under the legacy
      // one.
      expect(rekeys, hasLength(2));
      expect(rekeys.first, isNot('legacy-v2-key'));
      expect(rekeys.last, 'legacy-v2-key');
      expect((await readPersistedRecord()).version, 2);
      expect(vault.controller.vaultSession!.keyId, 'legacy-v2-key');
    });

    test('migration re-enrolls the biometric envelope under the new DEK',
        () async {
      // The v2 vault already had a working biometric unlock, so an
      // envelope wrapping the OLD DEK is on disk. After the rewrite the
      // record points at a fresh DEK, and an envelope left untouched
      // would hand that fresh record a key that opens nothing.
      await storage.save(
        VaultSecurityController.biometricEnabledKey,
        'true',
      );
      final envelopeKey = SecretKey(List<int>.generate(32, (i) => i * 5 + 2));
      final envelope = BiometricKeyEnvelopeService(storage: storage);
      await envelope.enroll(
        dekBytes: Uint8List.fromList(legacyDek),
        envelopeKey: envelopeKey,
      );

      final vault = buildLockedVault(
        unlocker: _FixedKeyUnlockService(storage, envelopeKey),
      );
      await vault.controller.initialize();

      expect(await vault.controller.unlockWithPassword(password), isTrue);

      // The envelope on disk must now unwrap to the session's DEK.
      final unwrapped = await envelope.unwrap(envelopeKey: envelopeKey);
      expect(
        unwrapped,
        await vault.controller.vaultSession!.secretKey.extractBytes(),
      );
    });
  });

  // The security screen used to print a static platform table: `false` for
  // capabilities that worked on the device, and no way at all to say "I
  // could not find out". These tests pin the probe against the services
  // that actually perform the operations — one test per state, including
  // the failure modes that used to be flattened into `false`.
  group('VaultSecurityController capability probe', () {
    const keystoreChannel = MethodChannel(
      AndroidKeystoreEnvelopeKeyProvider.keystoreChannelName,
    );
    const biometricChannel = MethodChannel(
      AndroidKeystoreEnvelopeKeyProvider.biometricChannelName,
    );

    late _FakeCapabilityPlatform platform;
    late _InMemorySecureStorageService storage;

    setUp(() {
      platform = _FakeCapabilityPlatform();
      platform.install(keystoreChannel, biometricChannel);
      storage = _InMemorySecureStorageService();
    });

    tearDown(() => platform.uninstall(keystoreChannel, biometricChannel));

    /// A controller wired exactly like `password_manager_app.dart` wires
    /// it on Android: the native gate plus the KeyStore envelope provider.
    VaultSecurityController androidController({bool withUnlocker = true}) {
      final authService = NativeBiometricAuthService(isAndroid: true);
      final controller = VaultSecurityController(
        storage: storage,
        masterPasswordService: MasterPasswordService.test(),
        biometricAuthService: authService,
        biometricUnlockService: withUnlocker
            ? BiometricUnlockService(
                storage: storage,
                biometricAuthService: authService,
                envelopeService: BiometricKeyEnvelopeService(storage: storage),
                envelopeKeyProvider: AndroidKeystoreEnvelopeKeyProvider(
                  storage: storage,
                  isAndroid: true,
                ),
                isMobileTarget: true,
              )
            : null,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test('reports the KeyStore capabilities the device really has', () async {
      final plan = await androidController().probeSecurityPlan();

      expect(plan.secureStorage, SecurityCapabilityState.supported);
      expect(plan.biometricUnlock, SecurityCapabilityState.supported);
      expect(plan.hardwareBackedKeys, SecurityCapabilityState.supported);
      expect(plan.vaultEncryptionReady, SecurityCapabilityState.supported);
      // The probe asks the platform, it does not keep a table.
      expect(platform.keystoreCalls, contains('isAvailable'));
      expect(platform.biometricCalls, contains('probeAvailability'));
      expect(
        platform.biometricCalls,
        isNot(contains('requestDecryptAuthorization')),
        reason: 'reporting capabilities must never open a biometric prompt',
      );
    });

    test('reports not available when the platform answers no', () async {
      // Android 10 (the KeyStore channel refuses the API 30 biometric-only
      // spec) with no biometric enrolled: a real, confirmed "no".
      platform.available = false;
      platform.strongBiometricEnrolled = false;

      final plan = await androidController().probeSecurityPlan();

      expect(plan.hardwareBackedKeys, SecurityCapabilityState.unsupported);
      expect(plan.biometricUnlock, SecurityCapabilityState.unsupported);
      expect(plan.secureStorage, SecurityCapabilityState.supported);
    });

    test('reports unknown when the KeyStore cannot answer', () async {
      platform.availableError = PlatformException(code: 'KEYSTORE');

      final plan = await androidController().probeSecurityPlan();

      expect(
        plan.hardwareBackedKeys,
        SecurityCapabilityState.unknown,
        reason: 'a failed channel call is not evidence of a missing key',
      );
      expect(plan.biometricUnlock, SecurityCapabilityState.unknown);
      expect(plan.hardwareBackedKeys.isUnsupported, isFalse);
    });

    test('reports unknown when the biometric probe cannot answer', () async {
      platform.probeError = PlatformException(code: 'UNAVAILABLE');

      final plan = await androidController().probeSecurityPlan();

      expect(plan.biometricUnlock, SecurityCapabilityState.unknown);
      expect(plan.hardwareBackedKeys, SecurityCapabilityState.supported);
    });

    test('reports unknown when secure storage cannot be read', () async {
      storage.failReads = true;

      final plan = await androidController().probeSecurityPlan();

      expect(plan.secureStorage, SecurityCapabilityState.unknown);
    });

    test('reports not available for a build with no platform key', () async {
      // Outside Android the bootstrap wires a no-op envelope provider, so
      // there is no key-recovery path to report. That is a property of the
      // build, which means a confirmed "no", not an "unknown".
      final plan = await androidController(withUnlocker: false)
          .probeSecurityPlan();

      expect(plan.biometricUnlock, SecurityCapabilityState.unsupported);
      expect(plan.hardwareBackedKeys, SecurityCapabilityState.unsupported);
      expect(platform.keystoreCalls, isEmpty);
      expect(platform.biometricCalls, isEmpty);
    });
  });

  // A capability that needs two things can only be claimed when both were
  // confirmed. This is the rule the screen's "biometric unlock" answer
  // rests on, so it is pinned directly.
  group('SecurityCapabilityState.both', () {
    test('a confirmed no wins over a maybe and over a yes', () {
      expect(
        SecurityCapabilityState.both(
          SecurityCapabilityState.unsupported,
          SecurityCapabilityState.unknown,
        ),
        SecurityCapabilityState.unsupported,
      );
      expect(
        SecurityCapabilityState.both(
          SecurityCapabilityState.supported,
          SecurityCapabilityState.unsupported,
        ),
        SecurityCapabilityState.unsupported,
      );
    });

    test('a maybe wins over a yes', () {
      expect(
        SecurityCapabilityState.both(
          SecurityCapabilityState.supported,
          SecurityCapabilityState.unknown,
        ),
        SecurityCapabilityState.unknown,
      );
    });

    test('a yes needs both halves', () {
      expect(
        SecurityCapabilityState.both(
          SecurityCapabilityState.supported,
          SecurityCapabilityState.supported,
        ),
        SecurityCapabilityState.supported,
      );
    });
  });
}

class _CountingMasterPasswordService extends MasterPasswordService {
  _CountingMasterPasswordService()
    : super(
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

  /// When true, reads throw, simulating a platform store that cannot
  /// answer (as opposed to a store that answers "nothing stored").
  bool failReads = false;

  /// When true, writes of the unlock attempt state throw, simulating
  /// an unavailable keystore.
  bool failSaves = false;

  /// When true, writes of the master-password record throw. Used to
  /// pin the rollback behaviour of the record rewrite.
  bool failRecordSaves = false;

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    if (failReads) {
      throw StateError('keystore unavailable');
    }
    return _values[key];
  }

  @override
  Future<void> save(String key, String value) async {
    if (failSaves && key == UnlockAttemptLimiter.stateKey) {
      throw StateError('keystore unavailable');
    }
    if (failRecordSaves &&
        key == VaultSecurityController.masterPasswordRecordKey) {
      throw StateError('keystore unavailable');
    }
    _values[key] = value;
  }
}

/// Unlock service whose envelope-key provider hands out a fixed key, so
/// a test can enroll and then unwrap the real envelope.
class _FixedKeyUnlockService extends BiometricUnlockService {
  _FixedKeyUnlockService(SecureStorageService storage, SecretKey envelopeKey)
    : super(
        storage: storage,
        biometricAuthService: const _FakeBiometricAuthService(),
        envelopeService: BiometricKeyEnvelopeService(storage: storage),
        envelopeKeyProvider: _FixedKeyProvider(envelopeKey),
      );
}

class _FixedKeyProvider implements BiometricEnvelopeKeyProvider {
  const _FixedKeyProvider(this.key);

  final SecretKey key;

  @override
  Future<BiometricEnvelopeKeyResult> acquireEnvelopeKey() async {
    return BiometricEnvelopeKeyResult.success(key);
  }

  @override
  Future<BiometricEnvelopeKeyResult> releaseEnvelopeKey() async {
    return BiometricEnvelopeKeyResult.success(key);
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

/// Stands in for the Android KeyStore + `BiometricManager` side of the
/// app while a capability probe runs.
///
/// Deliberately has two answers and two failure knobs, because the whole
/// job of the probe is to keep "answered no" apart from "could not ask":
/// a fake that could not express the difference would let the regression
/// back in.
class _FakeCapabilityPlatform {
  /// What `KeystoreChannel.isAvailable` answers (API >= 30 with a strong
  /// biometric enrolled, in production terms).
  bool available = true;

  /// Thrown by `isAvailable` instead of answering, when set.
  PlatformException? availableError;

  /// Whether `probeAvailability` reports a strong biometric enrolled.
  bool strongBiometricEnrolled = true;

  /// Thrown by `probeAvailability`, when set.
  PlatformException? probeError;

  /// Method names seen on each channel, in call order.
  final List<String> keystoreCalls = <String>[];
  final List<String> biometricCalls = <String>[];

  void install(MethodChannel keystore, MethodChannel biometric) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(keystore, _handleKeystore);
    messenger.setMockMethodCallHandler(biometric, _handleBiometric);
  }

  void uninstall(MethodChannel keystore, MethodChannel biometric) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(keystore, null);
    messenger.setMockMethodCallHandler(biometric, null);
  }

  Future<Object?> _handleKeystore(MethodCall call) async {
    keystoreCalls.add(call.method);
    switch (call.method) {
      case 'isAvailable':
        final error = availableError;
        if (error != null) throw error;
        return available;
      default:
        throw MissingPluginException('no handler for ${call.method}');
    }
  }

  Future<Object?> _handleBiometric(MethodCall call) async {
    biometricCalls.add(call.method);
    switch (call.method) {
      case 'probeAvailability':
        final error = probeError;
        if (error != null) throw error;
        const success = 0;
        const noneEnrolled = 11;
        final code = strongBiometricEnrolled ? success : noneEnrolled;
        return <String, dynamic>{
          'canUseStrong': strongBiometricEnrolled,
          'canUseWeak': false,
          'canUseStrongOrCredential': strongBiometricEnrolled,
          'canUseDeviceCredential': false,
          'strongCode': code,
          'weakCode': noneEnrolled,
          'strongOrCredentialCode': code,
          'deviceCredentialCode': noneEnrolled,
          // The platform floor the native side owns: this fake models a
          // modern Android, where the KeyStore can declare a key as
          // biometric-only.
          'supportsBiometricOnlyAuth': true,
        };
      default:
        throw MissingPluginException('no handler for ${call.method}');
    }
  }
}
