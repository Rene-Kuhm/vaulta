import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import 'package:gestor_contrasenas/core/security/biometric_auth_service.dart';
import 'package:gestor_contrasenas/core/security/master_password_service.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/sensitive_clipboard_service.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';

/// Wiring between [VaultSecurityController.lock] and the sensitive
/// clipboard: which locks clear a copied secret and which do not.
void main() {
  late _CountingClipboardService clipboard;

  Future<VaultSecurityController> unlockedController() async {
    clipboard = _CountingClipboardService();
    final controller = VaultSecurityController(
      storage: _InMemorySecureStorageService(),
      masterPasswordService: MasterPasswordService.test(),
      biometricAuthService: const _FakeBiometricAuthService(),
      clipboard: clipboard,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.createMasterPassword(
      password: 'StrongPass!2026',
      confirmation: 'StrongPass!2026',
      enableBiometrics: false,
    );
    expect(controller.isUnlocked, isTrue);
    return controller;
  }

  test('manual lock clears the sensitive clipboard', () async {
    final controller = await unlockedController();

    await controller.lock(reason: 'manual');

    expect(controller.stage, VaultSecurityStage.locked);
    expect(clipboard.clears, 1);
  });

  test('lock drops the session before clearing the clipboard', () async {
    final controller = await unlockedController();
    clipboard.onClear = () {
      expect(controller.vaultSession, isNull);
      expect(controller.stage, VaultSecurityStage.locked);
    };

    await controller.lock();

    expect(clipboard.clears, 1);
  });

  test(
    'background auto-lock does NOT clear the clipboard (copy-then-paste)',
    () async {
      final controller = await unlockedController();

      await controller.handleAppLifecycleState(AppLifecycleState.paused);

      expect(controller.stage, VaultSecurityStage.locked);
      expect(clipboard.clears, 0);
    },
  );

  testWidgets('idle-timeout lock clears the clipboard', (tester) async {
    final controller = await unlockedController();
    await controller.setIdleTimeoutSeconds(5);
    controller.registerUserInteraction();

    await tester.pump(const Duration(seconds: 6));

    expect(controller.stage, VaultSecurityStage.locked);
    expect(clipboard.clears, 1);
  });
}

class _CountingClipboardService extends SensitiveClipboardService {
  _CountingClipboardService() : super(isAndroid: false);

  int clears = 0;
  void Function()? onClear;

  @override
  Future<bool> clearIfOwned() async {
    onClear?.call();
    clears++;
    return true;
  }
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
