import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/vault_backup_service.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';
import 'package:gestor_contrasenas/features/backup/application/vault_backup_coordinator.dart';
import 'package:gestor_contrasenas/features/backup/data/vault_backup_file_gateway.dart';
import 'package:gestor_contrasenas/features/backup/presentation/backup_section.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

import '../backup_test_support.dart';

void main() {
  late VaultSecurityController controller;
  late InMemoryVaultRepository repository;
  late FakeBackupFileGateway gateway;
  late Uint8List backupBytes;

  setUp(() async {
    controller = await buildUnlockedController(
      storage: InMemorySecureStorage(),
    );
    repository = InMemoryVaultRepository([
      testItem(id: 'x', title: 'GitHub', secret: 'gh-Secret!123'),
    ]);
    gateway = FakeBackupFileGateway();
    backupBytes =
        await VaultBackupService.test(
          clock: () => DateTime.utc(2026, 10, 19, 9, 30),
        ).export(
          items: [
            testItem(id: 'a', title: 'GitHub', secret: 'gh-Secret!123'),
            testItem(id: 'b', title: 'Bank', secret: 'B4nk!Secret'),
            // Same title/username/site as the existing entry, new secret.
            testItem(id: 'c', title: 'GitHub', secret: 'Other!Secret9'),
          ],
          backupPassword: testBackupPassword,
          appVersion: '1',
        );
  });

  tearDown(() => controller.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
  }

  Future<void> openRestore(WidgetTester tester) async {
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
              appVersionLoader: () async => '1',
            ),
          ),
        ),
      ),
    );
    await pump(tester);
    await tester.tap(find.byKey(const Key('backup.section.restore')));
    await pump(tester);
  }

  Future<void> pickAndOpen(WidgetTester tester, String password) async {
    await tester.tap(find.byKey(const Key('backup.restore.pick')));
    await pump(tester);
    await tester.enterText(
      find.byKey(const Key('backup.restore.password')),
      password,
    );
    await tester.tap(find.byKey(const Key('backup.restore.open')));
    await pump(tester);
  }

  const genericError =
      'The backup could not be opened. Check the backup password; the file '
      'may also be damaged or modified.';

  testWidgets('a wrong backup password shows the generic error', (
    tester,
  ) async {
    gateway.fileToPick = VaultBackupPickedFile(
      name: 'vault.vaulta',
      bytes: backupBytes,
    );
    await openRestore(tester);
    await pickAndOpen(tester, 'Wrong#Pass2026');

    expect(find.text(genericError), findsOneWidget);
    expect(find.byKey(const Key('backup.restore.summary')), findsNothing);
    expect(repository.saved, isEmpty);
  });

  testWidgets('a tampered file shows the same generic error', (tester) async {
    final envelope = jsonDecode(utf8.decode(backupBytes)) as Map;
    envelope['created_at'] = '2020-01-01T00:00:00.000Z';
    gateway.fileToPick = VaultBackupPickedFile(
      name: 'vault.vaulta',
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
    );
    await openRestore(tester);
    await pickAndOpen(tester, testBackupPassword);

    expect(find.text(genericError), findsOneWidget);
    expect(repository.saved, isEmpty);
  });

  testWidgets('a newer format version is reported on pick', (tester) async {
    final envelope = jsonDecode(utf8.decode(backupBytes)) as Map;
    envelope['v'] = 2;
    gateway.fileToPick = VaultBackupPickedFile(
      name: 'vault.vaulta',
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
    );
    await openRestore(tester);
    await tester.tap(find.byKey(const Key('backup.restore.pick')));
    await pump(tester);

    expect(
      find.textContaining('made by a newer version of Vaulta'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('backup.restore.password')), findsNothing);
  });

  testWidgets('previews then merges through the repository', (tester) async {
    gateway.fileToPick = VaultBackupPickedFile(
      name: 'vault.vaulta',
      bytes: backupBytes,
    );
    await openRestore(tester);
    await pickAndOpen(tester, testBackupPassword);

    expect(
      find.text(
        '3 entries: 1 new, 1 kept next to a similar entry, '
        '1 already in your vault.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Created '), findsOneWidget);
    expect(repository.saved, isEmpty);

    await tester.tap(find.byKey(const Key('backup.restore.confirm')));
    await pump(tester);

    expect(find.text('Restored 2 entries.'), findsOneWidget);
    expect(repository.saved.map((item) => item.title).toSet(), {
      'Bank',
      'GitHub (restored)',
    });
    expect(repository.items.length, 3);
  });
}
