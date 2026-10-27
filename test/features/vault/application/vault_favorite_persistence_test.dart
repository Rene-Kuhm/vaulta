// Favorites must survive the real persistence path and arrive through
// imports. The flag lives inside the encrypted payload (an optional
// field, like `passwordHistory`), so neither the payload version, the
// storage schema nor the sync wire change; these tests pin that.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/aes_gcm_vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/local_encrypted_vault_repository.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/vault_session.dart';
import 'package:gestor_contrasenas/features/vault/application/vault_backup_merger.dart';
import 'package:gestor_contrasenas/features/vault/application/vault_import_parser.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';

/// Minimal in-memory [SecureStorageService]: the repository sees exactly
/// the key/value surface it uses on device.
class _MemorySecureStorage implements SecureStorageService {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> save(String key, String value) async => values[key] = value;
}

VaultSession _session() {
  return VaultSession.v2(
    keyId: 'key-generation-1',
    secretKey: SecretKey(List<int>.generate(32, (i) => (i * 7 + 3) % 256)),
    kdf: const {'name': 'argon2id'},
    dekWrap: const {'alg': 'AES-256-GCM'},
  );
}

VaultItem _item({bool isFavorite = false, String id = 'gh'}) {
  return VaultItem(
    id: id,
    title: 'GitHub',
    username: 'leo@example.com',
    secret: 'StrongPass!2026',
    category: VaultCategory.work,
    strengthScore: 90,
    lastUpdatedLabel: 'Updated now',
    website: 'https://github.com',
    updatedAt: DateTime.utc(2026, 10, 1),
    isFavorite: isFavorite,
  );
}

void main() {
  group('favorites through the encrypted repository', () {
    late _MemorySecureStorage storage;
    late LocalEncryptedVaultRepository repository;

    setUp(() {
      storage = _MemorySecureStorage();
      repository = LocalEncryptedVaultRepository(
        storage: storage,
        cryptoService: AesGcmVaultCryptoService(),
        readSession: _session,
      );
    });

    test('survives a save -> load round trip', () async {
      await repository.saveItem(_item(isFavorite: true));

      final loaded = await repository.fetchItems();

      expect(loaded, hasLength(1));
      expect(loaded.single.isFavorite, isTrue);
      expect(
        await storage.read(
          LocalEncryptedVaultRepository.encryptedVaultItemsKey,
        ),
        isNotNull,
      );
    });

    test('keeps every other field while toggling the flag', () async {
      await repository.saveItem(_item());
      var loaded = await repository.fetchItems();
      expect(loaded.single.isFavorite, isFalse);

      await repository.saveItem(loaded.single.copyWith(isFavorite: true));
      loaded = await repository.fetchItems();

      expect(loaded.single.isFavorite, isTrue);
      expect(loaded.single.title, 'GitHub');
      expect(loaded.single.username, 'leo@example.com');
      expect(loaded.single.secret, 'StrongPass!2026');
      expect(loaded.single.website, 'https://github.com');
    });

    test(
      'loads an entry written before favorites existed as not favorite',
      () async {
        // What an older build persisted: the same payload without the key.
        final legacyPayload = _item().toJson()..remove('isFavorite');
        final decoded = VaultItem.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(jsonEncode(legacyPayload)) as Map,
          ),
        );

        await repository.saveItem(decoded);
        final loaded = await repository.fetchItems();

        expect(loaded.single.isFavorite, isFalse);
      },
    );
  });

  group('favorites through an import', () {
    test('a Bitwarden JSON entry marked favorite arrives as favorite', () {
      const content = '''
      {
        "items": [
          {
            "name": "GitHub",
            "favorite": true,
            "notes": "work account",
            "login": {
              "username": "leo@example.com",
              "password": "StrongPass!2026",
              "uris": [{"uri": "https://github.com"}]
            }
          },
          {
            "name": "Bank",
            "favorite": false,
            "login": {
              "username": "leo@example.com",
              "password": "BankPass!2026",
              "uris": [{"uri": "https://bank.example.com"}]
            }
          }
        ]
      }
      ''';

      final preview = const VaultImportParser().parse(
        fileName: 'bitwarden_export.json',
        content: content,
        existingItems: const <VaultItem>[],
      );

      expect(preview.candidates, hasLength(2));
      final byTitle = {
        for (final candidate in preview.candidates)
          candidate.item.title: candidate.item,
      };
      expect(byTitle['GitHub']!.isFavorite, isTrue);
      expect(byTitle['Bank']!.isFavorite, isFalse);
    });

    test('a generic JSON import without the column is not favorite', () {
      const content =
          '[{"name": "Email", "username": "leo", "password": "Mail!2026"}]';

      final preview = const VaultImportParser().parse(
        fileName: 'passwords.json',
        content: content,
        existingItems: const <VaultItem>[],
      );

      expect(preview.candidates.single.item.isFavorite, isFalse);
    });

    test(
      'a restored backup keeps the favorite flag when it is written',
      () async {
        // A backup written by this build carries the flag inside the
        // encrypted payload JSON; restoring it must not drop it.
        final backupItem = VaultItem.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(jsonEncode(_item(isFavorite: true).toJson())) as Map,
          ),
        );
        expect(backupItem.isFavorite, isTrue);

        final storage = _MemorySecureStorage();
        final repository = LocalEncryptedVaultRepository(
          storage: storage,
          cryptoService: AesGcmVaultCryptoService(),
          readSession: _session,
        );

        await const VaultBackupMerger().apply(
          backupItems: [backupItem],
          repository: repository,
          conflictSuffix: ' (restored)',
        );

        final loaded = await repository.fetchItems();
        expect(loaded, hasLength(1));
        expect(loaded.single.isFavorite, isTrue);
        expect(loaded.single.title, 'GitHub');
      },
    );
  });
}
