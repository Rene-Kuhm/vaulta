import 'dart:convert';
import 'dart:async';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../../features/vault/domain/vault_item.dart';
import '../../features/vault/domain/vault_summary.dart';
import '../sync/local_vault_mutation.dart';
import '../sync/remote_vault_blob_change.dart';
import '../sync/sync_item_payload_codec.dart';
import 'platform_security_plan.dart';
import 'secure_storage_service.dart';
import 'vault_crypto_service.dart';
import 'vault_repository.dart';
import 'vault_session.dart';

/// Function shape that returns the active [VaultSession] (or `null`
/// when the vault is locked). Injected into the repository so it can
/// read the DEK without holding a direct reference to the controller.
typedef VaultSessionReader = VaultSession? Function();

/// Production [VaultRepository] backed by an on-device encrypted
/// store. The DEK is held only in memory (in the active
/// [VaultSession]); on disk the items are stored as a JSON list of
/// per-item AES-256-GCM envelopes keyed by that DEK. Every envelope
/// written by this class is payload v3, bound to its record id and key
/// id through GCM associated data.
///
/// The repository also coordinates rekeying when the master password
/// changes and the one-time v1/v2 -> v3 migration: both stage the new
/// encrypted blob in a separate key and only swap the live key when
/// the rewrite completes, so an interrupted rewrite never leaves the
/// vault half-encrypted.
class LocalEncryptedVaultRepository implements VaultRepository {
  /// Builds a [LocalEncryptedVaultRepository]. The [readSession] is
  /// called on every read/write to get the current DEK; the optional
  /// [mutationSink] receives local upsert/delete notifications so the
  /// sync layer can drain them.
  LocalEncryptedVaultRepository({
    required SecureStorageService storage,
    required VaultCryptoService cryptoService,
    required VaultSessionReader readSession,
    LocalVaultMutationSink? mutationSink,
  }) : _storage = storage,
       _cryptoService = cryptoService,
       _readSession = readSession,
       _mutationSink = mutationSink;

  /// Secure storage key for the live encrypted vault blob.
  static const encryptedVaultItemsKey = 'vault_encrypted_items_v1';

  /// Secure storage key for the staging blob used during rekeying.
  /// Holds the new encrypted vault while the rekey is in flight; if
  /// the rekey is interrupted, recovery reads from this key.
  static const encryptedVaultItemsStagingKey =
      'vault_encrypted_items_v1_staging';

  /// Secure storage key for the "rekey in progress" flag.
  static const rekeyInProgressKey = 'vault_rekey_in_progress_v1';

  /// Secure storage key for the vault's minimum accepted item payload
  /// version. Written as `'3'` once every locally stored item is v3;
  /// from then on v1/v2 payloads (local or pulled from sync) are
  /// refused instead of decrypted. Lives in secure storage so killing
  /// the app cannot reset the downgrade defense.
  static const itemPayloadMinVersionKey = 'vault_item_payload_min_version';

  /// Payload version every item is written with, and the minimum the
  /// vault accepts after migration.
  static const currentItemPayloadVersion = 3;

  /// Capability snapshot for the security screen on the current
  /// platform. See [securityPlanFor].
  static PlatformSecurityPlan get securityPlan =>
      securityPlanFor(platform: defaultTargetPlatform, isWeb: kIsWeb);

  /// Capability snapshot for [platform].
  ///
  /// On Android the app wires `AndroidKeystoreEnvelopeKeyProvider`
  /// (see `password_manager_app.dart`): the DEK is wrapped under a seed
  /// that is RSA-OAEP-encrypted by a KeyStore RSA-2048 key requiring a
  /// fresh `BIOMETRIC_STRONG` prompt bound through a `CryptoObject`
  /// (`MainActivity.kt`, `KeystoreChannel.kt`). Biometric unlock is
  /// therefore a real key-recovery path backed by KeyStore keys. Every
  /// other target uses a no-op envelope provider: the vault opens with
  /// the master password only and no hardware-backed key is involved.
  static PlatformSecurityPlan securityPlanFor({
    required TargetPlatform platform,
    bool isWeb = false,
  }) {
    final androidKeystore = !isWeb && platform == TargetPlatform.android;
    const itemFormat =
        'Items del vault en formato v3: KEK Argon2id desde la master password, DEK aleatoria por vault envuelta con AES-256-GCM, y cada item cifrado con AES-256-GCM usando como datos asociados (AAD) "vaulta:item:v3|<recordId>|<keyId>", asi un ciphertext no puede moverse a otro registro ni reutilizarse con otra clave. Tras migrar a v3 se rechazan payloads v1/v2. La DEK vive solo en memoria de sesion.';
    return PlatformSecurityPlan(
      secureStorage: true,
      biometricUnlock: androidKeystore,
      hardwareBackedKeys: androidKeystore,
      vaultEncryptionReady: true,
      notes: androidKeystore
          ? '$itemFormat Desbloqueo biometrico: la DEK se recupera con una clave RSA-2048 del Android KeyStore que exige BIOMETRIC_STRONG con CryptoObject; el respaldo en TEE/StrongBox depende del dispositivo.'
          : '$itemFormat En esta plataforma no hay desbloqueo biometrico ni claves con respaldo de hardware: el vault se abre solo con la master password.',
    );
  }

  final SecureStorageService _storage;
  final VaultCryptoService _cryptoService;
  final VaultSessionReader _readSession;
  final LocalVaultMutationSink? _mutationSink;

  @override
  Future<List<VaultItem>> fetchItems() async {
    await _recoverFromInterruptedRekey();
    final session = _requireSession();
    final minimumVersion = await _readMinimumVersion();
    final encryptedItems = await _readEncryptedItems();
    final items = <VaultItem>[];

    for (final encrypted in encryptedItems) {
      final decrypted = await _decryptStoredItem(
        encrypted: encrypted,
        session: session,
        minimumVersion: minimumVersion,
      );
      items.add(decrypted.item);
    }

    items.sort((left, right) {
      final leftUpdated = left.updatedAt;
      final rightUpdated = right.updatedAt;
      if (leftUpdated == null && rightUpdated == null) {
        return right.lastUpdatedLabel.compareTo(left.lastUpdatedLabel);
      }
      if (leftUpdated == null) {
        return 1;
      }
      if (rightUpdated == null) {
        return -1;
      }
      return rightUpdated.compareTo(leftUpdated);
    });

    return items;
  }

  @override
  Future<VaultSummary> fetchSummary() async {
    final items = await fetchItems();
    final weakItems = items.where((item) => item.strengthScore < 80).length;
    final reusedItems = _countReusedSecrets(items);
    final averageScore = items.isEmpty
        ? 0
        : items.fold<int>(0, (sum, item) => sum + item.strengthScore) ~/
              items.length;

    return VaultSummary(
      totalItems: items.length,
      weakItems: weakItems,
      reusedItems: reusedItems,
      securityScore: averageScore,
      connectedDevices: 1,
      syncEnabled: false,
    );
  }

  @override
  Future<VaultItem?> fetchItemById(String id) async {
    final items = await fetchItems();
    for (final item in items) {
      if (item.id == id) {
        return item;
      }
    }
    return null;
  }

  @override
  Future<VaultItem> saveItem(VaultItem item) async {
    final items = List<VaultItem>.of(await fetchItems());
    final now = DateTime.now();
    final persisted = item.copyWith(
      strengthScore: estimatePasswordStrength(item.secret),
      updatedAt: now,
      lastUpdatedLabel: formatVaultUpdatedLabel(now, now: now),
    );
    final index = items.indexWhere((candidate) => candidate.id == persisted.id);

    if (index == -1) {
      items.add(persisted);
    } else {
      items[index] = persisted;
    }

    final encryptedById = await _saveEncryptedItems(items);
    final syncPayload = _extractSyncPayload(encryptedById[persisted.id]);
    if (syncPayload != null) {
      unawaited(
        _mutationSink
            ?.onLocalMutation(
              LocalVaultMutation.upsert(
                localRecordId: persisted.id,
                ciphertext: syncPayload.ciphertext,
                nonce: syncPayload.nonce,
                gcmTag: syncPayload.gcmTag,
                keyVersion: syncPayload.keyVersion,
                occurredAt: now.toUtc(),
              ),
            )
            .catchError((_) {}),
      );
    }
    return persisted;
  }

  @override
  Future<void> deleteItem(String id) async {
    final items = List<VaultItem>.of(await fetchItems());
    items.removeWhere((item) => item.id == id);
    await _saveEncryptedItems(items);
    unawaited(
      _mutationSink
          ?.onLocalMutation(
            LocalVaultMutation.delete(
              localRecordId: id,
              occurredAt: DateTime.now().toUtc(),
            ),
          )
          .catchError((_) {}),
    );
  }

  /// Re-encrypts every item from [sourceSession] (old key) under
  /// [targetSession] (new key), atomically swapping the live blob.
  /// The output is always v3; legacy v1/v2 input is accepted only
  /// while the vault has not been migrated yet.
  Future<void> rekeyEntries({
    required VaultSession sourceSession,
    required VaultSession targetSession,
  }) async {
    await _recoverFromInterruptedRekey();

    final encryptedItems = await _readEncryptedItems();
    if (encryptedItems.isEmpty) {
      await _clearRekeyArtifacts(swallowErrors: true);
      return;
    }

    final minimumVersion = await _readMinimumVersion();
    final reencryptedItems = <String>[];

    for (final encrypted in encryptedItems) {
      final decrypted = await _decryptStoredItem(
        encrypted: encrypted,
        session: sourceSession,
        minimumVersion: minimumVersion,
      );
      final reencrypted = await _cryptoService.encrypt(
        plaintext: decrypted.plaintext,
        secretKey: targetSession,
        keyId: targetSession.keyId,
        recordId: decrypted.item.id,
      );
      reencryptedItems.add(reencrypted);
    }

    await _commitStaged(jsonEncode(reencryptedItems));
    await _markMigratedToCurrentVersion();
  }

  /// Rewrites every v1/v2 item as v3 under the active session in one
  /// atomic swap (same staging + in-progress marker as [rekeyEntries]),
  /// then persists the v3 minimum-version marker. Returns the number of
  /// items that were rewritten (0 when the vault was already v3).
  ///
  /// Called after every successful unlock. Idempotent, and safe to
  /// interrupt: until the live blob is swapped the old items are left
  /// untouched and stay decryptable, and the marker is written only
  /// after the swap committed, so a crash at any point leaves either
  /// the intact legacy vault (the next unlock retries) or a complete v3
  /// vault whose marker the next call writes.
  Future<int> migrateItemsToCurrentVersion() async {
    await _recoverFromInterruptedRekey();
    final session = _requireSession();
    final minimumVersion = await _readMinimumVersion();
    final encryptedItems = await _readEncryptedItems();

    final legacyCount = encryptedItems
        .where(
          (encrypted) =>
              _cryptoService.inspect(encrypted).version <
              currentItemPayloadVersion,
        )
        .length;
    if (legacyCount == 0) {
      await _markMigratedToCurrentVersion();
      return 0;
    }

    final migrated = <String>[];
    for (final encrypted in encryptedItems) {
      final decrypted = await _decryptStoredItem(
        encrypted: encrypted,
        session: session,
        minimumVersion: minimumVersion,
      );
      if (decrypted.version >= currentItemPayloadVersion) {
        migrated.add(encrypted);
        continue;
      }
      migrated.add(
        await _cryptoService.encrypt(
          plaintext: decrypted.plaintext,
          secretKey: session,
          keyId: session.keyId,
          recordId: decrypted.item.id,
        ),
      );
    }

    await _commitStaged(jsonEncode(migrated));
    await _markMigratedToCurrentVersion();
    return legacyCount;
  }

  /// Stages [payload] behind the rekey-in-progress marker, then swaps
  /// it into the live key. When the swap fails and did not commit, the
  /// artifacts are cleared and the error is rethrown with the previous
  /// live blob intact.
  Future<void> _commitStaged(String payload) async {
    await _storage.save(rekeyInProgressKey, 'true');
    await _storage.save(encryptedVaultItemsStagingKey, payload);

    try {
      await _storage.save(encryptedVaultItemsKey, payload);
    } catch (_) {
      final committed = await _didSwapCommit(payload);
      if (!committed) {
        await _clearRekeyArtifacts(swallowErrors: true);
        rethrow;
      }
    }

    await _clearRekeyArtifacts(swallowErrors: true);
  }

  Future<Map<String, String>> _saveEncryptedItems(List<VaultItem> items) async {
    await _recoverFromInterruptedRekey();
    final session = _requireSession();
    final encryptedItems = <String>[];
    final encryptedById = <String, String>{};
    for (final item in items) {
      final encrypted = await _cryptoService.encrypt(
        plaintext: jsonEncode(item.toJson()),
        secretKey: session,
        keyId: session.keyId,
        recordId: item.id,
      );
      encryptedItems.add(encrypted);
      encryptedById[item.id] = encrypted;
    }

    await _storage.save(encryptedVaultItemsKey, jsonEncode(encryptedItems));
    // Every item was just written as v3, so the vault now qualifies for
    // the downgrade defense even if it never ran the explicit migration.
    await _markMigratedToCurrentVersion();
    return encryptedById;
  }

  _SyncBlobPayload? _extractSyncPayload(String? encryptedItemPayload) {
    if (encryptedItemPayload == null || encryptedItemPayload.isEmpty) {
      return null;
    }

    final payload = jsonDecode(encryptedItemPayload);
    if (payload is! Map<String, dynamic>) {
      return null;
    }

    final nestedPayload = payload['payload'] is Map<String, dynamic>
        ? payload['payload'] as Map<String, dynamic>
        : payload;
    final ciphertext =
        (nestedPayload['ciphertext_b64'] ?? nestedPayload['ciphertext'])
            as String?;
    final nonce =
        (nestedPayload['nonce_b64'] ?? nestedPayload['nonce']) as String?;
    final gcmTag =
        (nestedPayload['tag_b64'] ?? nestedPayload['mac']) as String?;

    if (ciphertext == null ||
        ciphertext.isEmpty ||
        nonce == null ||
        nonce.isEmpty) {
      return null;
    }

    final version = (payload['v'] ?? payload['version'] ?? 1) as int;
    if (version >= SyncItemPayloadCodec.boundPayloadVersion) {
      final recordId = payload['rid'];
      if (recordId is! String || recordId.isEmpty) {
        return null;
      }
      return _SyncBlobPayload(
        ciphertext: SyncItemPayloadCodec.encode(
          recordId: recordId,
          ciphertextB64: ciphertext,
        ),
        nonce: nonce,
        gcmTag: gcmTag,
        keyVersion: version,
      );
    }

    return _SyncBlobPayload(
      ciphertext: ciphertext,
      nonce: nonce,
      gcmTag: gcmTag,
      keyVersion: version,
    );
  }

  /// Applies a batch of remote snapshots to the local vault, fed by
  /// the pull sync path. Each snapshot is decrypted with the active
  /// session and the resulting vault is written back (always as v3).
  /// Idempotent: applying the same snapshots twice yields the same
  /// vault.
  ///
  /// Snapshots that fail validation are skipped, never applied, and
  /// their record ids are returned so the sync layer can surface them:
  /// a v1/v2 payload once the vault is migrated (downgrade), a v3
  /// payload bound to another record id or key, a decrypted item whose
  /// `id` differs from the bound record id, or a GCM authentication
  /// failure.
  Future<List<String>> applyRemoteSnapshots({
    required Iterable<RemoteVaultBlobSnapshot> snapshots,
  }) async {
    await _recoverFromInterruptedRekey();
    final session = _requireSession();
    final minimumVersion = await _readMinimumVersion();
    final currentItems = <String, VaultItem>{
      for (final item in await fetchItems()) item.id: item,
    };
    final rejected = <String>[];

    for (final snapshot in snapshots) {
      final localId = snapshot.recordId;
      if (snapshot.isTombstone) {
        currentItems.remove(localId);
        continue;
      }
      final isBound =
          snapshot.keyVersion >= SyncItemPayloadCodec.boundPayloadVersion;
      final encrypted = _encryptedPayloadFromSnapshot(snapshot);
      if (encrypted == null) {
        if (isBound) {
          rejected.add(localId);
        }
        continue;
      }
      try {
        final decrypted = await _decryptStoredItem(
          encrypted: encrypted,
          session: session,
          minimumVersion: minimumVersion,
          expectedRecordId: isBound ? localId : null,
        );
        currentItems[decrypted.item.id] = decrypted.item;
      } on VaultPayloadRejectedError {
        rejected.add(localId);
      } on SecretBoxAuthenticationError {
        rejected.add(localId);
      }
    }

    await _saveEncryptedItems(currentItems.values.toList(growable: false));
    return rejected;
  }

  String? _encryptedPayloadFromSnapshot(RemoteVaultBlobSnapshot snapshot) {
    final ciphertext = snapshot.ciphertext;
    final nonce = snapshot.nonce;
    if (ciphertext == null ||
        ciphertext.isEmpty ||
        nonce == null ||
        nonce.isEmpty) {
      return null;
    }
    final session = _requireSession();
    if (snapshot.keyVersion >= SyncItemPayloadCodec.boundPayloadVersion) {
      final bound = SyncItemPayloadCodec.decode(ciphertext);
      if (bound == null) {
        return null;
      }
      return jsonEncode({
        'v': snapshot.keyVersion,
        'keyId': session.keyId,
        'rid': bound.recordId,
        'payload': {
          'alg': 'AES-256-GCM',
          'nonce_b64': nonce,
          'ciphertext_b64': bound.ciphertextB64,
          'tag_b64': snapshot.gcmTag ?? '',
        },
      });
    }
    if (snapshot.keyVersion == 2 && session.isV2) {
      return jsonEncode({
        'v': 2,
        'keyId': session.keyId,
        'kdf': session.kdf,
        'dek_wrap': session.dekWrap,
        'payload': {
          'alg': 'AES-256-GCM',
          'nonce_b64': nonce,
          'ciphertext_b64': ciphertext,
          'tag_b64': snapshot.gcmTag ?? '',
        },
      });
    }
    return jsonEncode({
      'version': 1,
      'algorithm': 'aes-256-gcm',
      'keyId': session.keyId,
      'nonce': nonce,
      'ciphertext': ciphertext,
      'mac': snapshot.gcmTag ?? '',
    });
  }

  Future<List<String>> _readEncryptedItems() async {
    final raw = await _storage.read(encryptedVaultItemsKey);
    if (raw == null || raw.isEmpty) {
      return const [];
    }
    return (jsonDecode(raw) as List<dynamic>).cast<String>();
  }

  /// Decrypts one stored envelope and enforces the record binding.
  ///
  /// For v3 the record id comes from the envelope (and must equal
  /// [expectedRecordId] when the caller knows it); GCM authenticates
  /// it, and the decrypted item's `id` must equal it. Legacy payloads
  /// carry no binding, so the id check only runs when the caller
  /// passes [expectedRecordId].
  Future<_DecryptedItem> _decryptStoredItem({
    required String encrypted,
    required VaultSession session,
    required int minimumVersion,
    String? expectedRecordId,
  }) async {
    final header = _cryptoService.inspect(encrypted);
    final isBound = header.version >= currentItemPayloadVersion;
    final recordId = isBound ? header.recordId : null;
    if (isBound &&
        (recordId == null ||
            (expectedRecordId != null && recordId != expectedRecordId))) {
      throw VaultPayloadRejectedError(
        VaultPayloadRejection.recordMismatch,
        'Vault payload is bound to a different record.',
      );
    }
    final plaintext = await _cryptoService.decrypt(
      ciphertext: encrypted,
      secretKey: session,
      expectedKeyId: session.keyId,
      recordId: recordId,
      minimumVersion: minimumVersion,
    );
    final item = VaultItem.fromJson(
      jsonDecode(plaintext) as Map<String, dynamic>,
    );
    final requiredId = recordId ?? expectedRecordId;
    if (requiredId != null && item.id != requiredId) {
      throw VaultPayloadRejectedError(
        VaultPayloadRejection.recordMismatch,
        'Decrypted item id does not match its bound record id.',
      );
    }
    return _DecryptedItem(
      item: item,
      plaintext: plaintext,
      version: header.version,
    );
  }

  Future<int> _readMinimumVersion() async {
    final raw = await _storage.read(itemPayloadMinVersionKey);
    if (raw == null || raw.isEmpty) {
      return 1;
    }
    // A marker that exists but cannot be parsed is treated as the
    // strictest known value: fail closed rather than re-open v1/v2.
    return int.tryParse(raw) ?? currentItemPayloadVersion;
  }

  Future<void> _markMigratedToCurrentVersion() async {
    final current = await _readMinimumVersion();
    if (current >= currentItemPayloadVersion) {
      return;
    }
    await _storage.save(
      itemPayloadMinVersionKey,
      '$currentItemPayloadVersion',
    );
  }

  Future<void> _recoverFromInterruptedRekey() async {
    final marker = await _storage.read(rekeyInProgressKey);
    if (marker != 'true') {
      final staleStaging = await _storage.read(encryptedVaultItemsStagingKey);
      if (staleStaging != null) {
        await _storage.delete(encryptedVaultItemsStagingKey);
      }
      return;
    }

    await _clearRekeyArtifacts(swallowErrors: true);
  }

  Future<bool> _didSwapCommit(String expectedPayload) async {
    final committedPayload = await _storage.read(encryptedVaultItemsKey);
    return committedPayload == expectedPayload;
  }

  Future<void> _clearRekeyArtifacts({required bool swallowErrors}) async {
    Future<void> runDelete(String key) async {
      try {
        await _storage.delete(key);
      } catch (_) {
        if (!swallowErrors) {
          rethrow;
        }
      }
    }

    await runDelete(encryptedVaultItemsStagingKey);
    await runDelete(rekeyInProgressKey);
  }

  VaultSession _requireSession() {
    final session = _readSession();
    if (session == null) {
      throw StateError(
        'Vault encryption key unavailable. Unlock with the master password first.',
      );
    }
    return session;
  }

  int _countReusedSecrets(List<VaultItem> items) {
    final counts = <String, int>{};
    for (final item in items) {
      counts.update(item.secret, (current) => current + 1, ifAbsent: () => 1);
    }

    return counts.values
        .where((count) => count > 1)
        .fold<int>(0, (sum, count) => sum + count);
  }
}

class _DecryptedItem {
  const _DecryptedItem({
    required this.item,
    required this.plaintext,
    required this.version,
  });

  final VaultItem item;
  final String plaintext;
  final int version;
}

class _SyncBlobPayload {
  const _SyncBlobPayload({
    required this.ciphertext,
    required this.nonce,
    required this.gcmTag,
    required this.keyVersion,
  });

  final String ciphertext;
  final String nonce;
  final String? gcmTag;
  final int keyVersion;
}
