import 'dart:convert';
import 'dart:async';

import 'package:cryptography/cryptography.dart';

import '../../features/vault/domain/vault_item.dart';
import '../../features/vault/domain/vault_summary.dart';
import '../sync/local_vault_mutation.dart';
import '../sync/remote_snapshot_applier.dart';
import '../sync/remote_snapshot_envelope.dart';
import '../sync/remote_vault_blob_change.dart';
import '../sync/sync_item_payload_codec.dart';
import 'aes_gcm_vault_crypto_service.dart';
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
/// per-item AES-256-GCM envelopes. Every envelope written by this class
/// is payload v4: sealed under a per-item key derived from the DEK and
/// bound to its record id, key id and item key version through GCM
/// associated data.
///
/// The repository also coordinates rekeying when the master password
/// changes and the one-time v1/v2/v3 -> v4 migration: both stage the new
/// encrypted blob in a separate key and only swap the live key when
/// the rewrite completes, so an interrupted rewrite never leaves the
/// vault half-encrypted.
class LocalEncryptedVaultRepository
    implements VaultRepository, RemoteSnapshotApplier {
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
                itemKeySalt: syncPayload.itemKeySalt,
                itemKeyVersion: syncPayload.itemKeyVersion,
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

  /// Rewrites every stored item that is not yet sealed under its own key
  /// (payload v4) as such, in one atomic swap (same staging +
  /// in-progress marker as [rekeyEntries]), then persists the minimum
  /// payload version marker. Returns the number of items rewritten (0
  /// when every item already has its own key).
  ///
  /// A v3 item is sealed directly under the DEK, so "every item has its
  /// own key" is false of it until it is rewritten here (ADR-001, G2b).
  /// Legacy v1/v2 items are covered by the same pass: [encrypt] only
  /// ever writes the current version, so a vault at v1/v2 goes straight
  /// to v4.
  ///
  /// Called by [migrateItemsToCurrentVersion] after every successful
  /// unlock, so no user action is needed. Idempotent, and safe to
  /// interrupt: until the live blob is swapped the old items are left
  /// untouched and stay decryptable, and the marker is written only
  /// after the swap committed, so a crash at any point leaves either the
  /// intact pre-migration vault (the next unlock retries) or a complete
  /// v4 vault.
  Future<int> migrateItemsToItemKeyed() async {
    await _recoverFromInterruptedRekey();
    final session = _requireSession();
    final minimumVersion = await _readMinimumVersion();
    final encryptedItems = await _readEncryptedItems();

    final staleCount = encryptedItems
        .where(
          (encrypted) =>
              _cryptoService.inspect(encrypted).version <
              AesGcmVaultCryptoService.payloadVersionV4,
        )
        .length;
    if (staleCount == 0) {
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
      if (decrypted.version >= AesGcmVaultCryptoService.payloadVersionV4) {
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
    return staleCount;
  }

  /// Upgrades every stored item to the payload version this build writes
  /// and persists the minimum-version marker. Returns the number of
  /// items rewritten (0 when the vault was already current).
  ///
  /// Called after every successful unlock. Idempotent, and safe to
  /// interrupt: until the live blob is swapped the old items are left
  /// untouched and stay decryptable, and the marker is written only
  /// after the swap committed, so a crash at any point leaves either
  /// the intact legacy vault (the next unlock retries) or a complete v4
  /// vault whose marker the next call writes.
  Future<int> migrateItemsToCurrentVersion() => migrateItemsToItemKeyed();

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

    // A v4 item is sealed under a per-item key derived from the DEK with
    // this envelope's salt and item key version, so both travel to the
    // wire on their own fields (`item_key_salt` / `item_key_version`,
    // see `SyncItemPayloadCodec.itemKeyPayloadVersion`). An envelope
    // that claims v4 without them describes a key nobody can derive, so
    // it is not queued at all rather than queued broken.
    final isItemKeyed = version >= SyncItemPayloadCodec.itemKeyPayloadVersion;
    final itemKeySalt = isItemKeyed
        ? _readNonEmptyString(payload, 'salt')
        : null;
    final itemKeyVersion = isItemKeyed ? _readPositiveInt(payload, 'iv') : null;
    if (isItemKeyed &&
        (itemKeySalt == null ||
            !isBase64Value(itemKeySalt) ||
            itemKeyVersion == null)) {
      return null;
    }

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
        itemKeySalt: itemKeySalt,
        itemKeyVersion: itemKeyVersion,
      );
    }

    return _SyncBlobPayload(
      ciphertext: ciphertext,
      nonce: nonce,
      gcmTag: gcmTag,
      keyVersion: version,
    );
  }

  /// Reads a non-empty string field, treating any other shape as absent
  /// so a malformed envelope fails closed instead of shipping a value the
  /// receiver would derive a wrong key from.
  static String? _readNonEmptyString(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// Reads a positive integer field, treating any other shape as absent.
  static int? _readPositiveInt(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    return value is int && value > 0 ? value : null;
  }

  /// Applies a batch of remote snapshots to the local vault, fed by
  /// the pull sync path. Each snapshot is decrypted with the active
  /// session and the resulting vault is written back (always as the current
  /// payload version).
  /// Idempotent: applying the same snapshots twice yields the same
  /// vault.
  ///
  /// Snapshots that fail validation are skipped, never applied, and
  /// their record ids are returned so the sync layer can surface them:
  /// a v1/v2 payload once the vault is migrated (downgrade), a v3
  /// payload bound to another record id or key, an item-keyed (v4)
  /// payload that did not bring its item key salt and version, a
  /// decrypted item whose `id` differs from the bound record id, or a
  /// GCM authentication failure.
  @override
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
      final envelope = RemoteSnapshotEnvelope.fromSnapshot(
        snapshot: snapshot,
        session: session,
      );
      final encrypted = envelope.encrypted;
      if (encrypted == null) {
        if (envelope.isRejected) {
          rejected.add(localId);
        }
        continue;
      }
      try {
        final decrypted = await _decryptStoredItem(
          encrypted: encrypted,
          session: session,
          minimumVersion: minimumVersion,
          expectedRecordId: envelope.isRecordBound ? localId : null,
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

  Future<List<String>> _readEncryptedItems() async {
    final raw = await _storage.read(encryptedVaultItemsKey);
    if (raw == null || raw.isEmpty) {
      return const [];
    }
    return (jsonDecode(raw) as List<dynamic>).cast<String>();
  }

  /// Decrypts one stored envelope and enforces the record binding, through the
  /// shared checks in [decryptSnapshotItem] so the vault's own read paths and
  /// the pull path cannot disagree on what a payload bound elsewhere means.
  Future<_DecryptedItem> _decryptStoredItem({
    required String encrypted,
    required VaultSession session,
    required int minimumVersion,
    String? expectedRecordId,
  }) async {
    final decrypted = await decryptSnapshotItem(
      cryptoService: _cryptoService,
      encrypted: encrypted,
      session: session,
      minimumVersion: minimumVersion,
      expectedRecordId: expectedRecordId,
    );
    return _DecryptedItem(
      item: decrypted.item,
      plaintext: decrypted.plaintext,
      version: decrypted.payloadVersion,
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
    this.itemKeySalt,
    this.itemKeyVersion,
  });

  final String ciphertext;
  final String nonce;
  final String? gcmTag;
  final int keyVersion;

  /// Base64 salt of the per-item key, for an item-keyed (v4) payload.
  final String? itemKeySalt;

  /// Item key version bound into the v4 associated data.
  final int? itemKeyVersion;
}
