import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import 'package:gestor_contrasenas/core/security/biometric_auth_service.dart';
import 'package:gestor_contrasenas/core/security/master_password_service.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/unlock_attempt_limiter.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';
import 'package:gestor_contrasenas/core/sync/device_registration_repository.dart';
import 'package:gestor_contrasenas/core/sync/device_registration_service.dart';
import 'package:gestor_contrasenas/core/sync/device_session_revocation_service.dart';
import 'package:gestor_contrasenas/features/security/presentation/security_gate.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

void main() {
  testWidgets('locks gate when app moves to background state', (tester) async {
    final controller = VaultSecurityController(
      storage: _InMemorySecureStorageService(),
      masterPasswordService: MasterPasswordService.test(),
      biometricAuthService: const _FakeBiometricAuthService(),
    );
    addTearDown(() async {
      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    await controller.initialize();
    await controller.createMasterPassword(
      password: 'StrongPass!2026',
      confirmation: 'StrongPass!2026',
      enableBiometrics: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SecurityGate(
          controller: controller,
          child: const Scaffold(body: Center(child: Text('Unlocked vault'))),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Unlocked vault'), findsOneWidget);

    await controller.handleAppLifecycleState(AppLifecycleState.paused);
    await tester.pumpAndSettle();

    expect(find.text('Unlock vault'), findsOneWidget);
    expect(find.text('Unlocked vault'), findsNothing);
  });

  testWidgets('locks gate after foreground idle timeout', (tester) async {
    final controller = VaultSecurityController(
      storage: _InMemorySecureStorageService(),
      masterPasswordService: MasterPasswordService.test(),
      biometricAuthService: const _FakeBiometricAuthService(),
    );
    addTearDown(() async {
      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    await controller.initialize();
    await controller.createMasterPassword(
      password: 'StrongPass!2026',
      confirmation: 'StrongPass!2026',
      enableBiometrics: false,
    );
    await controller.setIdleTimeoutSeconds(1);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SecurityGate(
          controller: controller,
          child: const Scaffold(body: Center(child: Text('Unlocked vault'))),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Unlocked vault'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();

    expect(find.text('Unlock vault'), findsOneWidget);
    expect(find.text('Unlocked vault'), findsNothing);
  });

  testWidgets('locks gate when current device is revoked on session start', (
    tester,
  ) async {
    final controller = VaultSecurityController(
      storage: _InMemorySecureStorageService(),
      masterPasswordService: MasterPasswordService.test(),
      biometricAuthService: const _FakeBiometricAuthService(),
    );
    addTearDown(() async {
      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    await controller.initialize();
    await controller.createMasterPassword(
      password: 'StrongPass!2026',
      confirmation: 'StrongPass!2026',
      enableBiometrics: false,
    );
    await controller.lock();

    final repository = _RevokedDeviceRegistrationRepository();
    final service = DeviceRegistrationService(
      repository: repository,
      identityService: const _FakeDeviceIdentityService(),
      appVersionProvider: const _FakeAppVersionProvider(),
    );
    final revocationService = DeviceSessionRevocationService(
      repository: repository,
      identityService: const _FakeDeviceIdentityService(),
    );
    final lifecycle = DeviceSyncLifecycle(
      service: service,
      revocationService: revocationService,
      onCurrentDeviceRevoked: (status) {
        return controller.lock(reason: status.userFacingReason());
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SecurityGate(
          controller: controller,
          deviceSyncLifecycle: lifecycle,
          child: const Scaffold(body: Center(child: Text('Unlocked vault'))),
        ),
      ),
    );
    await _pumpUi(tester);

    await controller.unlockWithPassword('StrongPass!2026');
    await _pumpUi(tester);

    expect(find.text('Unlock vault'), findsOneWidget);
    expect(find.text('Unlocked vault'), findsNothing);
  });

  testWidgets('shows lockout countdown and disables unlock after failures', (
    tester,
  ) async {
    final storage = _InMemorySecureStorageService();
    var now = DateTime.utc(2026, 10, 19, 12);
    final controller = VaultSecurityController(
      storage: storage,
      masterPasswordService: MasterPasswordService.test(),
      biometricAuthService: const _FakeBiometricAuthService(),
      unlockAttemptLimiter: UnlockAttemptLimiter(
        storage: storage,
        clock: () => now,
      ),
    );
    addTearDown(() async {
      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    await controller.initialize();
    await controller.createMasterPassword(
      password: 'StrongPass!2026',
      confirmation: 'StrongPass!2026',
      enableBiometrics: false,
    );
    await controller.lock();
    for (var i = 0; i < 5; i++) {
      await controller.unlockWithPassword('WrongPass!2026');
    }

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SecurityGate(
          controller: controller,
          child: const Scaffold(body: Center(child: Text('Unlocked vault'))),
        ),
      ),
    );
    await _pumpUi(tester);

    FilledButton unlockButton() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('unlock-with-password-button')),
    );

    expect(
      find.text('Too many failed attempts. Try again in 0:30.'),
      findsOneWidget,
    );
    expect(unlockButton().onPressed, isNull);

    // Submitting from the keyboard is ignored too.
    await tester.enterText(find.byType(TextField), 'StrongPass!2026');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await _pumpUi(tester);
    expect(controller.isUnlocked, isFalse);

    // The countdown ticks once per second.
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.text('Too many failed attempts. Try again in 0:29.'),
      findsOneWidget,
    );

    // Once the lockout expires the banner goes away and unlock works.
    now = now.add(const Duration(seconds: 29));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('unlock-lockout-banner')), findsNothing);
    expect(unlockButton().onPressed, isNotNull);

    final unlockFinder = find.byKey(
      const ValueKey('unlock-with-password-button'),
    );
    await tester.ensureVisible(unlockFinder);
    await tester.pump();
    await tester.tap(unlockFinder);
    // The KDF runs on real async work, so let it finish outside the
    // fake clock before checking the result.
    for (var i = 0; i < 50 && !controller.isUnlocked; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(controller.isUnlocked, isTrue);
    expect(controller.failedUnlockAttempts, 0);
    // Drop the idle auto-lock timer so the test leaves no timers behind.
    await controller.lock();
    await _pumpUi(tester);
  });

  test('formats lockout remaining time as m:ss, rounding up', () {
    expect(formatLockoutRemaining(const Duration(seconds: 30)), '0:30');
    expect(
      formatLockoutRemaining(const Duration(seconds: 29, milliseconds: 1)),
      '0:30',
    );
    expect(formatLockoutRemaining(const Duration(minutes: 15)), '15:00');
    expect(formatLockoutRemaining(const Duration(seconds: 61)), '1:01');
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

Future<void> _pumpUi(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
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

class _FakeDeviceIdentityService implements DeviceIdentityService {
  const _FakeDeviceIdentityService();

  @override
  Future<String> getOrCreateDeviceId() async => 'current-device';

  @override
  String readPlatform() => 'android';

  @override
  Future<String> readDeviceName() async => 'Pixel';
}

class _FakeAppVersionProvider implements AppVersionProvider {
  const _FakeAppVersionProvider();

  @override
  Future<String> readAppVersion() async => '1.0.4+5';
}

class _RevokedDeviceRegistrationRepository
    implements DeviceRegistrationRepository {
  @override
  Future<List<VaultDeviceSession>> listDevices() async => const [];

  @override
  Future<DeviceAccessStatus> readDeviceAccessStatus({
    required String deviceId,
  }) async {
    return const DeviceAccessStatus(
      accessAllowed: false,
      reason: DeviceAccessRevocationReason.deviceRevoked,
    );
  }

  @override
  Future<DeviceAccessStatus> registerDevice({
    required String deviceId,
    required String deviceName,
    required String platform,
    required String appVersion,
    required DateTime lastSeenAt,
  }) async {
    return const DeviceAccessStatus(
      accessAllowed: false,
      reason: DeviceAccessRevocationReason.deviceRevoked,
    );
  }

  @override
  Future<void> revokeAllOtherDevices({required String currentDeviceId}) async {}

  @override
  Future<void> revokeDevice({required String deviceId}) async {}

  @override
  Future<DeviceAccessStatus> sendHeartbeat({
    required String deviceId,
    required String deviceName,
    required String platform,
    required String appVersion,
    required DateTime lastSeenAt,
  }) async {
    return const DeviceAccessStatus(
      accessAllowed: false,
      reason: DeviceAccessRevocationReason.deviceRevoked,
    );
  }
}
