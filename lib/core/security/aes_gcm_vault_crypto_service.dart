import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'vault_session.dart';
import 'vault_crypto_service.dart';

/// AES-256-GCM implementation of [VaultCryptoService] for vault item
/// payloads. Decrypts the legacy v1 and v2 envelope shapes defined in
/// `docs/adr/0001-crypto-key-derivation-and-encrypted-blob.md`, decrypts v3, and always
/// encrypts v4, which gives every item its own key (see [itemKeyFor]).
class AesGcmVaultCryptoService implements VaultCryptoService {
  /// Optional [algorithm] override for tests. Production code should
  /// use the default 256-bit AES-GCM.
  AesGcmVaultCryptoService({AesGcm? algorithm, Random? random})
    : _algorithm = algorithm ?? AesGcm.with256bits(),
      _random = random ?? Random.secure();

  static const _version = 1;
  static const _version2 = 2;

  /// AES-256-GCM under the DEK, bound to record id and key id.
  static const payloadVersionV3 = 3;

  /// Current item payload version: its own key per item, derived from the
  /// DEK, bound to record id, key id and item key version.
  static const payloadVersionV4 = 4;

  /// Domain-separation prefix of the v3 associated data.
  static const aadDomain = 'vaulta:item:v3';

  /// Domain-separation prefix of the v4 associated data.
  static const aadDomainV4 = 'vaulta:item:v4';

  /// Item key version this build writes.
  static const currentItemKeyVersion = 1;

  /// Bytes of salt mixed into each item key derivation.
  static const _itemSaltBytes = 16;

  final AesGcm _algorithm;
  final Random _random;

  /// Canonical v3 associated data: the UTF-8 bytes of
  /// `"vaulta:item:v3|" + recordId + "|" + keyId`.
  ///
  /// The `|` separator is only unambiguous because neither field may
  /// contain it, so both are validated here and the call throws
  /// [ArgumentError] on an empty value or an embedded `|`.
  static List<int> itemAssociatedData({
    required String recordId,
    required String keyId,
  }) {
    _requireAadField(recordId, 'recordId');
    _requireAadField(keyId, 'keyId');
    return utf8.encode('$aadDomain|$recordId|$keyId');
  }

  /// Canonical v4 associated data: the UTF-8 bytes of
  /// `"vaulta:item:v4|" + recordId + "|" + keyId + "|" + itemKeyVersion`.
  ///
  /// The item key version is bound here, not only stored, so an attacker
  /// holding the DEK cannot rewrite an item from one key version to
  /// another to keep replaying an old plaintext under a new label.
  static List<int> itemAssociatedDataV4({
    required String recordId,
    required String keyId,
    required int itemKeyVersion,
  }) {
    _requireAadField(recordId, 'recordId');
    _requireAadField(keyId, 'keyId');
    if (itemKeyVersion < 1) {
      throw ArgumentError.value(
        itemKeyVersion,
        'itemKeyVersion',
        'must be >= 1',
      );
    }
    return utf8.encode('$aadDomainV4|$recordId|$keyId|$itemKeyVersion');
  }

  /// Derives the per-item key from the DEK.
  ///
  /// HKDF-SHA256 over a fresh 16-byte salt per item version, with the
  /// same context string the AAD uses. Two items therefore never share a
  /// key, and compromising one item's key does not expose any other item
  /// or the DEK.
  ///
  /// The salt is not secret: it is stored in the payload so the item can
  /// be reopened. Its purpose is domain separation across item versions,
  /// not entropy.
  static Future<SecretKey> itemKeyFor({
    required SecretKey dek,
    required List<int> salt,
    required String recordId,
    required String keyId,
    required int itemKeyVersion,
  }) async {
    _requireAadField(recordId, 'recordId');
    _requireAadField(keyId, 'keyId');
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: dek,
      nonce: salt,
      info: utf8.encode(
        '$aadDomainV4|$recordId|$keyId|$itemKeyVersion',
      ),
    );
  }

  @override
  VaultItemPayloadHeader inspect(String ciphertext) {
    final payload = _decodeEnvelope(ciphertext);
    final version = payload['v'] ?? payload['version'];
    if (version is! int) {
      throw VaultPayloadRejectedError(
        VaultPayloadRejection.malformed,
        'Vault payload has no version.',
      );
    }
    final keyId = payload['keyId'];
    final recordId = payload['rid'];
    final itemKeyVersion = payload['iv'];
    return VaultItemPayloadHeader(
      version: version,
      keyId: keyId is String ? keyId : null,
      recordId: version >= payloadVersionV3 && recordId is String
          ? recordId
          : null,
      itemKeyVersion: version >= payloadVersionV4 &&
              itemKeyVersion is int
          ? itemKeyVersion
          : null,
    );
  }

  @override
  Future<String> decrypt({
    required String ciphertext,
    required Object secretKey,
    required String expectedKeyId,
    required String? recordId,
    int minimumVersion = _version,
  }) async {
    final itemKey = _readItemKey(secretKey);

    final payload = _decodeEnvelope(ciphertext);
    final version = (payload['v'] ?? payload['version']) as int?;
    final keyId = payload['keyId'] as String?;

    if (version == null ||
        (version != _version &&
            version != _version2 &&
            version != payloadVersionV3 &&
            version != payloadVersionV4)) {
      throw VaultPayloadRejectedError(
        VaultPayloadRejection.unsupportedVersion,
        'Unsupported vault payload version: $version',
      );
    }

    if (version < minimumVersion) {
      throw VaultPayloadRejectedError(
        VaultPayloadRejection.downgrade,
        'Vault payload v$version is below the vault minimum v$minimumVersion.',
      );
    }

    if (keyId != expectedKeyId) {
      throw VaultPayloadRejectedError(
        VaultPayloadRejection.keyMismatch,
        'Vault payload key mismatch. Rekeying is required.',
      );
    }

    if (version == payloadVersionV4) {
      return _decryptV4(
        payload: payload,
        dek: itemKey,
        keyId: expectedKeyId,
        recordId: recordId,
      );
    }

    if (version == payloadVersionV3) {
      final boundRecordId = payload['rid'];
      if (recordId == null || boundRecordId != recordId) {
        throw VaultPayloadRejectedError(
          VaultPayloadRejection.recordMismatch,
          'Vault payload is bound to a different record.',
        );
      }
      final secretBox = _secretBoxFromPayload(
        payload['payload'] as Map<String, dynamic>,
      );
      final clearBytes = await _algorithm.decrypt(
        secretBox,
        secretKey: itemKey,
        aad: itemAssociatedData(recordId: recordId, keyId: expectedKeyId),
      );
      return utf8.decode(clearBytes);
    }

    final encryptedPayload = version == _version2
        ? payload['payload'] as Map<String, dynamic>
        : payload;
    final secretBox = _secretBoxFromPayload(encryptedPayload);

    final clearBytes = await _algorithm.decrypt(secretBox, secretKey: itemKey);
    return utf8.decode(clearBytes);
  }

  /// Decrypts a v4 payload: re-derives the per-item key from the DEK and
  /// seals with the version-bound AAD.
  ///
  /// The salt and item key version are read from the payload, not
  /// assumed, so a payload written under an older item key version keeps
  /// decrypting after the DEK rotates.
  Future<String> _decryptV4({
    required Map<String, dynamic> payload,
    required SecretKey dek,
    required String keyId,
    required String? recordId,
  }) async {
    final boundRecordId = payload['rid'];
    if (recordId == null || boundRecordId != recordId) {
      throw VaultPayloadRejectedError(
        VaultPayloadRejection.recordMismatch,
        'Vault payload is bound to a different record.',
      );
    }

    final itemKeyVersion = payload['iv'];
    if (itemKeyVersion is! int || itemKeyVersion < 1) {
      throw VaultPayloadRejectedError(
        VaultPayloadRejection.malformed,
        'Vault payload has no usable item key version.',
      );
    }

    final salt = payload['salt'];
    if (salt is! String) {
      throw VaultPayloadRejectedError(
        VaultPayloadRejection.malformed,
        'Vault payload has no item key salt.',
      );
    }

    final itemKey = await itemKeyFor(
      dek: dek,
      salt: base64Decode(salt),
      recordId: recordId,
      keyId: keyId,
      itemKeyVersion: itemKeyVersion,
    );

    final secretBox = _secretBoxFromPayload(
      payload['payload'] as Map<String, dynamic>,
    );
    final clearBytes = await _algorithm.decrypt(
      secretBox,
      secretKey: itemKey,
      aad: itemAssociatedDataV4(
        recordId: recordId,
        keyId: keyId,
        itemKeyVersion: itemKeyVersion,
      ),
    );
    return utf8.decode(clearBytes);
  }

  @override
  Future<String> encrypt({
    required String plaintext,
    required Object secretKey,
    required String keyId,
    required String recordId,
  }) async {
    final dek = _readItemKey(secretKey);
    const itemKeyVersion = currentItemKeyVersion;
    final salt = _randomSalt(_itemSaltBytes);

    final itemKey = await itemKeyFor(
      dek: dek,
      salt: salt,
      recordId: recordId,
      keyId: keyId,
      itemKeyVersion: itemKeyVersion,
    );

    final secretBox = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: itemKey,
      aad: itemAssociatedDataV4(
        recordId: recordId,
        keyId: keyId,
        itemKeyVersion: itemKeyVersion,
      ),
    );

    return jsonEncode({
      'v': payloadVersionV4,
      'keyId': keyId,
      'rid': recordId,
      'iv': itemKeyVersion,
      'salt': base64Encode(salt),
      if (secretKey is VaultSession && secretKey.isV2) ...{
        'kdf': secretKey.kdf,
        'dek_wrap': secretKey.dekWrap,
      },
      'payload': _payloadFromSecretBox(secretBox),
    });
  }

  /// Produces a v3 payload (sealed under the DEK) exactly as builds
  /// before v4 wrote them. Exists so tests can build pre-migration
  /// fixtures; production code always writes v4 through [encrypt].
  @visibleForTesting
  Future<String> encryptV3ForTesting({
    required String plaintext,
    required Object secretKey,
    required String keyId,
    required String recordId,
  }) async {
    final dek = _readItemKey(secretKey);
    final secretBox = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: dek,
      aad: itemAssociatedData(recordId: recordId, keyId: keyId),
    );

    return jsonEncode({
      'v': payloadVersionV3,
      'keyId': keyId,
      'rid': recordId,
      if (secretKey is VaultSession && secretKey.isV2) ...{
        'kdf': secretKey.kdf,
        'dek_wrap': secretKey.dekWrap,
      },
      'payload': _payloadFromSecretBox(secretBox),
    });
  }

  List<int> _randomSalt(int length) =>
      List<int>.generate(length, (_) => _random.nextInt(256));

  /// Produces a legacy v1 (raw [SecretKey] or v1 session) or v2 (v2
  /// [VaultSession]) payload with no associated data, exactly as builds
  /// before v3 wrote them. Exists only so tests can build pre-migration
  /// fixtures; production code always writes v3 through [encrypt].
  @visibleForTesting
  Future<String> encryptLegacyForTesting({
    required String plaintext,
    required Object secretKey,
    required String keyId,
  }) async {
    final itemKey = _readItemKey(secretKey);

    final secretBox = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: itemKey,
    );

    if (secretKey is VaultSession && secretKey.isV2) {
      return jsonEncode({
        'v': _version2,
        'keyId': keyId,
        'kdf': secretKey.kdf,
        'dek_wrap': secretKey.dekWrap,
        'payload': _payloadFromSecretBox(secretBox),
      });
    }

    return jsonEncode({
      'version': _version,
      'algorithm': 'aes-256-gcm',
      'keyId': keyId,
      'nonce': base64Encode(secretBox.nonce),
      'ciphertext': base64Encode(secretBox.cipherText),
      'mac': base64Encode(secretBox.mac.bytes),
    });
  }

  static void _requireAadField(String value, String name) {
    if (value.isEmpty || value.contains('|')) {
      throw ArgumentError.value(
        value,
        name,
        'must be non-empty and must not contain "|"',
      );
    }
  }

  Map<String, dynamic> _decodeEnvelope(String ciphertext) {
    try {
      final decoded = jsonDecode(ciphertext);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on FormatException {
      // Fall through to the structured rejection below.
    }
    throw VaultPayloadRejectedError(
      VaultPayloadRejection.malformed,
      'Vault payload is not a JSON envelope.',
    );
  }

  SecretKey _readItemKey(Object value) {
    if (value is VaultSession) {
      return value.secretKey;
    }
    if (value is SecretKey) {
      return value;
    }
    throw ArgumentError.value(
      value,
      'secretKey',
      'Expected SecretKey or VaultSession.',
    );
  }

  Map<String, dynamic> _payloadFromSecretBox(SecretBox box) {
    return {
      'alg': 'AES-256-GCM',
      'nonce_b64': base64Encode(box.nonce),
      'ciphertext_b64': base64Encode(box.cipherText),
      'tag_b64': base64Encode(box.mac.bytes),
    };
  }

  SecretBox _secretBoxFromPayload(Map<String, dynamic> payload) {
    final ciphertext = payload['ciphertext_b64'] ?? payload['ciphertext'];
    final nonce = payload['nonce_b64'] ?? payload['nonce'];
    final tag = payload['tag_b64'] ?? payload['mac'];
    return SecretBox(
      base64Decode(ciphertext as String),
      nonce: base64Decode(nonce as String),
      mac: Mac(base64Decode(tag as String)),
    );
  }
}
