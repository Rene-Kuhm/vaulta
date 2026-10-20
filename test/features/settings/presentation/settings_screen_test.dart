import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import 'package:gestor_contrasenas/app/localization/app_locale_controller.dart';
import 'package:gestor_contrasenas/core/security/biometric_auth_service.dart';
import 'package:gestor_contrasenas/core/security/master_password_service.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';
import 'package:gestor_contrasenas/core/sync/device_registration_repository.dart';
import 'package:gestor_contrasenas/core/sync/device_registration_service.dart';
import 'package:gestor_contrasenas/core/sync/device_session_revocation_service.dart';
import 'package:gestor_contrasenas/features/settings/presentation/settings_screen.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

import '../../backup/backup_test_support.dart' show InMemoryVaultRepository;

void main() {
  group('SettingsScreen backup section', () {
    testWidgets('renders only when a repository is provided', (tester) async {
      final controller = await _buildUnlockedController();
      final localeController = AppLocaleController(
        storage: _InMemorySecureStorageService(),
      );
      await localeController.initialize();
      addTearDown(controller.dispose);
      _setLargeViewport(tester);

      await tester.pumpWidget(
        _testApp(
          SettingsScreen(
            securityController: controller,
            localeController: localeController,
          ),
        ),
      );
      await _pumpUi(tester);
      expect(find.text('Encrypted backup'), findsNothing);

      await tester.pumpWidget(
        _testApp(
          SettingsScreen(
            key: const ValueKey('with-repository'),
            securityController: controller,
            localeController: localeController,
            repository: InMemoryVaultRepository(),
          ),
        ),
      );
      await _pumpUi(tester);
      expect(find.text('Encrypted backup'), findsOneWidget);
      expect(find.text('Export backup'), findsOneWidget);
      expect(find.text('Restore backup'), findsOneWidget);
    });
  });

  group('SettingsScreen change master password', () {
    testWidgets('updates master password and closes dialog on success', (
      tester,
    ) async {
      var rekeyCalls = 0;
      final controller = await _buildUnlockedController(
        rekeyEntries: ({required sourceSession, required targetSession}) async {
          rekeyCalls += 1;
        },
      );
      final localeController = AppLocaleController(
        storage: _InMemorySecureStorageService(),
      );
      await localeController.initialize();
      addTearDown(controller.dispose);
      _setLargeViewport(tester);

      await tester.pumpWidget(
        _testApp(
          SettingsScreen(
            securityController: controller,
            localeController: localeController,
          ),
        ),
      );
      await _pumpUi(tester);

      await tester.tap(find.text('Change master password'));
      await _pumpUi(tester);

      final dialogFields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(dialogFields.at(0), 'StrongPass!2026');
      await tester.enterText(dialogFields.at(1), 'AnotherStrong!2027');
      await tester.enterText(dialogFields.at(2), 'AnotherStrong!2027');

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Apply'),
        ),
      );
      await _pumpUi(tester, settleFor: const Duration(seconds: 1));

      expect(
        find.widgetWithText(AlertDialog, 'Change master password'),
        findsNothing,
      );
      expect(
        find.text('Master password updated successfully.'),
        findsOneWidget,
      );
      expect(rekeyCalls, 1);

      await controller.lock();
      expect(await controller.unlockWithPassword('StrongPass!2026'), isFalse);
      expect(await controller.unlockWithPassword('AnotherStrong!2027'), isTrue);
    });

    testWidgets('shows error feedback when current password is invalid', (
      tester,
    ) async {
      final controller = await _buildUnlockedController();
      final localeController = AppLocaleController(
        storage: _InMemorySecureStorageService(),
      );
      await localeController.initialize();
      addTearDown(controller.dispose);
      _setLargeViewport(tester);

      await tester.pumpWidget(
        _testApp(
          SettingsScreen(
            securityController: controller,
            localeController: localeController,
          ),
        ),
      );
      await _pumpUi(tester);

      await tester.tap(find.text('Change master password'));
      await _pumpUi(tester);

      final dialogFields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(dialogFields.at(0), 'WrongPass!2026');
      await tester.enterText(dialogFields.at(1), 'AnotherStrong!2027');
      await tester.enterText(dialogFields.at(2), 'AnotherStrong!2027');

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Apply'),
        ),
      );
      await _pumpUi(tester);

      expect(
        find.widgetWithText(AlertDialog, 'Change master password'),
        findsOneWidget,
      );
      expect(find.textContaining('master password actual'), findsWidgets);
    });

    testWidgets('shows the lockout message after too many wrong attempts', (
      tester,
    ) async {
      final controller = await _buildUnlockedController();
      final localeController = AppLocaleController(
        storage: _InMemorySecureStorageService(),
      );
      await localeController.initialize();
      addTearDown(controller.dispose);
      _setLargeViewport(tester);

      for (var i = 0; i < 5; i++) {
        await controller.changeMasterPassword(
          currentPassword: 'WrongPass!2026',
          newPassword: 'AnotherStrong!2027',
          confirmation: 'AnotherStrong!2027',
        );
      }
      expect(controller.isUnlockLockedOut, isTrue);

      await tester.pumpWidget(
        _testApp(
          SettingsScreen(
            securityController: controller,
            localeController: localeController,
          ),
        ),
      );
      await _pumpUi(tester);

      await tester.tap(find.text('Change master password'));
      await _pumpUi(tester);

      final dialogFields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      // Even the correct current password is refused during lockout.
      await tester.enterText(dialogFields.at(0), 'StrongPass!2026');
      await tester.enterText(dialogFields.at(1), 'AnotherStrong!2027');
      await tester.enterText(dialogFields.at(2), 'AnotherStrong!2027');

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Apply'),
        ),
      );
      await _pumpUi(tester);

      expect(
        find.widgetWithText(AlertDialog, 'Change master password'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Too many failed attempts. Try again in'),
        findsOneWidget,
      );
    });

    testWidgets('updates idle timeout preset from settings', (tester) async {
      final controller = await _buildUnlockedController();
      final localeController = AppLocaleController(
        storage: _InMemorySecureStorageService(),
      );
      await localeController.initialize();
      await controller.setIdleTimeoutSeconds(300);
      addTearDown(controller.dispose);
      _setLargeViewport(tester);

      await tester.pumpWidget(
        _testApp(
          SettingsScreen(
            securityController: controller,
            localeController: localeController,
          ),
        ),
      );
      await _pumpUi(tester);

      expect(controller.idleTimeoutSeconds, 300);

      await tester.tap(find.text('5 minutes - Recommended'));
      await _pumpUi(tester);
      await tester.tap(find.text('Never - Disabled').last);
      await _pumpUi(tester);

      expect(controller.idleTimeoutSeconds, 0);
      expect(controller.message, contains('inactividad'));
    });

    testWidgets('renders device sessions and revokes selected device', (
      tester,
    ) async {
      final controller = await _buildUnlockedController();
      final localeController = AppLocaleController(
        storage: _InMemorySecureStorageService(),
      );
      await localeController.initialize();
      final repository = _FakeDeviceRegistrationRepository(
        devices: const [
          VaultDeviceSession(
            deviceId: 'test-device-id',
            deviceName: 'Pixel 8',
            platform: 'android',
            appVersion: '1.0.4+5',
            status: DeviceSessionStatus.active,
            accessAllowed: true,
          ),
          VaultDeviceSession(
            deviceId: 'old-laptop',
            deviceName: 'Old Laptop',
            platform: 'windows',
            appVersion: '1.0.4+5',
            status: DeviceSessionStatus.revokedAll,
            accessAllowed: false,
          ),
        ],
      );
      final revocationService = DeviceSessionRevocationService(
        repository: repository,
        identityService: const _FakeDeviceIdentityService('current-device'),
      );
      addTearDown(controller.dispose);
      _setLargeViewport(tester);

      await tester.pumpWidget(
        _testApp(
          SettingsScreen(
            securityController: controller,
            localeController: localeController,
            revocationService: revocationService,
          ),
        ),
      );
      await _pumpUi(tester);

      expect(find.text('Devices and sessions'), findsOneWidget);
      expect(find.text('status: active'), findsOneWidget);
      expect(find.text('status: revoked_all'), findsOneWidget);

      await tester.tap(find.text('Revoke device'));
      await _pumpUi(tester);

      expect(repository.lastRevokedDeviceId, 'test-device-id');
    });

    testWidgets('locks current session when current device is revoked', (
      tester,
    ) async {
      final controller = await _buildUnlockedController();
      final localeController = AppLocaleController(
        storage: _InMemorySecureStorageService(),
      );
      await localeController.initialize();
      final repository = _FakeDeviceRegistrationRepository(
        devices: const [
          VaultDeviceSession(
            deviceId: 'current-device',
            deviceName: 'Pixel 8',
            platform: 'android',
            appVersion: '1.0.4+5',
            status: DeviceSessionStatus.active,
            accessAllowed: true,
          ),
        ],
      );
      final revocationService = DeviceSessionRevocationService(
        repository: repository,
        identityService: const _FakeDeviceIdentityService('current-device'),
      );
      addTearDown(controller.dispose);
      _setLargeViewport(tester);

      await tester.pumpWidget(
        _testApp(
          SettingsScreen(
            securityController: controller,
            localeController: localeController,
            revocationService: revocationService,
          ),
        ),
      );
      await _pumpUi(tester);

      await tester.tap(find.text('Revoke device'));
      await _pumpUi(tester);
      await tester.tap(find.text('Revoke now'));
      await _pumpUi(tester);
      await tester.tap(find.text('Lock now').last);
      await _pumpUi(tester);

      expect(controller.stage, VaultSecurityStage.locked);
      expect(controller.message, contains('no longer has an active session'));
    });

    testWidgets('revokes all other devices with current device id', (
      tester,
    ) async {
      final controller = await _buildUnlockedController();
      final localeController = AppLocaleController(
        storage: _InMemorySecureStorageService(),
      );
      await localeController.initialize();
      final repository = _FakeDeviceRegistrationRepository(
        devices: const [
          VaultDeviceSession(
            deviceId: 'current-device',
            deviceName: 'Pixel 8',
            platform: 'android',
            appVersion: '1.0.4+5',
            status: DeviceSessionStatus.active,
            accessAllowed: true,
          ),
        ],
      );
      final revocationService = DeviceSessionRevocationService(
        repository: repository,
        identityService: const _FakeDeviceIdentityService('current-device'),
      );
      addTearDown(controller.dispose);
      _setLargeViewport(tester);

      await tester.pumpWidget(
        _testApp(
          SettingsScreen(
            securityController: controller,
            localeController: localeController,
            revocationService: revocationService,
          ),
        ),
      );
      await _pumpUi(tester);

      await tester.tap(find.text('Revoke all other sessions'));
      await _pumpUi(tester);

      expect(repository.lastRevokeAllCurrentDeviceId, 'current-device');
      expect(repository.revokeAllOtherCalls, 1);
    });
  });

  group('SettingsScreen platform capabilities', () {
    Future<Map<String, bool>> renderCapabilities(
      WidgetTester tester,
      TargetPlatform platform,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final controller = await _buildUnlockedController();
      final localeController = AppLocaleController(
        storage: _InMemorySecureStorageService(),
      );
      await localeController.initialize();
      addTearDown(controller.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 12000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _testApp(
          SettingsScreen(
            securityController: controller,
            localeController: localeController,
          ),
        ),
      );
      await _pumpUi(tester);

      bool enabled(String title) {
        final row = find
            .ancestor(of: find.text(title), matching: find.byType(Row))
            .first;
        return find
            .descendant(
              of: row,
              matching: find.byIcon(Icons.verified_user_rounded),
            )
            .evaluate()
            .isNotEmpty;
      }

      final result = {
        'biometric': enabled('Biometric key recovery'),
        'hardware': enabled('Hardware-backed keys'),
        'storage': enabled('Secure storage'),
      };
      debugDefaultTargetPlatformOverride = null;
      return result;
    }

    testWidgets('Android reports KeyStore-backed biometric unlock', (
      tester,
    ) async {
      final capabilities = await renderCapabilities(
        tester,
        TargetPlatform.android,
      );
      expect(capabilities, {
        'biometric': true,
        'hardware': true,
        'storage': true,
      });
    });

    testWidgets('Windows reports master password only', (tester) async {
      final capabilities = await renderCapabilities(
        tester,
        TargetPlatform.windows,
      );
      expect(capabilities, {
        'biometric': false,
        'hardware': false,
        'storage': true,
      });
    });
  });
}

Widget _testApp(Widget home) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: home,
  );
}

Future<void> _pumpUi(
  WidgetTester tester, {
  Duration settleFor = const Duration(milliseconds: 100),
}) async {
  await tester.pump();
  await tester.pump(settleFor);
  await tester.pump();
}

void _setLargeViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 2400);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<VaultSecurityController> _buildUnlockedController({
  VaultRekeyEntries? rekeyEntries,
}) async {
  final controller = VaultSecurityController(
    storage: _InMemorySecureStorageService(),
    masterPasswordService: MasterPasswordService.test(),
    biometricAuthService: const _FakeBiometricAuthService(),
    rekeyEntries: rekeyEntries,
  );

  await controller.initialize();
  await controller.createMasterPassword(
    password: 'StrongPass!2026',
    confirmation: 'StrongPass!2026',
    enableBiometrics: false,
  );
  await controller.setIdleTimeoutSeconds(0);

  return controller;
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

class _FakeDeviceIdentityService implements DeviceIdentityService {
  const _FakeDeviceIdentityService(this._deviceId);

  final String _deviceId;

  @override
  Future<String> getOrCreateDeviceId() async => _deviceId;

  @override
  String readPlatform() => 'android';

  @override
  Future<String> readDeviceName() async => 'Pixel 8';
}

class _FakeDeviceRegistrationRepository
    implements DeviceRegistrationRepository {
  _FakeDeviceRegistrationRepository({required this.devices});

  final List<VaultDeviceSession> devices;
  String? lastRevokedDeviceId;
  String? lastRevokeAllCurrentDeviceId;
  int revokeAllOtherCalls = 0;

  @override
  Future<List<VaultDeviceSession>> listDevices() async => devices;

  @override
  Future<DeviceAccessStatus> readDeviceAccessStatus({
    required String deviceId,
  }) async {
    return const DeviceAccessStatus(accessAllowed: true, reason: null);
  }

  @override
  Future<DeviceAccessStatus> registerDevice({
    required String deviceId,
    required String deviceName,
    required String platform,
    required String appVersion,
    required DateTime lastSeenAt,
  }) async {
    return const DeviceAccessStatus(accessAllowed: true, reason: null);
  }

  @override
  Future<void> revokeAllOtherDevices({required String currentDeviceId}) async {
    revokeAllOtherCalls += 1;
    lastRevokeAllCurrentDeviceId = currentDeviceId;
  }

  @override
  Future<void> revokeDevice({required String deviceId}) async {
    lastRevokedDeviceId = deviceId;
  }

  @override
  Future<DeviceAccessStatus> sendHeartbeat({
    required String deviceId,
    required String deviceName,
    required String platform,
    required String appVersion,
    required DateTime lastSeenAt,
  }) async {
    return const DeviceAccessStatus(accessAllowed: true, reason: null);
  }
}
