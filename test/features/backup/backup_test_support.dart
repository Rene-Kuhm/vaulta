import 'dart:typed_data';

import 'package:local_auth/local_auth.dart';

import 'package:gestor_contrasenas/core/security/biometric_auth_service.dart';
import 'package:gestor_contrasenas/core/security/master_password_record.dart';
import 'package:gestor_contrasenas/core/security/master_password_service.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/unlock_attempt_limiter.dart';
import 'package:gestor_contrasenas/core/security/vault_repository.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';
import 'package:gestor_contrasenas/features/backup/data/vault_backup_file_gateway.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_summary.dart';

/// Master password used by every backup test vault.
const testMasterPassword = 'StrongPass!2026';

/// A backup password that satisfies the policy.
const testBackupPassword = 'Backup#Pass2026';

/// Builds a vault item with sensible defaults.
VaultItem testItem({
  required String id,
  required String title,
  String username = 'rene@example.com',
  String secret = 'S3cret!value',
  String? website,
  String? notes,
  VaultCategory category = VaultCategory.personal,
}) {
  return VaultItem(
    id: id,
    title: title,
    username: username,
    secret: secret,
    category: category,
    strengthScore: estimatePasswordStrength(secret),
    lastUpdatedLabel: 'Updated now',
    website: website,
    notes: notes,
    updatedAt: DateTime.utc(2026, 10, 1),
  );
}

/// In-memory [SecureStorageService]; [failSaves] simulates a broken
/// keystore.
class InMemorySecureStorage implements SecureStorageService {
  final Map<String, String> _values = {};

  /// When true, every save throws.
  bool failSaves = false;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> save(String key, String value) async {
    if (failSaves) {
      throw StateError('storage unavailable');
    }
    _values[key] = value;
  }
}

/// Biometric service that reports no biometrics.
class NoBiometricAuthService implements BiometricAuthService {
  /// Builds the fake.
  const NoBiometricAuthService();

  @override
  Future<bool> authenticateForUnlock() async => false;

  @override
  Future<BiometricAvailability> getAvailability() async {
    return const BiometricAvailability(
      deviceSupported: false,
      canCheckBiometrics: false,
      availableBiometrics: <BiometricType>[],
    );
  }
}

/// Fast-KDF master password service that counts verifier runs.
class CountingMasterPasswordService extends MasterPasswordService {
  /// Builds the counting service.
  CountingMasterPasswordService()
    : super(
        encryptionIterations: 1,
        argon2MemoryKiB: 1024,
        useFastTestKdf: true,
      );

  /// Number of [verify] calls (each one is a KDF run in production).
  int verifyCalls = 0;

  @override
  Future<bool> verify({
    required MasterPasswordRecord record,
    required String password,
  }) {
    verifyCalls++;
    return super.verify(record: record, password: password);
  }
}

/// In-memory [VaultRepository] that records every save.
class InMemoryVaultRepository implements VaultRepository {
  /// Builds a repository seeded with [items].
  InMemoryVaultRepository([List<VaultItem> items = const []])
    : items = List.of(items);

  /// Current items.
  final List<VaultItem> items;

  /// Every item passed to [saveItem], in order.
  final List<VaultItem> saved = [];

  @override
  Future<void> deleteItem(String id) async =>
      items.removeWhere((item) => item.id == id);

  @override
  Future<VaultItem?> fetchItemById(String id) async {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  @override
  Future<List<VaultItem>> fetchItems() async => List.of(items);

  @override
  Future<VaultSummary> fetchSummary() => throw UnimplementedError();

  @override
  Future<VaultItem> saveItem(VaultItem item) async {
    saved.add(item);
    final index = items.indexWhere((candidate) => candidate.id == item.id);
    if (index == -1) {
      items.add(item);
    } else {
      items[index] = item;
    }
    return item;
  }
}

/// Scripted [VaultBackupFileGateway].
class FakeBackupFileGateway implements VaultBackupFileGateway {
  /// Results returned by successive [save] calls (true = saved).
  final List<bool> saveResults = [];

  /// Envelope bytes passed to every [save] call.
  final List<Uint8List> savedBytes = [];

  /// File names passed to every [save] call.
  final List<String> savedNames = [];

  /// File returned by [pick].
  VaultBackupPickedFile? fileToPick;

  @override
  Future<VaultBackupPickedFile?> pick() async => fileToPick;

  @override
  Future<bool> save({
    required String fileName,
    required Uint8List bytes,
  }) async {
    savedNames.add(fileName);
    savedBytes.add(bytes);
    return saveResults.isEmpty ? true : saveResults.removeAt(0);
  }
}

/// Builds an unlocked controller over [storage] with a deterministic
/// limiter clock.
Future<VaultSecurityController> buildUnlockedController({
  required InMemorySecureStorage storage,
  MasterPasswordService? passwords,
}) async {
  final now = DateTime.utc(2026, 10, 19, 12);
  final controller = VaultSecurityController(
    storage: storage,
    masterPasswordService: passwords ?? MasterPasswordService.test(),
    biometricAuthService: const NoBiometricAuthService(),
    unlockAttemptLimiter: UnlockAttemptLimiter(
      storage: storage,
      clock: () => now,
      monotonicClock: () => Duration.zero,
    ),
  );
  await controller.initialize();
  await controller.createMasterPassword(
    password: testMasterPassword,
    confirmation: testMasterPassword,
    enableBiometrics: false,
  );
  await controller.setIdleTimeoutSeconds(0);
  return controller;
}
