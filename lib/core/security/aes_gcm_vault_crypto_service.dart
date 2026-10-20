import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'vault_session.dart';
import 'vault_crypto_service.dart';

/// AES-256-GCM implementation of [VaultCryptoService] for vault item
/// payloads. Decrypts the legacy v1 and v2 envelope shapes defined in
/// `docs/architecture/ADR-001-crypto.md` and always encrypts v3, which
/// binds each ciphertext to its record id and key id through GCM
/// associated data (see [itemAssociatedData]).
class AesGcmVaultCryptoService implements VaultCryptoService {
  /// Optional [algorithm] override for tests. Production code should
  /// use the default 256-bit AES-GCM.
  AesGcmVaultCryptoService({AesGcm? algorithm})
    : _algorithm = algorithm ?? AesGcm.with256bits();

  static const _version = 1;
  static const _version2 = 2;

  /// Current item payload version: AES-256-GCM with record-bound AAD.
  static const payloadVersionV3 = 3;

  /// Domain-separation prefix of the v3 associated data.
  static const aadDomain = 'vaulta:item:v3';

  final AesGcm _algorithm;

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
    return VaultItemPayloadHeader(
      version: version,
      keyId: keyId is String ? keyId : null,
      recordId: version >= payloadVersionV3 && recordId is String
          ? recordId
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
            version != payloadVersionV3)) {
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

  @override
  Future<String> encrypt({
    required String plaintext,
    required Object secretKey,
    required String keyId,
    required String recordId,
  }) async {
    final itemKey = _readItemKey(secretKey);
    final aad = itemAssociatedData(recordId: recordId, keyId: keyId);

    final secretBox = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: itemKey,
      aad: aad,
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
