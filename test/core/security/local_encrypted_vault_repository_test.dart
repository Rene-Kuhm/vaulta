// ignore_for_file: avoid_dynamic_calls

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/aes_gcm_vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/biometric_auth_service.dart';
import 'package:gestor_contrasenas/core/security/local_encrypted_vault_repository.dart';
import 'package:gestor_contrasenas/core/security/master_password_service.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/security/vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/vault_security_controller.dart';
import 'package:gestor_contrasenas/core/security/vault_session.dart';
import 'package:gestor_contrasenas/core/sync/local_vault_mutation.dart';
import 'package:gestor_contrasenas/core/sync/remote_vault_blob_change.dart';
import 'package:gestor_contrasenas/core/sync/sync_item_payload_codec.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';

const _itemsKey = LocalEncryptedVaultRepository.encryptedVaultItemsKey;
const _markerKey = LocalEncryptedVaultRepository.itemPayloadMinVersionKey;
const _stagingKey = LocalEncryptedVaultRepository.encryptedVaultItemsStagingKey;
const _rekeyMarkerKey = LocalEncryptedVaultRepository.rekeyInProgressKey;

VaultSession _vaultSession({String keyId = 'key-generation-1', int seed = 1}) {
  return VaultSession.v2(
    keyId: keyId,
    secretKey: SecretKey(List<int>.generate(32, (i) => (i * 7 + seed) % 256)),
    kdf: const {'name': 'argon2id'},
    dekWrap: const {'alg': 'AES-256-GCM'},
  );
}

VaultItem _vaultItem(String id, {String secret = 'Str0ng!Secret#2026'}) {
  return VaultItem(
    id: id,
    title: 'Title $id',
    username: '$id@vaulta.test',
    secret: secret,
    category: VaultCategory.personal,
    strengthScore: 90,
    lastUpdatedLabel: 'now',
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

/// One device: its own secure storage, its own repository and its own
/// recording sink, opened under [session]. Two harnesses over the same
/// [VaultSession] model two devices holding the same vault key, which
/// is what "written on one device, opened on another" means.
class _Device {
  _Device({
    VaultSession? session,
    _ScriptedStorage? storage,
    VaultCryptoService? cryptoService,
  }) : session = session ?? _vaultSession(),
       storage = storage ?? _ScriptedStorage() {
    repository = LocalEncryptedVaultRepository(
      storage: this.storage,
      cryptoService: cryptoService ?? crypto,
      readSession: () => this.session,
      mutationSink: _RecordingSink(mutations),
    );
  }

  final VaultSession session;
  final _ScriptedStorage storage;
  final AesGcmVaultCryptoService crypto = AesGcmVaultCryptoService();
  final List<LocalVaultMutation> mutations = <LocalVaultMutation>[];

  late final LocalEncryptedVaultRepository repository;

  /// The mutation [repository] queued for the last [saveItem], or
  /// `null` when it deliberately queued none.
  Future<LocalVaultMutation?> saveAndCapture(VaultItem item) async {
    mutations.clear();
    await repository.saveItem(item);
    await Future<void>.delayed(Duration.zero);
    return mutations.isEmpty ? null : mutations.single;
  }

  Future<List<Map<String, dynamic>>> storedEnvelopes() async {
    final raw = await storage.read(_itemsKey);
    return (jsonDecode(raw!) as List<dynamic>)
        .cast<String>()
        .map((envelope) => jsonDecode(envelope) as Map<String, dynamic>)
        .toList();
  }

  /// Stores [envelopes] as the live vault blob, bypassing encryption
  /// so a test can seed a payload from an older build.
  Future<void> seedEnvelopes(List<String> envelopes) {
    return storage.save(_itemsKey, jsonEncode(envelopes));
  }

  /// A v3 envelope of [item]: sealed directly under the DEK with the
  /// record-bound v3 associated data, exactly as the build before v4
  /// stored it.
  Future<String> sealV3(VaultItem item) async {
    return crypto.encryptV3ForTesting(
      plaintext: jsonEncode(item.toJson()),
      secretKey: session,
      keyId: session.keyId,
      recordId: item.id,
    );
  }
}

void main() {
  group('LocalEncryptedVaultRepository', () {
    test('stores encrypted items without plaintext leakage', () async {
      final storage = _InMemorySecureStorageService();
      final controller = VaultSecurityController(
        storage: storage,
        masterPasswordService: MasterPasswordService.test(),
        biometricAuthService: const _FakeBiometricAuthService(),
      );
      await controller.initialize();
      await controller.createMasterPassword(
        password: 'StrongPass!2026',
        confirmation: 'StrongPass!2026',
        enableBiometrics: false,
      );

      final repository = LocalEncryptedVaultRepository(
        storage: storage,
        cryptoService: AesGcmVaultCryptoService(),
        readSession: () => controller.vaultSession,
      );

      final saved = await repository.saveItem(
        const VaultItem(
          id: 'github',
          title: 'GitHub',
          username: 'leo@example.com',
          secret: 'VeryStrong!2026',
          category: VaultCategory.work,
          strengthScore: 0,
          lastUpdatedLabel: '',
        ),
      );
      final items = await repository.fetchItems();
      final stored = await storage.read(
        LocalEncryptedVaultRepository.encryptedVaultItemsKey,
      );

      expect(items, hasLength(1));
      expect(saved.strengthScore, greaterThan(80));
      expect(stored, isNotNull);
      expect(stored, isNot(contains('GitHub')));
      expect(stored, isNot(contains('VeryStrong!2026')));

      final encodedItems = (jsonDecode(stored!) as List<dynamic>)
          .cast<String>();
      final firstPayload =
          jsonDecode(encodedItems.first) as Map<String, dynamic>;
      expect(
        firstPayload['v'],
        AesGcmVaultCryptoService.payloadVersionV4,
      );
      expect(firstPayload['rid'], 'github');
      expect(firstPayload['kdf']['name'], 'argon2id');
      expect(firstPayload['dek_wrap']['alg'], 'AES-256-GCM');
      expect(firstPayload['payload']['alg'], 'AES-256-GCM');
      expect(firstPayload['payload']['nonce_b64'], isNotEmpty);
      expect(firstPayload['payload']['tag_b64'], isNotEmpty);
    });

    test('security plan matches the platform key-recovery path', () {
      final android = LocalEncryptedVaultRepository.securityPlanFor(
        platform: TargetPlatform.android,
      );
      expect(android.biometricUnlock, isTrue);
      expect(android.hardwareBackedKeys, isTrue);
      expect(android.vaultEncryptionReady, isTrue);
      expect(android.notes, contains('v3'));
      expect(android.notes, contains('KeyStore'));
      expect(android.notes, isNot(contains('UX')));

      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.iOS,
      ]) {
        final plan = LocalEncryptedVaultRepository.securityPlanFor(
          platform: platform,
        );
        expect(plan.biometricUnlock, isFalse, reason: '$platform');
        expect(plan.hardwareBackedKeys, isFalse, reason: '$platform');
        expect(plan.secureStorage, isTrue, reason: '$platform');
        expect(plan.notes, contains('master password'), reason: '$platform');
      }

      // The web build never wires the KeyStore provider.
      final web = LocalEncryptedVaultRepository.securityPlanFor(
        platform: TargetPlatform.android,
        isWeb: true,
      );
      expect(web.biometricUnlock, isFalse);
      expect(web.hardwareBackedKeys, isFalse);
    });

    test('fails when no vault session is available', () async {
      final repository = LocalEncryptedVaultRepository(
        storage: _InMemorySecureStorageService(),
        cryptoService: AesGcmVaultCryptoService(),
        readSession: () => null,
      );

      expect(repository.fetchItems(), throwsStateError);
    });

    test('creates updates and deletes encrypted entries', () async {
      final storage = _InMemorySecureStorageService();
      final controller = VaultSecurityController(
        storage: storage,
        masterPasswordService: MasterPasswordService.test(),
        biometricAuthService: const _FakeBiometricAuthService(),
      );
      await controller.initialize();
      await controller.createMasterPassword(
        password: 'StrongPass!2026',
        confirmation: 'StrongPass!2026',
        enableBiometrics: false,
      );

      final repository = LocalEncryptedVaultRepository(
        storage: storage,
        cryptoService: AesGcmVaultCryptoService(),
        readSession: () => controller.vaultSession,
      );

      await repository.saveItem(
        const VaultItem(
          id: 'bank',
          title: 'Bank',
          username: 'finance@vaulta.app',
          secret: 'BankPass!2026',
          category: VaultCategory.finance,
          strengthScore: 0,
          lastUpdatedLabel: '',
        ),
      );

      final created = await repository.fetchItemById('bank');
      expect(created, isNotNull);
      expect(created!.title, 'Bank');

      await repository.saveItem(
        created.copyWith(
          title: 'Primary Bank',
          secret: 'RotatedStrongPass#2026',
          notes: 'Updated after quarterly rotation.',
        ),
      );

      final updated = await repository.fetchItemById('bank');
      expect(updated, isNotNull);
      expect(updated!.title, 'Primary Bank');
      expect(updated.notes, 'Updated after quarterly rotation.');
      expect(
        updated.strengthScore,
        greaterThanOrEqualTo(created.strengthScore),
      );

      await repository.deleteItem('bank');

      final items = await repository.fetchItems();
      expect(items, isEmpty);
    });

    test('rekeys all entries with a new master-derived key', () async {
      final storage = _InMemorySecureStorageService();
      final masterPasswordService = MasterPasswordService.test();
      final controller = VaultSecurityController(
        storage: storage,
        masterPasswordService: masterPasswordService,
        biometricAuthService: const _FakeBiometricAuthService(),
      );
      await controller.initialize();
      await controller.createMasterPassword(
        password: 'StrongPass!2026',
        confirmation: 'StrongPass!2026',
        enableBiometrics: false,
      );

      final oldSession = controller.vaultSession!;
      var activeSession = oldSession;
      final repository = LocalEncryptedVaultRepository(
        storage: storage,
        cryptoService: AesGcmVaultCryptoService(),
        readSession: () => activeSession,
      );

      await repository.saveItem(
        const VaultItem(
          id: 'mail',
          title: 'Mail',
          username: 'leo@mail.com',
          secret: 'MailPass!2026',
          category: VaultCategory.personal,
          strengthScore: 0,
          lastUpdatedLabel: '',
        ),
      );

      final newRecord = await masterPasswordService.createRecord(
        'AnotherStrong!2027',
      );
      final newSession = VaultSession(
        keyId: newRecord.keyId,
        secretKey: await masterPasswordService.deriveVaultKey(
          record: newRecord,
          password: 'AnotherStrong!2027',
        ),
        kdf: newRecord.kdf,
        dekWrap: newRecord.dekWrap,
      );

      await repository.rekeyEntries(
        sourceSession: oldSession,
        targetSession: newSession,
      );

      activeSession = newSession;
      final itemsWithNewSession = await repository.fetchItems();
      expect(itemsWithNewSession, hasLength(1));
      expect(itemsWithNewSession.first.secret, 'MailPass!2026');

      activeSession = oldSession;
      expect(repository.fetchItems(), throwsStateError);
    });

    test('a v4 save is queued for sync with its item key salt', () async {
      final device = _Device();

      final mutation = await device.saveAndCapture(_vaultItem('github'));

      expect(mutation, isNotNull);
      expect(mutation!.keyVersion, AesGcmVaultCryptoService.payloadVersionV4);
      expect(mutation.itemKeySalt, isNotNull);
      expect(mutation.itemKeySalt, isNotEmpty);
      expect(
        mutation.itemKeyVersion,
        AesGcmVaultCryptoService.currentItemKeyVersion,
      );
      // The salt on the wire is the one inside the stored envelope: the
      // receiving device derives the item key from it or opens nothing.
      final envelope = (await device.storedEnvelopes()).single;
      expect(mutation.itemKeySalt, envelope['salt']);
      // The record binding still rides the ciphertext column.
      final bound = SyncItemPayloadCodec.decode(mutation.ciphertext);
      expect(bound, isNotNull);
      expect(bound!.recordId, 'github');
      expect(mutation.nonce, isNotEmpty);
      expect(mutation.gcmTag, isNotEmpty);
    });

    test('a v4 payload written on one device opens on another', () async {
      final sender = _Device();
      final item = _vaultItem('github', secret: 'RoundTrip!Secret#2026');

      final mutation = await sender.saveAndCapture(item);

      expect(mutation, isNotNull);
      // Second device: same vault key, its own storage and repository.
      final receiver = _Device(session: sender.session);
      final rejected = await receiver.repository.applyRemoteSnapshots(
        snapshots: [
          RemoteVaultBlobSnapshot(
            recordId: 'github',
            version: 1,
            keyVersion: mutation!.keyVersion!,
            ciphertext: mutation.ciphertext,
            nonce: mutation.nonce,
            gcmTag: mutation.gcmTag,
            itemKeySalt: mutation.itemKeySalt,
            itemKeyVersion: mutation.itemKeyVersion,
            updatedAt: DateTime.utc(2026, 1, 2),
          ),
        ],
      );

      expect(rejected, isEmpty);
      final opened = await receiver.repository.fetchItemById('github');
      expect(opened, isNotNull);
      expect(opened!.title, item.title);
      expect(opened.username, item.username);
      expect(opened.secret, item.secret);
      // And it is stored re-sealed under its own item key, not the DEK.
      final envelope = (await receiver.storedEnvelopes()).single;
      expect(envelope['v'], AesGcmVaultCryptoService.payloadVersionV4);
      expect(envelope['salt'], isNotEmpty);
    });

    test('a v4 payload whose envelope lost its salt is not queued', () async {
      final device = _Device(
        cryptoService: _TamperedV4CryptoService(
          AesGcmVaultCryptoService(),
          tamper: (envelope) => envelope.remove('salt'),
        ),
      );

      final mutation = await device.saveAndCapture(_vaultItem('github'));

      expect(
        mutation,
        isNull,
        reason: 'a payload the receiving device cannot derive is not queued',
      );
      expect(device.mutations, isEmpty);
    });

    test('a v4 payload whose salt is not base64 is not queued', () async {
      final device = _Device(
        cryptoService: _TamperedV4CryptoService(
          AesGcmVaultCryptoService(),
          tamper: (envelope) => envelope['salt'] = '!!!not-base64!!!',
        ),
      );

      final mutation = await device.saveAndCapture(_vaultItem('github'));

      expect(mutation, isNull);
    });

    test('a v3 payload is still queued with no item key salt', () async {
      final device = _Device(
        cryptoService: _V3ForTestingCryptoService(AesGcmVaultCryptoService()),
      );

      final mutation = await device.saveAndCapture(_vaultItem('github'));

      expect(mutation, isNotNull);
      expect(mutation!.keyVersion, AesGcmVaultCryptoService.payloadVersionV3);
      expect(mutation.itemKeySalt, isNull);
      expect(mutation.itemKeyVersion, isNull);
      expect(
        SyncItemPayloadCodec.decode(mutation.ciphertext)?.recordId,
        'github',
      );
    });

    test('a v4 payload from another key generation is refused', () async {
      final sender = _Device();
      final mutation = await sender.saveAndCapture(_vaultItem('github'));
      final receiver = _Device(
        session: _vaultSession(keyId: 'key-generation-2', seed: 1),
      );

      final rejected = await receiver.repository.applyRemoteSnapshots(
        snapshots: [
          RemoteVaultBlobSnapshot(
            recordId: 'github',
            version: 1,
            keyVersion: mutation!.keyVersion!,
            ciphertext: mutation.ciphertext,
            nonce: mutation.nonce,
            gcmTag: mutation.gcmTag,
            itemKeySalt: mutation.itemKeySalt,
            itemKeyVersion: mutation.itemKeyVersion,
            updatedAt: DateTime.utc(2026, 1, 2),
          ),
        ],
      );

      expect(rejected, ['github']);
      expect(await receiver.repository.fetchItems(), isEmpty);
    });

    test('a v4-tagged payload with no salt on the wire is refused', () async {
      final sender = _Device();
      final mutation = await sender.saveAndCapture(_vaultItem('github'));
      final bound = SyncItemPayloadCodec.decode(mutation!.ciphertext)!;
      final receiver = _Device(session: sender.session);

      final rejected = await receiver.repository.applyRemoteSnapshots(
        snapshots: [
          RemoteVaultBlobSnapshot(
            recordId: 'github',
            version: 1,
            keyVersion: mutation.keyVersion!,
            ciphertext: SyncItemPayloadCodec.encode(
              recordId: bound.recordId,
              ciphertextB64: bound.ciphertextB64,
            ),
            nonce: mutation.nonce,
            gcmTag: mutation.gcmTag,
            updatedAt: DateTime.utc(2026, 1, 2),
          ),
        ],
      );

      expect(rejected, ['github']);
      expect(await receiver.repository.fetchItems(), isEmpty);
    });

    test('a v4-tagged payload with a corrupt salt is refused', () async {
      final sender = _Device();
      final mutation = await sender.saveAndCapture(_vaultItem('github'));
      final receiver = _Device(session: sender.session);

      final rejected = await receiver.repository.applyRemoteSnapshots(
        snapshots: [
          RemoteVaultBlobSnapshot(
            recordId: 'github',
            version: 1,
            keyVersion: mutation!.keyVersion!,
            ciphertext: mutation.ciphertext,
            nonce: mutation.nonce,
            gcmTag: mutation.gcmTag,
            itemKeySalt: '!!!not-base64!!!',
            itemKeyVersion: mutation.itemKeyVersion,
            updatedAt: DateTime.utc(2026, 1, 2),
          ),
        ],
      );

      expect(
        rejected,
        ['github'],
        reason: 'an undecodable salt must be refused, not thrown out of the pull',
      );
      expect(await receiver.repository.fetchItems(), isEmpty);
    });
  });

  group('v3 -> v4 item key migration', () {
    test(
      're-seals a v3 item under its own key and keeps it readable',
      () async {
        final device = _Device();
        final item = _vaultItem('github', secret: 'Sealed!Under#Dek2026');
        await device.seedEnvelopes([await device.sealV3(item)]);

        final migrated = await device.repository.migrateItemsToItemKeyed();

        expect(migrated, 1);
        final envelope = (await device.storedEnvelopes()).single;
        expect(envelope['v'], AesGcmVaultCryptoService.payloadVersionV4);
        expect(envelope['rid'], 'github');
        expect(envelope['iv'], AesGcmVaultCryptoService.currentItemKeyVersion);
        expect(envelope['salt'], isNotEmpty);
        final opened = await device.repository.fetchItemById('github');
        expect(opened, isNotNull);
        expect(opened!.secret, item.secret);
        expect(opened.toJson(), item.toJson());
      },
    );

    test('an already item-keyed vault is left untouched', () async {
      final device = _Device();
      await device.repository.saveItem(_vaultItem('github'));
      final before = await device.storage.read(_itemsKey);

      final migrated = await device.repository.migrateItemsToItemKeyed();

      expect(migrated, 0);
      expect(await device.storage.read(_itemsKey), before);
    });

    test('is idempotent', () async {
      final device = _Device();
      await device.seedEnvelopes([await device.sealV3(_vaultItem('github'))]);
      expect(await device.repository.migrateItemsToItemKeyed(), 1);
      final afterFirst = await device.storage.read(_itemsKey);

      final second = await device.repository.migrateItemsToItemKeyed();

      expect(second, 0);
      expect(await device.storage.read(_itemsKey), afterFirst);
    });

    test('the unlock-time hook runs it too', () async {
      final device = _Device();
      await device.seedEnvelopes([await device.sealV3(_vaultItem('github'))]);

      final migrated = await device.repository.migrateItemsToCurrentVersion();

      expect(migrated, 1);
      expect(
        (await device.storedEnvelopes()).single['v'],
        AesGcmVaultCryptoService.payloadVersionV4,
      );
      expect(await device.storage.read(_markerKey), '3');
    });

    test('a failed swap leaves the v3 items intact and retryable', () async {
      final device = _Device();
      final item = _vaultItem('github', secret: 'Sealed!Under#Dek2026');
      await device.seedEnvelopes([await device.sealV3(item)]);
      final before = await device.storage.read(_itemsKey);
      device.storage.failNextSaveOf(_itemsKey);

      await expectLater(
        device.repository.migrateItemsToItemKeyed(),
        throwsA(isA<_StorageWriteFailure>()),
      );

      expect(await device.storage.read(_itemsKey), before);
      expect(await device.storage.read(_markerKey), isNull);
      expect(await device.storage.read(_stagingKey), isNull);
      expect(await device.storage.read(_rekeyMarkerKey), isNull);
      expect((await device.repository.fetchItems()).single.secret, item.secret);

      expect(await device.repository.migrateItemsToItemKeyed(), 1);
      expect(
        (await device.storedEnvelopes()).single['v'],
        AesGcmVaultCryptoService.payloadVersionV4,
      );
    });
  });
}

class _StorageWriteFailure implements Exception {
  const _StorageWriteFailure();
}

class _ScriptedStorage implements SecureStorageService {
  final Map<String, String> _values = {};
  final Map<String, bool> _failures = {};

  /// Makes the next `save` of [key] throw.
  void failNextSaveOf(String key) {
    _failures[key] = false;
  }

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> save(String key, String value) async {
    if (_failures.remove(key) != null) {
      throw const _StorageWriteFailure();
    }
    _values[key] = value;
  }
}

class _RecordingSink implements LocalVaultMutationSink {
  _RecordingSink(this.mutations);

  final List<LocalVaultMutation> mutations;

  @override
  Future<void> onLocalMutation(LocalVaultMutation mutation) async {
    mutations.add(mutation);
  }
}

/// Writes v4 envelopes with a tampered header, to prove the repository
/// refuses to queue a payload a second device could not open.
class _TamperedV4CryptoService implements VaultCryptoService {
  _TamperedV4CryptoService(this._inner, {required this.tamper});

  final AesGcmVaultCryptoService _inner;

  /// Mutates the clear-text v4 header before it reaches the vault.
  final void Function(Map<String, dynamic> envelope) tamper;

  @override
  Future<String> encrypt({
    required String plaintext,
    required Object secretKey,
    required String keyId,
    required String recordId,
  }) async {
    final envelope =
        jsonDecode(
              await _inner.encrypt(
                plaintext: plaintext,
                secretKey: secretKey,
                keyId: keyId,
                recordId: recordId,
              ),
            )
            as Map<String, dynamic>;
    tamper(envelope);
    return jsonEncode(envelope);
  }

  @override
  Future<String> decrypt({
    required String ciphertext,
    required Object secretKey,
    required String expectedKeyId,
    required String? recordId,
    int minimumVersion = 1,
  }) {
    return _inner.decrypt(
      ciphertext: ciphertext,
      secretKey: secretKey,
      expectedKeyId: expectedKeyId,
      recordId: recordId,
      minimumVersion: minimumVersion,
    );
  }

  @override
  VaultItemPayloadHeader inspect(String ciphertext) =>
      _inner.inspect(ciphertext);
}

/// Writes v3 envelopes (DEK-sealed, record-bound) instead of the current
/// v4 format, to prove a pre-v4 build's payload still reaches the wire
/// with no item key salt on it.
class _V3ForTestingCryptoService implements VaultCryptoService {
  _V3ForTestingCryptoService(this._inner);

  final AesGcmVaultCryptoService _inner;

  @override
  Future<String> encrypt({
    required String plaintext,
    required Object secretKey,
    required String keyId,
    required String recordId,
  }) {
    return _inner.encryptV3ForTesting(
      plaintext: plaintext,
      secretKey: secretKey,
      keyId: keyId,
      recordId: recordId,
    );
  }

  @override
  Future<String> decrypt({
    required String ciphertext,
    required Object secretKey,
    required String expectedKeyId,
    required String? recordId,
    int minimumVersion = 1,
  }) {
    return _inner.decrypt(
      ciphertext: ciphertext,
      secretKey: secretKey,
      expectedKeyId: expectedKeyId,
      recordId: recordId,
      minimumVersion: minimumVersion,
    );
  }

  @override
  VaultItemPayloadHeader inspect(String ciphertext) =>
      _inner.inspect(ciphertext);
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
      availableBiometrics: [],
    );
  }
}
