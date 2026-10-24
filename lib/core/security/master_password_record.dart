import 'dart:convert';

/// Persisted record describing how the master password protects a
/// vault. Stored encrypted at rest via [SecureStorageService] (which
/// goes through Android Keystore / Windows Credential Manager / etc).
///
/// v1 records only carry the verifier triple (verifier + salt +
/// iterations) used to check the master password without keeping the
/// derived key. v2 records add the KDF and DEK wrap so the biometric
/// unlock path can recover the DEK without re-prompting the master
/// password. v3 records derive a single 64-byte master key with one
/// Argon2id run and split it with HKDF-SHA256 into the verifier and the
/// KEK, and mark the password as NFC-normalized (see [pwNorm]).
class MasterPasswordRecord {
  /// Builds a [MasterPasswordRecord]. [kdf] and [dekWrap] are required
  /// for v2 and v3 records; leave both null for legacy v1 records.
  const MasterPasswordRecord({
    required this.version,
    required this.verifierIterations,
    required this.verifierSalt,
    required this.verifier,
    required this.encryptionIterations,
    required this.encryptionSalt,
    required this.keyId,
    required this.createdAt,
    this.kdf,
    this.dekWrap,
    this.pwNorm,
  });

  /// Record version (1 = legacy, 2 = DEK wrap, 3 = single-KDF HKDF split).
  final int version;

  /// Normalization applied to the master password before the KDF.
  ///
  /// `'NFC'` on v3 records. `null` on v1/v2 records, which hashed the raw
  /// input: the distinction is load-bearing, because NFC changes the byte
  /// sequence of a decomposed password and verifying a legacy record
  /// against normalized bytes would lock its owner out.
  final String? pwNorm;

  /// Argon2id iterations used to derive the verifier key from the
  /// master password.
  final int verifierIterations;

  /// Salt for the verifier derivation (random per user).
  final String verifierSalt;

  /// Base64 hash of (verifier_salt + master_password) under the
  /// verifier KDF. Checked at unlock time before deriving the
  /// encryption key.
  final String verifier;

  /// Argon2id iterations used to derive the encryption key. May
  /// differ from [verifierIterations] in older records (was the
  /// case in v1, fixed in v2).
  final int encryptionIterations;

  /// Salt for the encryption key derivation.
  final String encryptionSalt;

  /// Identifier of the current vault key, used by the crypto service
  /// to detect rekeying.
  final String keyId;

  /// When this record was first created. Used to decide when the
  /// parameters are old enough to warrant a migration.
  final DateTime createdAt;

  /// KDF parameters for the DEK wrap. Present only on v2 records.
  final Map<String, dynamic>? kdf;

  /// Wrapped DEK envelope. Present only on v2 records.
  final Map<String, dynamic>? dekWrap;

  /// Serializes the record to a plain `Map<String, dynamic>` for
  /// storage. v2-only fields are included only when present.
  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'verifierIterations': verifierIterations,
      'verifierSalt': verifierSalt,
      'verifier': verifier,
      'encryptionIterations': encryptionIterations,
      'encryptionSalt': encryptionSalt,
      'keyId': keyId,
      'createdAt': createdAt.toIso8601String(),
      if (kdf != null) 'kdf': kdf,
      if (dekWrap != null) 'dek_wrap': dekWrap,
      if (pwNorm != null) 'pw_norm': pwNorm,
    };
  }

  /// Inverse of [toJson]. Accepts both the current `verifierSalt`/
  /// `encryptionSalt` field names and the legacy `salt`/`iterations`
  /// pair for backward compatibility with pre-v2 persisted data.
  factory MasterPasswordRecord.fromJson(Map<String, dynamic> json) {
    final verifierIterations =
        (json['verifierIterations'] ?? json['iterations']) as int;
    final verifierSalt = (json['verifierSalt'] ?? json['salt']) as String;
    final encryptionIterations =
        (json['encryptionIterations'] ?? verifierIterations) as int;
    final encryptionSalt = (json['encryptionSalt'] ?? verifierSalt) as String;

    return MasterPasswordRecord(
      version: json['version'] as int,
      verifierIterations: verifierIterations,
      verifierSalt: verifierSalt,
      verifier: json['verifier'] as String,
      encryptionIterations: encryptionIterations,
      encryptionSalt: encryptionSalt,
      keyId: (json['keyId'] ?? 'legacy-master-password') as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      kdf: (json['kdf'] as Map?)?.cast<String, dynamic>(),
      dekWrap: (json['dek_wrap'] as Map?)?.cast<String, dynamic>(),
      pwNorm: json['pw_norm'] as String?,
    );
  }

  /// True when this record's derivation matches the current scheme.
  ///
  /// Current is: version 3, an HKDF split, and NFC-normalized input. A
  /// record missing any of those is migrated on the next successful
  /// unlock rather than in place, so a failed migration cannot damage a
  /// working vault.
  bool get isCurrentFormat => version == currentVersion && pwNorm == nfcMarker;

  /// The only record version this build writes.
  static const int currentVersion = 3;

  /// Value stored in [pwNorm] for records whose password is NFC-normalized
  /// before the KDF.
  static const String nfcMarker = 'NFC';

  /// Convenience: [toJson] then JSON-encode.
  String encode() => jsonEncode(toJson());

  /// Convenience: [decode] from a JSON string. Inverse of [encode].
  factory MasterPasswordRecord.decode(String source) {
    return MasterPasswordRecord.fromJson(
      jsonDecode(source) as Map<String, dynamic>,
    );
  }
}
