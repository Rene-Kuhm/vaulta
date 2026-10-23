import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:gestor_contrasenas/core/security/biometric_auth_service.dart';
import 'package:gestor_contrasenas/core/security/master_password_service.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';

/// Minimal in-memory store for the controller's vault-key adoption paths.
class _MemoryStorage implements SecureStorageService {
  final Map<String, String> values = {};

  @override
  Future<void> save(String key, String value) async => values[key] = value;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> delete(String key) async => values.remove(key);
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

void main() {
  const password = 'StrongPass!2026';

  test('adopts a remote record and unlocks it with the master password',
      () async {
    final storage = _MemoryStorage();
    final controller = VaultSecurityController(
      storage: storage,
      masterPasswordService: MasterPasswordService.test(),
      biometricAuthService: const _FakeBiometricAuthService(),
    );
    addTearDown(controller.dispose);

    // Fresh device: no local record → onboarding.
    await controller.initialize();
    expect(controller.stage, VaultSecurityStage.onboarding);
    expect(await controller.readRecordJson(), isNull);

    // A second device already created the vault; simulate the synced record.
    final remoteRecord = await MasterPasswordService.test().createRecord(
      password,
    );
    final adopted = await controller.adoptRemoteVaultRecord(
      remoteRecord.encode(),
    );

    expect(adopted, isTrue);
    expect(controller.stage, VaultSecurityStage.locked);
    expect(
      await controller.readRecordJson(),
      remoteRecord.encode(),
      reason: 'the adopted record is the local record from now on',
    );

    // The same master password must unlock the synced vault.
    final unlocked = await controller.unlockWithPassword(password);
    expect(unlocked, isTrue);
    expect(controller.isUnlocked, isTrue);
  });

  test('a malformed remote record is refused and leaves no local record',
      () async {
    final storage = _MemoryStorage();
    final controller = VaultSecurityController(
      storage: storage,
      masterPasswordService: MasterPasswordService.test(),
      biometricAuthService: const _FakeBiometricAuthService(),
    );
    addTearDown(controller.dispose);

    await controller.initialize();

    final adopted = await controller.adoptRemoteVaultRecord('not-a-record');

    expect(adopted, isFalse);
    expect(await controller.readRecordJson(), isNull);
    expect(controller.stage, VaultSecurityStage.onboarding);
  });
}
