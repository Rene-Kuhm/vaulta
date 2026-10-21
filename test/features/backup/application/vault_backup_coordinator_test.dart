import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/vault_backup_service.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';
import 'package:gestor_contrasenas/features/backup/application/vault_backup_coordinator.dart';
import 'package:gestor_contrasenas/features/backup/domain/vault_clear_text_export.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';

import '../backup_test_support.dart';

void main() {
  late InMemorySecureStorage storage;
  late CountingMasterPasswordService passwords;
  late VaultSecurityController controller;
  late InMemoryVaultRepository repository;
  late DateTime now;
  late VaultBackupCoordinator coordinator;

  setUp(() async {
    storage = InMemorySecureStorage();
    passwords = CountingMasterPasswordService();
    controller = await buildUnlockedController(
      storage: storage,
      passwords: passwords,
    );
    addTearDown(controller.dispose);
    repository = InMemoryVaultRepository([
      testItem(id: 'a', title: 'GitHub', secret: 'gh-Secret!123'),
      testItem(id: 'b', title: 'Bank', secret: 'B4nk!Secret'),
    ]);
    now = DateTime.utc(2026, 10, 19, 12);
    coordinator = VaultBackupCoordinator(
      securityController: controller,
      repository: repository,
      backupService: VaultBackupService.test(),
      clock: () => now,
    );
  });

  Future<VaultBackupExportGrant> authorize() async {
    final grant = await coordinator.authorizeExport(testMasterPassword);
    expect(grant, isNotNull);
    return grant!;
  }

  group('export authorization', () {
    test('a wrong master password yields no grant', () async {
      expect(await coordinator.authorizeExport('WrongPass!2026'), isNull);
      expect(controller.failedUnlockAttempts, 1);
      expect(controller.message, isNull);
      expect(controller.isUnlocked, isTrue);
    });

    test(
      'a locked-out limiter blocks re-auth without running the KDF',
      () async {
        for (var i = 0; i < 5; i++) {
          expect(await coordinator.authorizeExport('WrongPass!2026'), isNull);
        }
        expect(controller.isUnlockLockedOut, isTrue);
        final callsBefore = passwords.verifyCalls;

        expect(await coordinator.authorizeExport(testMasterPassword), isNull);
        expect(passwords.verifyCalls, callsBefore);
      },
    );

    test('re-auth failures count against the unlock throttle', () async {
      for (var i = 0; i < 5; i++) {
        await coordinator.authorizeExport('WrongPass!2026');
      }
      await controller.lock();
      final callsBefore = passwords.verifyCalls;
      expect(await controller.unlockWithPassword(testMasterPassword), isFalse);
      expect(passwords.verifyCalls, callsBefore);
    });

    test('an unwritable attempt counter fails closed', () async {
      storage.failSaves = true;
      expect(await coordinator.authorizeExport(testMasterPassword), isNull);
      expect(passwords.verifyCalls, 0);
      expect(controller.unlockAttemptStateUnavailable, isTrue);
    });

    test('a locked vault yields no grant', () async {
      await controller.lock();
      expect(await coordinator.authorizeExport(testMasterPassword), isNull);
      expect(passwords.verifyCalls, 0);
    });
  });

  group('createBackup', () {
    test('produces an envelope that decrypts to the vault items', () async {
      final bytes = await coordinator.createBackup(
        grant: await authorize(),
        backupPassword: testBackupPassword,
        confirmation: testBackupPassword,
        appVersion: '1.0.21+22',
      );
      final contents = await VaultBackupService.test().decrypt(
        bytes: bytes,
        backupPassword: testBackupPassword,
      );
      expect(contents.items.map((item) => item.title), ['GitHub', 'Bank']);
    });

    test('the grant is single-use', () async {
      final grant = await authorize();
      await coordinator.createBackup(
        grant: grant,
        backupPassword: testBackupPassword,
        confirmation: testBackupPassword,
        appVersion: '1',
      );
      await expectLater(
        coordinator.createBackup(
          grant: grant,
          backupPassword: testBackupPassword,
          confirmation: testBackupPassword,
          appVersion: '1',
        ),
        throwsA(isA<VaultBackupNotAuthorizedException>()),
      );
    });

    test('the grant expires', () async {
      final grant = await authorize();
      now = now.add(
        VaultBackupCoordinator.grantLifetime + const Duration(seconds: 1),
      );
      await expectLater(
        coordinator.createBackup(
          grant: grant,
          backupPassword: testBackupPassword,
          confirmation: testBackupPassword,
          appVersion: '1',
        ),
        throwsA(isA<VaultBackupNotAuthorizedException>()),
      );
    });

    test('locking the vault invalidates the grant', () async {
      final grant = await authorize();
      await controller.lock();
      await controller.unlockWithPassword(testMasterPassword);
      await expectLater(
        coordinator.createBackup(
          grant: grant,
          backupPassword: testBackupPassword,
          confirmation: testBackupPassword,
          appVersion: '1',
        ),
        throwsA(isA<VaultBackupNotAuthorizedException>()),
      );
    });

    test('a weak backup password is refused and keeps the grant', () async {
      final grant = await authorize();
      for (final (password, confirmation, issue) in [
        ('Sh0rt!', 'Sh0rt!', VaultBackupPasswordIssue.tooShort),
        // NIST SP 800-63B dropped the composition rule, so a
        // lowercase-only password is no longer weak on that basis. What
        // remains is the breached-password blocklist.
        ('password12345', 'password12345', VaultBackupPasswordIssue.weak),
        (
          testBackupPassword,
          'Other#Pass2026',
          VaultBackupPasswordIssue.mismatch,
        ),
      ]) {
        await expectLater(
          coordinator.createBackup(
            grant: grant,
            backupPassword: password,
            confirmation: confirmation,
            appVersion: '1',
          ),
          throwsA(
            isA<VaultBackupPasswordException>().having(
              (e) => e.issue,
              'issue',
              issue,
            ),
          ),
        );
      }
      await coordinator.createBackup(
        grant: grant,
        backupPassword: testBackupPassword,
        confirmation: testBackupPassword,
        appVersion: '1',
      );
    });
  });

  group('restore', () {
    test('restores into a new device vault through saveItem', () async {
      final bytes = await coordinator.createBackup(
        grant: await authorize(),
        backupPassword: testBackupPassword,
        confirmation: testBackupPassword,
        appVersion: '1',
      );

      // A different device: new secure storage, new master password,
      // new DEK. Only the backup password is shared.
      final otherController = await buildUnlockedController(
        storage: InMemorySecureStorage(),
      );
      addTearDown(otherController.dispose);
      final otherRepository = InMemoryVaultRepository([
        testItem(id: 'x', title: 'GitHub', secret: 'gh-Secret!123'),
      ]);
      final otherCoordinator = VaultBackupCoordinator(
        securityController: otherController,
        repository: otherRepository,
        backupService: VaultBackupService.test(),
      );

      final preview = await otherCoordinator.previewRestore(
        bytes: bytes,
        backupPassword: testBackupPassword,
      );
      expect(preview.plan.duplicateCount, 1);
      expect(preview.plan.newCount, 1);
      expect(otherRepository.saved, isEmpty, reason: 'preview writes nothing');

      final result = await otherCoordinator.applyRestore(
        preview: preview,
        conflictSuffix: ' (restored)',
      );
      expect(result.imported, 1);
      expect(otherRepository.saved.single.title, 'Bank');
      expect(otherRepository.items.length, 2);
    });

    test('a wrong backup password fails generically', () async {
      final bytes = await coordinator.createBackup(
        grant: await authorize(),
        backupPassword: testBackupPassword,
        confirmation: testBackupPassword,
        appVersion: '1',
      );
      await expectLater(
        coordinator.previewRestore(bytes: bytes, backupPassword: 'Nope#2026xx'),
        throwsA(
          isA<VaultBackupException>().having(
            (e) => e.failure,
            'failure',
            VaultBackupFailure.decryptionFailed,
          ),
        ),
      );
    });

    test('applying requires an unlocked vault', () async {
      final bytes = await coordinator.createBackup(
        grant: await authorize(),
        backupPassword: testBackupPassword,
        confirmation: testBackupPassword,
        appVersion: '1',
      );
      final preview = await coordinator.previewRestore(
        bytes: bytes,
        backupPassword: testBackupPassword,
      );
      await controller.lock();
      expect(
        () => coordinator.applyRestore(
          preview: preview,
          conflictSuffix: ' (restored)',
        ),
        throwsA(isA<VaultBackupNotAuthorizedException>()),
      );
      expect(repository.saved, isEmpty);
    });
  });

  test('backup file name uses the .vaulta extension', () {
    expect(
      vaultBackupFileName(DateTime(2026, 10, 19, 8, 5)),
      'vaulta-backup-20261019-0805.vaulta',
    );
  });

  group('clear-text export', () {
    Future<Uint8List> exportClearText(
      VaultBackupExportGrant grant,
      VaultClearTextFormat format, {
      bool acknowledged = true,
    }) {
      return coordinator.createClearTextExport(
        grant: grant,
        format: format,
        acknowledgedUnencrypted: acknowledged,
        appVersion: '1.0.21+22',
      );
    }

    test(
      'is refused without the explicit unencrypted acknowledgement',
      () async {
        final grant = await authorize();

        await expectLater(
          exportClearText(grant, VaultClearTextFormat.csv, acknowledged: false),
          throwsA(isA<VaultClearTextExportNotConfirmedException>()),
        );
        await expectLater(
          exportClearText(
            grant,
            VaultClearTextFormat.json,
            acknowledged: false,
          ),
          throwsA(isA<VaultClearTextExportNotConfirmedException>()),
        );
        expect(repository.items, hasLength(2), reason: 'nothing was written');

        // A refused confirmation must not burn the grant.
        final bytes = await exportClearText(grant, VaultClearTextFormat.csv);
        expect(utf8.decode(bytes), contains('GitHub,rene@example.com'));
      },
    );

    test('renders every item as CSV', () async {
      final bytes = await exportClearText(
        await authorize(),
        VaultClearTextFormat.csv,
      );
      final csv = utf8.decode(bytes);
      final lines = csv.split('\r\n');

      expect(
        lines.first,
        'title,username,password,url,notes,category,updated_at',
      );
      expect(csv, contains('GitHub,rene@example.com,gh-Secret!123'));
      expect(csv, contains('Bank,rene@example.com,B4nk!Secret'));
    });

    test('renders every item as JSON that round-trips', () async {
      final bytes = await exportClearText(
        await authorize(),
        VaultClearTextFormat.json,
      );
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

      expect(decoded['app_version'], '1.0.21+22');
      expect(decoded['exported_at'], now.toIso8601String());
      final restored = [
        for (final map in decoded['items'] as List)
          VaultItem.fromJson(map as Map<String, dynamic>),
      ];
      expect(restored.map((item) => item.id), ['a', 'b']);
      expect(restored.map((item) => item.secret), [
        'gh-Secret!123',
        'B4nk!Secret',
      ]);
      expect(restored.map((item) => item.updatedAt), [
        repository.items[0].updatedAt,
        repository.items[1].updatedAt,
      ]);
    });

    test('a locked vault or a spent grant produces nothing', () async {
      final spent = await authorize();
      await exportClearText(spent, VaultClearTextFormat.csv);
      await expectLater(
        exportClearText(spent, VaultClearTextFormat.csv),
        throwsA(isA<VaultBackupNotAuthorizedException>()),
      );

      final lockedGrant = await authorize();
      await controller.lock();
      await expectLater(
        exportClearText(lockedGrant, VaultClearTextFormat.csv),
        throwsA(isA<VaultBackupNotAuthorizedException>()),
      );
    });

    test('the encrypted export still produces its own envelope', () async {
      final bytes = await coordinator.createBackup(
        grant: await authorize(),
        backupPassword: testBackupPassword,
        confirmation: testBackupPassword,
        appVersion: '1.0.21+22',
      );

      expect(
        vaultBackupFileName(now),
        endsWith('.${VaultBackupService.fileExtension}'),
      );
      expect(utf8.decode(bytes).contains('gh-Secret!123'), isFalse);
      final contents = await VaultBackupService.test().decrypt(
        bytes: bytes,
        backupPassword: testBackupPassword,
      );
      expect(contents.items.map((item) => item.title), ['GitHub', 'Bank']);
    });
  });
}
