/// Reconstruction of a pulled remote snapshot into the stored-envelope form.
///
/// Sync delivers a snapshot as separate wire fields (`ciphertext`, `nonce`,
/// `gcmTag`, `itemKeySalt`, `itemKeyVersion`), while the vault decrypts a
/// self-describing envelope. This module is the single place that turns one
/// into the other, plus the binding checks that decide whether the payload may
/// be opened at all, so no two storages can drift apart on what "a valid pulled
/// snapshot" means.
library;

import 'dart:convert';

import '../../features/vault/domain/vault_item.dart';
import '../security/vault_crypto_service.dart';
import '../security/vault_session.dart';
import 'remote_vault_blob_change.dart';
import 'sync_item_payload_codec.dart';

/// Result of rebuilding one [RemoteVaultBlobSnapshot] into a stored envelope.
///
/// A snapshot can be refused without being a rejection: a legacy v1/v2 payload
/// carries no record binding, so a vault that already moved past it skips the
/// snapshot (the documented downgrade path). A refused payload that *does*
/// claim a bound version is a real rejection and its record id has to be
/// reported back to sync.
class RemoteSnapshotEnvelope {
  const RemoteSnapshotEnvelope._({
    required this.isRecordBound,
    required this.encrypted,
  });

  /// Rebuilds the stored envelope described by [snapshot] under [session].
  ///
  /// Four shapes exist, and each is refused when it did not bring what its
  /// version requires:
  /// - v1 legacy: `nonce` + `ciphertext`, no binding;
  /// - v2 with the session's `kdf` / `dek_wrap`;
  /// - v3 record-bound: `ciphertext` decoded through
  ///   [SyncItemPayloadCodec], which carries the bound record id;
  /// - v4 item-keyed: the v3 shape plus a base64 `itemKeySalt` and a non-null
  ///   `itemKeyVersion`, without which nobody can derive the item key.
  factory RemoteSnapshotEnvelope.fromSnapshot({
    required RemoteVaultBlobSnapshot snapshot,
    required VaultSession session,
  }) {
    final isRecordBound =
        snapshot.keyVersion >= SyncItemPayloadCodec.boundPayloadVersion;
    RemoteSnapshotEnvelope refuse() =>
        RemoteSnapshotEnvelope._(isRecordBound: isRecordBound, encrypted: null);
    RemoteSnapshotEnvelope accept(String encrypted) =>
        RemoteSnapshotEnvelope._(
          isRecordBound: isRecordBound,
          encrypted: encrypted,
        );

    final ciphertext = snapshot.ciphertext;
    final nonce = snapshot.nonce;
    if (ciphertext == null ||
        ciphertext.isEmpty ||
        nonce == null ||
        nonce.isEmpty) {
      return refuse();
    }
    if (isRecordBound) {
      final bound = SyncItemPayloadCodec.decode(ciphertext);
      if (bound == null) {
        return refuse();
      }
      if (snapshot.keyVersion >= SyncItemPayloadCodec.itemKeyPayloadVersion) {
        // Same rule as the write path: an item-keyed payload that did not
        // bring its salt and item key version cannot be reopened here,
        // so it is refused instead of decrypted into a wrong key.
        final salt = snapshot.itemKeySalt;
        final itemKeyVersion = snapshot.itemKeyVersion;
        if (salt == null || salt.isEmpty || itemKeyVersion == null) {
          return refuse();
        }
        if (!isBase64Value(salt)) {
          return refuse();
        }
        return accept(
          jsonEncode({
            'v': snapshot.keyVersion,
            'keyId': session.keyId,
            'rid': bound.recordId,
            'iv': itemKeyVersion,
            'salt': salt,
            'payload': {
              'alg': 'AES-256-GCM',
              'nonce_b64': nonce,
              'ciphertext_b64': bound.ciphertextB64,
              'tag_b64': snapshot.gcmTag ?? '',
            },
          }),
        );
      }
      return accept(
        jsonEncode({
          'v': snapshot.keyVersion,
          'keyId': session.keyId,
          'rid': bound.recordId,
          'payload': {
            'alg': 'AES-256-GCM',
            'nonce_b64': nonce,
            'ciphertext_b64': bound.ciphertextB64,
            'tag_b64': snapshot.gcmTag ?? '',
          },
        }),
      );
    }
    if (snapshot.keyVersion == 2 && session.isV2) {
      return accept(
        jsonEncode({
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
        }),
      );
    }
    return accept(
      jsonEncode({
        'version': 1,
        'algorithm': 'aes-256-gcm',
        'keyId': session.keyId,
        'nonce': nonce,
        'ciphertext': ciphertext,
        'mac': snapshot.gcmTag ?? '',
      }),
    );
  }

  /// The stored envelope JSON, or `null` when the snapshot was refused.
  final String? encrypted;

  /// Whether the snapshot claims a record-bound payload version (v3 or up).
  final bool isRecordBound;

  /// True when nothing can be decrypted, so the snapshot must be skipped.
  bool get isRefused => encrypted == null;

  /// True when a refusal also has to be reported to sync as a rejected
  /// record id.
  bool get isRejected => isRefused && isRecordBound;
}

/// One pulled payload after decryption, with the metadata the caller needs to
/// rewrite it bound to its record.
class DecryptedSnapshotItem {
  /// Builds the result.
  const DecryptedSnapshotItem({
    required this.item,
    required this.plaintext,
    required this.payloadVersion,
  });

  /// The decrypted item.
  final VaultItem item;

  /// The exact plaintext, so a caller can re-encrypt without re-serializing.
  final String plaintext;

  /// Envelope version the payload declared.
  final int payloadVersion;
}

/// Decrypts one stored envelope and enforces the record binding.
///
/// For a bound payload (v3+) the record id comes from the envelope (and must
/// equal [expectedRecordId] when the caller knows it); GCM authenticates it,
/// and the decrypted item's `id` must equal it. Legacy payloads carry no
/// binding, so the id check only runs when the caller passes
/// [expectedRecordId].
///
/// Throws [VaultPayloadRejectedError] when the envelope is malformed or bound
/// elsewhere, and lets the crypto service's authentication failure through, so
/// every caller can report the same record id as rejected.
Future<DecryptedSnapshotItem> decryptSnapshotItem({
  required VaultCryptoService cryptoService,
  required String encrypted,
  required VaultSession session,
  required int minimumVersion,
  String? expectedRecordId,
}) async {
  final header = cryptoService.inspect(encrypted);
  final isBound = header.version >= SyncItemPayloadCodec.boundPayloadVersion;
  final recordId = isBound ? header.recordId : null;
  if (isBound &&
      (recordId == null ||
          (expectedRecordId != null && recordId != expectedRecordId))) {
    throw VaultPayloadRejectedError(
      VaultPayloadRejection.recordMismatch,
      'Vault payload is bound to a different record.',
    );
  }
  final plaintext = await cryptoService.decrypt(
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
  return DecryptedSnapshotItem(
    item: item,
    plaintext: plaintext,
    payloadVersion: header.version,
  );
}

/// True when [value] decodes as base64. An item key salt that does not would
/// make the receiving device throw while it derives the item key, aborting a
/// whole pull batch instead of refusing one payload, so the value is checked
/// before it is queued and before it is used.
bool isBase64Value(String value) {
  try {
    base64Decode(value);
    return true;
  } on FormatException {
    return false;
  }
}
