import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/core/security/aes_gcm_vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/flutter_secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/local_encrypted_vault_repository.dart';
import 'package:gestor_contrasenas/core/security/vault_session.dart';
import 'package:gestor_contrasenas/core/storage/lazy_sqlite_vault_repository.dart';
import 'package:gestor_contrasenas/core/storage/vault_blob_migration.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// On-device proof of the ADR-007 verification items that unit tests cannot give:
/// the real SQLite build runs on a real Android filesystem, the migration moves a
/// real legacy blob, and the database file on disk contains no clear text.
///
/// This is the check the UI cannot provide: the app sets FLAG_SECURE, so a
/// screenshot is black by design and the accessibility tree exposes no widgets.
/// Driving the storage layer directly is both possible and stronger evidence.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const secret = 'Clave-Secreta-DE-PRUEBA-123';
  const title = 'Banco de Prueba';

  testWidgets('migrates a real legacy blob and never leaks clear text '
      'to the database files on disk', (tester) async {
    final storage = FlutterSecureStorageService();
    final crypto = AesGcmVaultCryptoService();
    final session = VaultSession(
      keyId: 'device-test-key',
      secretKey: SecretKey(List<int>.generate(32, (i) => 11 + i)),
    );

    // Start from a clean slate so a previous run cannot mask a failure.
    await storage.delete(LocalEncryptedVaultRepository.encryptedVaultItemsKey);
    await storage.delete(VaultBlobMigration.legacyBlobKey);
    await storage.delete('vault_db_salt_v1');

    final directory = await getApplicationSupportDirectory();
    final dbPath = '${directory.path}/vault.db';
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$dbPath$suffix');
      if (file.existsSync()) file.deleteSync();
    }

    // The legacy blob, written the way the app stores it today.
    final item = VaultItem(
      id: 'record-device-1',
      title: title,
      username: 'rene',
      secret: secret,
      category: VaultCategory.finance,
      strengthScore: 95,
      lastUpdatedLabel: 'hoy',
      website: 'https://www.banco.example/login',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
    final envelope = await crypto.encrypt(
      plaintext: jsonEncode(item.toJson()),
      secretKey: session,
      keyId: session.keyId,
      recordId: item.id,
    );
    await storage.save(
      LocalEncryptedVaultRepository.encryptedVaultItemsKey,
      jsonEncode([envelope]),
    );

    final repository = LazySqliteVaultRepository(
      storage: storage,
      cryptoService: crypto,
      readSession: () => session,
      readMinimumVersion: () => LocalEncryptedVaultRepository.currentItemPayloadVersion,
      databasePath: () async => dbPath,
    );

    // 1. First use migrates.
    final items = await repository.fetchItems();
    expect(items, hasLength(1), reason: 'the migration must carry the item over');
    expect(items.first.title, title);
    expect(items.first.secret, secret);

    // 2. The legacy blob is set aside as the rollback, not destroyed.
    expect(
      await storage.read(VaultBlobMigration.legacyBlobKey),
      isNotNull,
      reason: 'the legacy blob must survive as the rollback',
    );
    expect(
      await storage.read(LocalEncryptedVaultRepository.encryptedVaultItemsKey),
      isNull,
    );

    // 3. The database answers for autofill through the host index.
    final byHost = await repository.findByHost('banco.example');
    expect(byHost, hasLength(1));

    // 4. Nothing secret is readable in the files SQLite wrote.
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$dbPath$suffix');
      if (!file.existsSync()) continue;
      final bytes = file.readAsBytesSync();
      for (final needle in [secret, title, 'banco.example', 'rene']) {
        expect(
          _contains(bytes, needle.codeUnits),
          isFalse,
          reason: 'the "$needle" string appeared in clear in $suffix',
        );
      }
      // ignore: avoid_print
      print('device · $suffix: ${bytes.length} bytes, sin texto en claro');
    }

    repository.close();
    await storage.delete(LocalEncryptedVaultRepository.encryptedVaultItemsKey);
    await storage.delete(VaultBlobMigration.legacyBlobKey);
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}
