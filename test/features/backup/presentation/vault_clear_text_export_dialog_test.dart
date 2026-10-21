import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/vault_backup_service.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';
import 'package:gestor_contrasenas/features/backup/application/vault_backup_coordinator.dart';
import 'package:gestor_contrasenas/features/backup/presentation/backup_section.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

import '../backup_test_support.dart';

void main() {
  late InMemorySecureStorage storage;
  late VaultSecurityController controller;
  late InMemoryVaultRepository repository;
  late FakeBackupFileGateway gateway;

  setUp(() async {
    storage = InMemorySecureStorage();
    controller = await buildUnlockedController(
      storage: storage,
      passwords: CountingMasterPasswordService(),
    );
    repository = InMemoryVaultRepository([
      testItem(
        id: 'a',
        title: 'GitHub',
        secret: 'gh-Secret!123',
        website: 'github.com',
        notes: 'work account',
        category: VaultCategory.work,
      ),
      testItem(id: 'b', title: 'Bank', secret: 'B4nk!Secret'),
      // A value that a naive CSV join would corrupt.
      testItem(
        id: 'c',
        title: 'Mail, "personal"',
        secret: 'pa,ss"word',
        notes: 'line one\nline two',
      ),
    ]);
    gateway = FakeBackupFileGateway();
  });

  tearDown(() => controller.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
  }

  Future<void> pumpSection(WidgetTester tester) async {
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
  }

  Future<void> openClearTextDialog(WidgetTester tester) async {
    await pumpSection(tester);
    await tester.tap(find.byKey(const Key('backup.section.exportClearText')));
    await pump(tester);
  }

  final primary = find.byKey(const Key('backup.exportClearText.primary'));
  final warning = find.byKey(const Key('backup.exportClearText.warning'));
  final acknowledge = find.byKey(
    const Key('backup.exportClearText.acknowledge'),
  );

  Future<void> reauthenticate(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('backup.exportClearText.masterPassword')),
      testMasterPassword,
    );
    await tester.tap(primary);
    await pump(tester);
  }

  Future<void> acknowledgeAndExport(WidgetTester tester) async {
    await tester.tap(acknowledge);
    await pump(tester);
    await tester.tap(primary);
    await tester.pumpAndSettle();
  }

  String? feedback(WidgetTester tester) {
    final finder = find.descendant(
      of: find.byKey(const Key('backup.exportClearText.feedback')),
      matching: find.byType(Text),
    );
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<Text>(finder.first).data;
  }

  testWidgets('the warning only appears after re-authentication', (
    tester,
  ) async {
    await openClearTextDialog(tester);
    expect(
      find.byKey(const Key('backup.exportClearText.masterPassword')),
      findsOneWidget,
    );
    expect(warning, findsNothing);

    await reauthenticate(tester);

    expect(warning, findsOneWidget);
    expect(find.textContaining('This file is NOT encrypted.'), findsOneWidget);
    expect(find.text('The file will contain 3 entries.'), findsOneWidget);
  });

  testWidgets('nothing can be exported before the acknowledgement', (
    tester,
  ) async {
    await openClearTextDialog(tester);
    await reauthenticate(tester);

    final button = tester.widget<FilledButton>(primary);
    expect(button.onPressed, isNull, reason: 'no confirmation, no export');

    // Tapping the disabled button must not write anything either.
    await tester.tap(primary, warnIfMissed: false);
    await pump(tester);
    expect(gateway.savedBytes, isEmpty);
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(acknowledge);
    await pump(tester);
    expect(tester.widget<FilledButton>(primary).onPressed, isNotNull);
  });

  testWidgets('a confirmed export writes CSV and escapes every field', (
    tester,
  ) async {
    await openClearTextDialog(tester);
    await reauthenticate(tester);
    await acknowledgeAndExport(tester);

    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.text('Unencrypted file saved. Delete it once you are done with it.'),
      findsOneWidget,
    );
    expect(gateway.savedNames.single, endsWith('.csv'));
    expect(gateway.savedExtensions.single, 'csv');

    final csv = utf8.decode(gateway.savedBytes.single);
    expect(
      csv.split('\r\n').first,
      'title,username,password,url,notes,category,updated_at',
    );
    // Comma, quote and newline survive because the field is quoted.
    expect(csv, contains('"Mail, ""personal"""'));
    expect(csv, contains('"pa,ss""word"'));
    expect(csv, contains('"line one\nline two"'));
    expect(csv, contains('GitHub,rene@example.com,gh-Secret!123,github.com'));
  });

  testWidgets('the JSON option writes every field of every item', (
    tester,
  ) async {
    await openClearTextDialog(tester);
    await reauthenticate(tester);
    await tester.tap(
      find.byKey(const Key('backup.exportClearText.format.json')),
    );
    await pump(tester);

    await acknowledgeAndExport(tester);

    expect(gateway.savedNames.single, endsWith('.json'));
    expect(gateway.savedExtensions.single, 'json');
    final decoded =
        jsonDecode(utf8.decode(gateway.savedBytes.single))
            as Map<String, dynamic>;
    expect(decoded['app_version'], '1.0.21+22');
    final restored = [
      for (final map in decoded['items'] as List)
        VaultItem.fromJson(map as Map<String, dynamic>),
    ];
    expect(restored, hasLength(3));
    expect(restored[2].title, 'Mail, "personal"');
    expect(restored[2].secret, 'pa,ss"word');
    expect(restored[2].notes, 'line one\nline two');
    expect(restored[0].website, 'github.com');
    expect(restored[0].updatedAt, repository.items[0].updatedAt);
  });

  testWidgets('a cancelled save can be retried without re-rendering', (
    tester,
  ) async {
    gateway.saveResults.addAll([false, true]);
    await openClearTextDialog(tester);
    await reauthenticate(tester);
    await acknowledgeAndExport(tester);

    expect(feedback(tester), 'Saving was cancelled. No file was written.');
    expect(find.text('Save file'), findsOneWidget);

    await tester.tap(primary);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(gateway.savedBytes, hasLength(2));
    expect(gateway.savedBytes[0], gateway.savedBytes[1]);
  });

  testWidgets('a vault locked after re-authentication refuses the export', (
    tester,
  ) async {
    await openClearTextDialog(tester);
    await reauthenticate(tester);
    await controller.lock();
    await tester.tap(acknowledge);
    await pump(tester);
    await tester.tap(primary);
    await tester.pumpAndSettle();

    expect(
      feedback(tester),
      'Your confirmation expired. Start the export again.',
    );
    expect(gateway.savedBytes, isEmpty);
  });

  testWidgets('the encrypted export still writes a .vaulta file', (
    tester,
  ) async {
    await pumpSection(tester);
    await tester.tap(find.byKey(const Key('backup.section.export')));
    await pump(tester);

    await tester.enterText(
      find.byKey(const Key('backup.export.masterPassword')),
      testMasterPassword,
    );
    await tester.tap(find.byKey(const Key('backup.export.primary')));
    await pump(tester);

    await tester.enterText(
      find.byKey(const Key('backup.export.password')),
      testBackupPassword,
    );
    await tester.enterText(
      find.byKey(const Key('backup.export.confirm')),
      testBackupPassword,
    );
    await tester.tap(find.byKey(const Key('backup.export.primary')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Encrypted backup saved.'), findsOneWidget);
    expect(gateway.savedNames.single, endsWith('.vaulta'));
    expect(gateway.savedExtensions.single, VaultBackupService.fileExtension);
    final bytes = gateway.savedBytes.single;
    expect(utf8.decode(bytes).contains('gh-Secret!123'), isFalse);
    final contents = await VaultBackupService.test().decrypt(
      bytes: bytes,
      backupPassword: testBackupPassword,
    );
    expect(contents.items, hasLength(3));
  });
}
