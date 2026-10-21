import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/core/security/aes_gcm_vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/flutter_secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/local_encrypted_vault_repository.dart';
import 'package:gestor_contrasenas/core/security/vault_backup_service.dart';
import 'package:gestor_contrasenas/core/security/vault_session.dart';
import 'package:gestor_contrasenas/core/storage/lazy_sqlite_vault_repository.dart';
import 'package:gestor_contrasenas/core/storage/vault_blob_migration.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// The release gate from ADR-007, run on a real device: an encrypted backup is
/// taken from a vault that lives in the legacy blob, the vault is migrated to the
/// encrypted database, the app is restarted (a brand-new repository instance reads
/// the same files), the data is verified, and the backup is restored into a fresh
/// database as if this were a new device.
///
/// The UI cannot drive this: the app sets FLAG_SECURE, so screenshots are black and
/// the accessibility tree exposes no widgets. The sequence is the same one a person
/// would perform; only the taps are replaced by calls to the same services.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const backupPassword = 'Vaulta-Backup-2026!';
  const secret = 'Clave-Que-Debe-Sobrevivir-123';
  const title = 'Banco del Gate';

  late Directory dir;
  late FlutterSecureStorageService storage;
  late AesGcmVaultCryptoService crypto;
  late VaultSession session;

  String dbPath(String name) => '${dir.path}/$name.db';

  void deleteDbFiles(String path) {
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$path$suffix');
      if (file.existsSync()) file.deleteSync();
    }
  }

  VaultItem sampleItem() => VaultItem(
    id: 'gate-record-1',
    title: title,
    username: 'rene',
    secret: secret,
    category: VaultCategory.finance,
    strengthScore: 95,
    lastUpdatedLabel: 'hoy',
    website: 'https://www.gate.example/login',
    updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
  );

  LazySqliteVaultRepository sqliteAt(String path) => LazySqliteVaultRepository(
    storage: storage,
    cryptoService: crypto,
    readSession: () => session,
    readMinimumVersion: () =>
        LocalEncryptedVaultRepository.currentItemPayloadVersion,
    databasePath: () async => path,
  );

  setUp(() async {
    dir = Directory('${(await getApplicationSupportDirectory()).path}/gate')
      ..createSync(recursive: true);
    storage = FlutterSecureStorageService();
    crypto = AesGcmVaultCryptoService();
    session = VaultSession(
      keyId: 'gate-key',
      secretKey: SecretKey(List<int>.generate(32, (i) => 21 + i)),
    );

    // Clean slate: a previous run must not be able to mask a failure.
    await storage.delete(LocalEncryptedVaultRepository.encryptedVaultItemsKey);
    await storage.delete(VaultBlobMigration.legacyBlobKey);
    await storage.delete('vault_db_salt_v1');
    for (final name in ['a', 'b']) {
      deleteDbFiles(dbPath(name));
    }
  });

  testWidgets('backup, migrate, restart, verify and restore, on the device', (
    tester,
  ) async {
    // 1. A vault that lives in the legacy blob, exactly as the released app stores it.
    final blob = LocalEncryptedVaultRepository(
      storage: storage,
      cryptoService: crypto,
      readSession: () => session,
    );
    await blob.saveItem(sampleItem());
    expect((await blob.fetchItems()).single.secret, secret);

    // 2. Take an encrypted backup, the step a person must do before flipping the flag.
    final backup = VaultBackupService();
    final backupBytes = await backup.export(
      items: await blob.fetchItems(),
      backupPassword: backupPassword,
      appVersion: 'gate-test',
    );
    final backupFile = File('${dir.path}/gate.vaulta')
      ..writeAsBytesSync(backupBytes);
    expect(backupFile.lengthSync(), greaterThan(0));

    // 3. Migrate: the first use of the SQLite repository moves the blob.
    final migrated = sqliteAt(dbPath('a'));
    expect((await migrated.fetchItems()).single.title, title);
    expect(await storage.read(VaultBlobMigration.legacyBlobKey), isNotNull);
    migrated.close();

    // 4. "Restart": a brand-new repository instance reads the same files.
    final afterRestart = sqliteAt(dbPath('a'));
    final reread = await afterRestart.fetchItems();
    expect(reread.single.secret, secret, reason: 'data must survive a restart');
    afterRestart.close();

    // 5. Restore the backup into a fresh database, as a new device would.
    final restored = await backup.decrypt(
      bytes: backupFile.readAsBytesSync(),
      backupPassword: backupPassword,
    );
    expect(restored.items.single.secret, secret);

    final fresh = sqliteAt(dbPath('b'));
    for (final item in restored.items) {
      await fresh.saveItem(item);
    }
    expect((await fresh.fetchItems()).single.title, title);
    fresh.close();

    // 6. And the restored database is still encrypted on disk.
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('${dbPath('b')}$suffix');
      if (!file.existsSync()) continue;
      final bytes = file.readAsBytesSync();
      for (final needle in [secret, title]) {
        expect(
          _contains(bytes, utf8.encode(needle)),
          isFalse,
          reason: 'the "$needle" string appeared in clear in the restored $suffix',
        );
      }
      // ignore: avoid_print
      print('gate · restored $suffix: ${bytes.length} bytes, sin texto en claro');
    }

    // 7. A wrong backup password must not restore anything.
    await expectLater(
      backup.decrypt(
        bytes: backupFile.readAsBytesSync(),
        backupPassword: 'clave-equivocada',
      ),
      throwsA(isA<VaultBackupException>()),
    );

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
