import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import 'package:gestor_contrasenas/app/bootstrap/password_manager_app.dart';
import 'package:gestor_contrasenas/app/localization/app_locale_controller.dart';
import 'package:gestor_contrasenas/core/security/aes_gcm_vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/biometric_auth_service.dart';
import 'package:gestor_contrasenas/core/security/local_encrypted_vault_repository.dart';
import 'package:gestor_contrasenas/core/security/master_password_service.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_entry_detail_screen.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_entry_editor_screen.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

void main() {
  testWidgets('shows onboarding when no master password exists', (
    tester,
  ) async {
    final controller = VaultSecurityController(
      storage: _InMemorySecureStorageService(),
      masterPasswordService: MasterPasswordService.test(),
      biometricAuthService: const _FakeBiometricAuthService(),
    );
    final localeController = AppLocaleController(
      storage: _InMemorySecureStorageService(),
    );
    await controller.initialize();
    await localeController.initialize();

    await tester.pumpWidget(
      PasswordManagerApp(
        repository: LocalEncryptedVaultRepository(
          storage: _InMemorySecureStorageService(),
          cryptoService: AesGcmVaultCryptoService(),
          readSession: () => controller.vaultSession,
        ),
        securityController: controller,
        localeController: localeController,
        secureStorage: _InMemorySecureStorageService(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Vaulta'), findsOneWidget);
    expect(find.text('Create secure vault access'), findsOneWidget);
    expect(find.text('Secure onboarding'), findsOneWidget);

    await _disposeTree(tester);
  });

  testWidgets('builds a new vault entry from the editor form', (tester) async {
    VaultItem? savedItem;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    savedItem = await Navigator.of(context).push<VaultItem>(
                      MaterialPageRoute(
                        builder: (_) => const VaultEntryEditorScreen(),
                      ),
                    );
                  },
                  child: const Text('Open editor'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'GitHub');
    await tester.enterText(find.byType(TextFormField).at(1), 'leo@example.com');
    await tester.enterText(
      find.byType(TextFormField).at(2),
      'StrongSecret!2026',
    );
    await tester.enterText(
      find.byType(TextFormField).at(3),
      'https://github.com',
    );
    await tester.enterText(
      find.byType(TextFormField).at(4),
      'Personal access token backup.',
    );

    await tester.ensureVisible(find.text('Create entry'));
    await tester.tap(find.text('Create entry'));
    await tester.pumpAndSettle();

    expect(savedItem, isNotNull);
    expect(savedItem!.title, 'GitHub');
    expect(savedItem!.username, 'leo@example.com');
    expect(savedItem!.secret, 'StrongSecret!2026');
    expect(savedItem!.website, 'https://github.com');
    expect(savedItem!.notes, 'Personal access token backup.');
    expect(savedItem!.strengthScore, greaterThanOrEqualTo(80));

    await _disposeTree(tester);
  });

  testWidgets('reveals edits and deletes an entry from detail view', (
    tester,
  ) async {
    var editCalls = 0;
    var deleteCalls = 0;
    bool? routeResult;

    const item = VaultItem(
      id: 'bank',
      title: 'Bank',
      username: 'finance@vaulta.app',
      secret: 'BankPass!2026',
      category: VaultCategory.finance,
      strengthScore: 80,
      lastUpdatedLabel: 'Updated now',
      notes: 'Recovery branch code.',
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    routeResult = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => VaultEntryDetailScreen(
                          item: item,
                          onEdit: (VaultItem currentItem) async {
                            editCalls += 1;
                            expect(currentItem.id, item.id);
                            return true;
                          },
                          onDelete: () async {
                            deleteCalls += 1;
                          },
                        ),
                      ),
                    );
                  },
                  child: const Text('Open detail'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open detail'));
    await tester.pumpAndSettle();

    expect(find.text('*********2026'), findsOneWidget);

    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    expect(find.text('BankPass!2026'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit entry'));
    await tester.pumpAndSettle();

    expect(editCalls, 1);
    expect(routeResult, true);

    routeResult = null;
    await tester.tap(find.text('Open detail'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete entry'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(deleteCalls, 1);
    expect(routeResult, true);

    await _disposeTree(tester);
  });
}

Future<void> _disposeTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
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
