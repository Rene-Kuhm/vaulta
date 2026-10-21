import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import 'package:gestor_contrasenas/core/security/biometric_auth_service.dart';
import 'package:gestor_contrasenas/core/security/master_password_service.dart';
import 'package:gestor_contrasenas/core/security/platform_security_plan.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';
import 'package:gestor_contrasenas/features/security/presentation/security_capabilities_panel.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

void main() {
  const allSupported = PlatformSecurityPlan(
    secureStorage: SecurityCapabilityState.supported,
    biometricUnlock: SecurityCapabilityState.supported,
    hardwareBackedKeys: SecurityCapabilityState.supported,
    vaultEncryptionReady: SecurityCapabilityState.supported,
  );

  /// One plan with all three states in it, so a single render can show
  /// that they are told apart.
  const mixed = PlatformSecurityPlan(
    secureStorage: SecurityCapabilityState.supported,
    biometricUnlock: SecurityCapabilityState.unknown,
    hardwareBackedKeys: SecurityCapabilityState.unsupported,
    vaultEncryptionReady: SecurityCapabilityState.supported,
  );

  VaultSecurityController buildController() {
    final controller = VaultSecurityController(
      storage: _InMemorySecureStorageService(),
      masterPasswordService: MasterPasswordService.test(),
      biometricAuthService: const _FakeBiometricAuthService(),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> pumpPanel(
    WidgetTester tester, {
    required Future<PlatformSecurityPlan> Function() probe,
    Locale locale = const Locale('en'),
  }) {
    return tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(
          body: SecurityCapabilitiesPanel(
            controller: buildController(),
            probe: probe,
          ),
        ),
      ),
    );
  }

  testWidgets('renders each capability state differently', (tester) async {
    await pumpPanel(tester, probe: () async => mixed);
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final supported = l10n.settingsCapabilitySupported;
    final unsupported = l10n.settingsCapabilityUnsupported;
    final unknown = l10n.settingsCapabilityUnknown;

    // Three states, three words. "Could not determine" is not "not
    // available" — that is the whole point of the tri-state.
    expect(unknown, isNot(unsupported));
    expect(find.text(supported), findsNWidgets(2));
    expect(find.text(unsupported), findsOneWidget);
    expect(find.text(unknown), findsOneWidget);
  });

  testWidgets('renders a confirmed no for a platform without the path',
      (tester) async {
    await pumpPanel(
      tester,
      probe: () async => const PlatformSecurityPlan(
        secureStorage: SecurityCapabilityState.supported,
        biometricUnlock: SecurityCapabilityState.unsupported,
        hardwareBackedKeys: SecurityCapabilityState.unsupported,
        vaultEncryptionReady: SecurityCapabilityState.supported,
      ),
    );
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.settingsCapabilityUnsupported), findsNWidgets(2));
    expect(find.text(l10n.settingsCapabilityUnknown), findsNothing);
  });

  testWidgets('nothing is claimed before the probe answers', (tester) async {
    final gate = Completer<PlatformSecurityPlan>();
    await pumpPanel(tester, probe: () => gate.future);
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.settingsCapabilityUnknown), findsNWidgets(4));
    expect(
      find.text(l10n.settingsCapabilityUnsupported),
      findsNothing,
      reason: 'an unanswered question must never be printed as a "no"',
    );

    gate.complete(allSupported);
    await tester.pumpAndSettle();
    expect(find.text(l10n.settingsCapabilitySupported), findsNWidgets(4));
  });

  testWidgets('a probe that throws reports unknown, not unsupported',
      (tester) async {
    await pumpPanel(
      tester,
      probe: () async => throw StateError('platform channel missing'),
    );
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.settingsCapabilityUnknown), findsNWidgets(4));
    expect(find.text(l10n.settingsCapabilityUnsupported), findsNothing);
  });

  testWidgets('the three states are worded in Spanish too', (tester) async {
    await pumpPanel(
      tester,
      probe: () async => mixed,
      locale: const Locale('es'),
    );
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('es'));
    expect(find.text(l10n.settingsCapabilitySupported), findsNWidgets(2));
    expect(find.text(l10n.settingsCapabilityUnsupported), findsOneWidget);
    expect(find.text(l10n.settingsCapabilityUnknown), findsOneWidget);
    // The Spanish copy must keep the distinction the English copy makes.
    expect(
      l10n.settingsCapabilityUnknown,
      isNot(l10n.settingsCapabilityUnsupported),
    );
  });
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
