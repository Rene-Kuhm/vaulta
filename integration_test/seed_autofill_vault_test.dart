import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/core/security/aes_gcm_vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/flutter_secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/local_encrypted_vault_repository.dart';
import 'package:gestor_contrasenas/core/security/master_password_service.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';
import 'package:gestor_contrasenas/core/security/vault_session.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:integration_test/integration_test.dart';

/// Seeds a real vault on the device so the autofill flow can be exercised
/// end to end: a master-password record the app itself will accept, plus one
/// item whose website matches the host the trigger app asks about.
///
/// This exists because the onboarding UI is FLAG_SECURE: a person can type into
/// it, but a script cannot see it. Seeding the same state the app's
/// `createMasterPassword` produces is deterministic; navigating the form blind is
/// not.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const masterPassword = 'Vaulta-Autofill-2026!';
  const host = 'https://autofill-trigger.example/login';
  const itemTitle = 'Autofill Trigger';
  const itemUsername = 'rene@autofill.example';
  const itemSecret = 'Secreto-Que-Debe-Llenarse-42';

  testWidgets('seed a vault the app can unlock and fill from', (tester) async {
    final storage = FlutterSecureStorageService();
    final masterPasswordService = MasterPasswordService();
    final crypto = AesGcmVaultCryptoService();

    // Start clean so a previous run cannot mask a failure.
    await storage.delete(VaultSecurityController.masterPasswordRecordKey);
    await storage.delete(LocalEncryptedVaultRepository.encryptedVaultItemsKey);

    // Exactly what VaultSecurityController.createMasterPassword does, minus the
    // biometric enrolment: record first, then the session derived from it.
    final record = await masterPasswordService.createRecord(masterPassword);
    final session = VaultSession.v2(
      keyId: record.keyId,
      secretKey: await masterPasswordService.deriveVaultKey(
        record: record,
        password: masterPassword,
      ),
      kdf: record.kdf!,
      dekWrap: record.dekWrap!,
    );
    await storage.save(
      VaultSecurityController.masterPasswordRecordKey,
      record.encode(),
    );

    final repository = LocalEncryptedVaultRepository(
      storage: storage,
      cryptoService: crypto,
      readSession: () => session,
    );

    await repository.saveItem(
      VaultItem(
        id: 'autofill-seed-1',
        title: itemTitle,
        username: itemUsername,
        secret: itemSecret,
        category: VaultCategory.work,
        strengthScore: 93,
        lastUpdatedLabel: 'hoy',
        website: host,
        updatedAt: DateTime.now(),
      ),
    );

    final items = await repository.fetchItems();
    expect(items, hasLength(1), reason: 'the seed must be readable back');
    expect(items.first.username, itemUsername);
    expect(items.first.secret, itemSecret);

    // ignore: avoid_print
    print('seed · vault listo: ${items.first.title} → $host');
  });
}
