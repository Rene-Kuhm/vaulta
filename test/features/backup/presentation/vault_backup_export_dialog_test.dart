import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/vault_backup_service.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';
import 'package:gestor_contrasenas/features/backup/application/vault_backup_coordinator.dart';
import 'package:gestor_contrasenas/features/backup/presentation/backup_section.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

import '../backup_test_support.dart';

void main() {
  late InMemorySecureStorage storage;
  late CountingMasterPasswordService passwords;
  late VaultSecurityController controller;
  late InMemoryVaultRepository repository;
  late FakeBackupFileGateway gateway;

  setUp(() async {
    storage = InMemorySecureStorage();
    passwords = CountingMasterPasswordService();
    controller = await buildUnlockedController(
      storage: storage,
      passwords: passwords,
    );
    repository = InMemoryVaultRepository([
      testItem(id: 'a', title: 'GitHub', secret: 'gh-Secret!123'),
      testItem(id: 'b', title: 'Bank', secret: 'B4nk!Secret'),
      testItem(id: 'c', title: 'Mail', secret: 'M4il!Secret'),
    ]);
    gateway = FakeBackupFileGateway();
  });

  tearDown(() => controller.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: SingleChildScrollView(
            child: BackupSection(
              coordinator: VaultBackupCoordinator(
                securityController: controller,
                repository: repository,
                backupService: VaultBackupService.test(),
              ),
              securityController: controller,
              fileGateway: gateway,
              appVersionLoader: () async => '1.0.21+22',
            ),
          ),
        ),
      ),
    );
    await pump(tester);
    await tester.tap(find.byKey(const Key('backup.section.export')));
    await pump(tester);
  }

  Future<void> tapPrimary(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('backup.export.primary')));
    await pump(tester);
  }

  Future<void> reauthenticate(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('backup.export.masterPassword')),
      testMasterPassword,
    );
    await tapPrimary(tester);
  }

  String? feedback(WidgetTester tester) {
    final finder = find.descendant(
      of: find.byKey(const Key('backup.export.feedback')),
      matching: find.byType(Text),
    );
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<Text>(finder.first).data;
  }

  testWidgets('a wrong master password keeps the dialog on step one', (
    tester,
  ) async {
    await openDialog(tester);
    await tester.enterText(
      find.byKey(const Key('backup.export.masterPassword')),
      'WrongPass!2026',
    );
    await tapPrimary(tester);

    expect(feedback(tester), 'The master password does not match.');
    expect(find.byKey(const Key('backup.export.password')), findsNothing);
    expect(gateway.savedBytes, isEmpty);
  });

  testWidgets('a locked-out limiter blocks the export', (tester) async {
    for (var i = 0; i < 5; i++) {
      await controller.reauthenticateWithPassword('WrongPass!2026');
    }
    expect(controller.isUnlockLockedOut, isTrue);
    final callsBefore = passwords.verifyCalls;

    await openDialog(tester);
    await reauthenticate(tester);

    expect(feedback(tester), startsWith('Too many failed attempts.'));
    expect(find.byKey(const Key('backup.export.password')), findsNothing);
    expect(passwords.verifyCalls, callsBefore);
    expect(gateway.savedBytes, isEmpty);
  });

  testWidgets('shows item count and warning, validates the backup password', (
    tester,
  ) async {
    await openDialog(tester);
    await reauthenticate(tester);

    expect(find.text('The backup will contain 3 entries.'), findsOneWidget);
    expect(
      find.textContaining('Vaulta cannot recover the backup password'),
      findsOneWidget,
    );

    final password = find.byKey(const Key('backup.export.password'));
    final confirm = find.byKey(const Key('backup.export.confirm'));

    await tester.enterText(password, 'Sh0rt!');
    await tester.enterText(confirm, 'Sh0rt!');
    await tapPrimary(tester);
    expect(feedback(tester), 'Use at least 12 characters.');

    await tester.enterText(password, 'alllowercase123!');
    await tester.enterText(confirm, 'alllowercase123!');
    await tapPrimary(tester);
    expect(
      feedback(tester),
      'Combine upper and lower case letters, numbers and symbols.',
    );

    await tester.enterText(password, testBackupPassword);
    await tester.enterText(confirm, 'Different#Pass2026');
    await tapPrimary(tester);
    expect(
      feedback(tester),
      'The confirmation does not match the backup password.',
    );
    expect(gateway.savedBytes, isEmpty);
  });

  testWidgets('a valid password saves an encrypted .vaulta file', (
    tester,
  ) async {
    await openDialog(tester);
    await reauthenticate(tester);
    await tester.enterText(
      find.byKey(const Key('backup.export.password')),
      testBackupPassword,
    );
    await tester.enterText(
      find.byKey(const Key('backup.export.confirm')),
      testBackupPassword,
    );
    await tapPrimary(tester);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Encrypted backup saved.'), findsOneWidget);
    expect(gateway.savedNames.single, endsWith('.vaulta'));
    final bytes = gateway.savedBytes.single;
    expect(utf8.decode(bytes).contains('gh-Secret!123'), isFalse);
    final contents = await VaultBackupService.test().decrypt(
      bytes: bytes,
      backupPassword: testBackupPassword,
    );
    expect(contents.items.length, 3);
    expect(contents.header.appVersion, '1.0.21+22');
  });

  testWidgets('a cancelled save can be retried without re-encrypting', (
    tester,
  ) async {
    gateway.saveResults.addAll([false, true]);
    await openDialog(tester);
    await reauthenticate(tester);
    await tester.enterText(
      find.byKey(const Key('backup.export.password')),
      testBackupPassword,
    );
    await tester.enterText(
      find.byKey(const Key('backup.export.confirm')),
      testBackupPassword,
    );
    await tapPrimary(tester);

    expect(feedback(tester), 'Saving was cancelled. No file was written.');
    expect(find.text('Save file'), findsOneWidget);
    expect(find.byKey(const Key('backup.export.password')), findsNothing);

    await tapPrimary(tester);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(gateway.savedBytes.length, 2);
    expect(gateway.savedBytes[0], gateway.savedBytes[1]);
  });
}
