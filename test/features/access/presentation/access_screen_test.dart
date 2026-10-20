import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import 'package:gestor_contrasenas/core/security/biometric_auth_service.dart';
import 'package:gestor_contrasenas/core/security/master_password_service.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/vault_repository.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';
import 'package:gestor_contrasenas/features/access/presentation/access_screen.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_summary.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

class _InMemorySecureStorageService implements SecureStorageService {
  final Map<String, String> _values = {};

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> save(String key, String value) async => _values[key] = value;
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

class _EmptyVaultRepository implements VaultRepository {
  @override
  Future<List<VaultItem>> fetchItems() async => const [];

  @override
  Future<VaultSummary> fetchSummary() async => const VaultSummary(
    totalItems: 0,
    weakItems: 0,
    reusedItems: 0,
    securityScore: 0,
    connectedDevices: 0,
    syncEnabled: false,
  );

  @override
  Future<VaultItem?> fetchItemById(String id) async => null;

  @override
  Future<VaultItem> saveItem(VaultItem item) async => item;

  @override
  Future<void> deleteItem(String id) async {}
}

void main() {
  testWidgets('AccessScreen renders section header and locked state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = VaultSecurityController(
      storage: _InMemorySecureStorageService(),
      masterPasswordService: MasterPasswordService.test(),
      biometricAuthService: const _FakeBiometricAuthService(),
    );
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AccessScreen(
          securityController: controller,
          repository: _EmptyVaultRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('AUTOFILL & ACCESS'), findsOneWidget);
    expect(find.text('Autofill is on the way'), findsOneWidget);

    expect(find.text('Lock vault now'), findsOneWidget);

    await _disposeTree(tester);
  });

  for (final (locale, comingSoon, statusTitle, forbidden) in [
    (
      const Locale('en'),
      'Coming soon',
      'Not available in this version',
      ['Pick Vaulta', 'Setup in three steps', 'One-tap autofill'],
    ),
    (
      const Locale('es'),
      'Próximamente',
      'No disponible en esta versión',
      ['Elegí Vaulta', 'Configuracion en tres pasos', 'Autofill en un toque'],
    ),
  ]) {
    testWidgets(
      'AccessScreen shows an honest coming-soon state (${locale.languageCode})',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 4000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final controller = VaultSecurityController(
          storage: _InMemorySecureStorageService(),
          masterPasswordService: MasterPasswordService.test(),
          biometricAuthService: const _FakeBiometricAuthService(),
        );
        await controller.initialize();

        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AccessScreen(
              securityController: controller,
              repository: _EmptyVaultRepository(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text(comingSoon), findsOneWidget);
        expect(find.text(statusTitle), findsOneWidget);
        expect(
          find.byKey(const ValueKey('access-autofill-status')),
          findsOneWidget,
        );
        // No instructions to pick Vaulta as the system autofill
        // service: that service does not exist in this build.
        for (final text in forbidden) {
          expect(find.text(text), findsNothing, reason: text);
        }

        await _disposeTree(tester);
      },
    );
  }
}

Future<void> _disposeTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}
