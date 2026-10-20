import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/vault_backup_service.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';
import 'package:gestor_contrasenas/features/backup/application/vault_backup_coordinator.dart';
import 'package:gestor_contrasenas/features/backup/presentation/backup_section.dart';
import 'package:gestor_contrasenas/features/security/presentation/security_gate.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_entry_detail_screen.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

import '../../backup/backup_test_support.dart';

void main() {
  late VaultSecurityController controller;
  late InMemoryVaultRepository repository;
  late FakeBackupFileGateway gateway;

  setUp(() async {
    controller = await buildUnlockedController(
      storage: InMemorySecureStorage(),
    );
    repository = InMemoryVaultRepository([
      testItem(id: 'a', title: 'GitHub', secret: 'gh-Secret!123'),
    ]);
    gateway = FakeBackupFileGateway();
  });

  tearDown(() => controller.dispose());

  Future<void> pumpGate(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: SecurityGate(controller: controller, child: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('locking closes the export dialog and its pending save', (
    tester,
  ) async {
    gateway.saveResults.add(false);
    await pumpGate(
      tester,
      Scaffold(
        body: BackupSection(
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
    );

    await tester.tap(find.byKey(const Key('backup.section.export')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('backup.export.masterPassword')),
      testMasterPassword,
    );
    await tester.tap(find.byKey(const Key('backup.export.primary')));
    await tester.pumpAndSettle();
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
    // The save was cancelled: the sealed backup waits behind "Save file".
    expect(find.text('Save file'), findsOneWidget);
    expect(gateway.savedBytes.length, 1);

    await controller.lock();
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Save file'), findsNothing);
    expect(find.text('Unlock vault'), findsOneWidget);
    expect(gateway.savedBytes.length, 1);
  });

  testWidgets('locking closes an open entry detail screen', (tester) async {
    final item = testItem(id: 'a', title: 'GitHub', secret: 'gh-Secret!123');
    await pumpGate(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => VaultEntryDetailScreen(item: item),
              ),
            ),
            child: const Text('open entry'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open entry'));
    await tester.pumpAndSettle();
    expect(find.byType(VaultEntryDetailScreen), findsOneWidget);

    await controller.lock();
    await tester.pumpAndSettle();

    expect(find.byType(VaultEntryDetailScreen), findsNothing);
    expect(find.text('Unlock vault'), findsOneWidget);
  });

  testWidgets('locking closes bottom sheets and routes that veto pop', (
    tester,
  ) async {
    await pumpGate(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const PopScope(
                    canPop: false,
                    child: Scaffold(body: Text('sticky screen')),
                  ),
                ),
              );
            },
            child: const Text('open sticky'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open sticky'));
    await tester.pumpAndSettle();
    await showModalBottomSheet<void>(
      context: tester.element(find.text('sticky screen')),
      builder: (_) => const Text('sheet secret'),
    );
    await tester.pumpAndSettle();
    expect(find.text('sheet secret'), findsOneWidget);

    await controller.lock();
    await tester.pumpAndSettle();

    expect(find.text('sheet secret'), findsNothing);
    expect(find.text('sticky screen'), findsNothing);
    expect(find.text('Unlock vault'), findsOneWidget);
  });
}
