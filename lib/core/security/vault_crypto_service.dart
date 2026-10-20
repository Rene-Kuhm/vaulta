/// Encrypts and decrypts individual vault item payloads using a
/// per-item key (either a [VaultSession] or a raw [SecretKey]). The
/// returned ciphertext is a self-describing JSON envelope (version +
/// algorithm + nonce + tag + keyId) so the format can evolve without
/// breaking older payloads.
///
/// Since payload v3 every new ciphertext is bound to the identity of
/// the record it belongs to: AES-GCM authenticates the associated data
/// `"vaulta:item:v3|" + recordId + "|" + keyId`, so a ciphertext moved
/// to another record id, or replayed under another key generation,
/// fails authentication. See `docs/architecture/ADR-001-crypto.md`.
abstract interface class VaultCryptoService {
  /// Encrypts [plaintext] with [secretKey] as a v3 payload bound to
  /// [recordId] and [keyId] (the vault's current key identifier, used
  /// at decrypt time to detect rekeying). Both identifiers go into the
  /// GCM associated data; neither may be empty or contain `|`.
  Future<String> encrypt({
    required String plaintext,
    required Object secretKey,
    required String keyId,
    required String recordId,
  });

  /// Decrypts [ciphertext] with [secretKey], asserting that the
  /// embedded keyId matches [expectedKeyId]. A mismatch throws because
  /// it means the vault was rekeyed and the stored payload needs to be
  /// re-encrypted with the current key.
  ///
  /// For v3 payloads [recordId] is mandatory: it must equal the record
  /// id carried by the envelope and is fed into the GCM associated
  /// data. Legacy v1/v2 payloads carry no associated data; [recordId]
  /// may be `null` for them. Payloads whose version is below
  /// [minimumVersion] are rejected without being decrypted (downgrade
  /// defense once a vault has migrated to v3).
  Future<String> decrypt({
    required String ciphertext,
    required Object secretKey,
    required String expectedKeyId,
    required String? recordId,
    int minimumVersion,
  });

  /// Reads the clear-text header of [ciphertext] (version, keyId and,
  /// for v3, the bound record id) without touching key material.
  /// Throws [VaultPayloadRejectedError] when the envelope is malformed.
  VaultItemPayloadHeader inspect(String ciphertext);
}

/// Clear-text metadata of an encrypted item envelope, as returned by
/// [VaultCryptoService.inspect]. Nothing here is secret: the record id
/// and key id are authenticated (v3) but not confidential.
class VaultItemPayloadHeader {
  /// Builds a header. [recordId] is `null` for legacy v1/v2 payloads.
  const VaultItemPayloadHeader({
    required this.version,
    required this.keyId,
    this.recordId,
  });

  /// Payload format version (1, 2 or 3).
  final int version;

  /// Key identifier the payload claims to be encrypted under.
  final String? keyId;

  /// Record id bound into the GCM associated data (v3 only).
  final String? recordId;
}

/// Why an item payload was refused before or after decryption.
enum VaultPayloadRejection {
  /// The envelope is not valid JSON or misses required fields.
  malformed,

  /// The envelope declares a version this build cannot decrypt.
  unsupportedVersion,

  /// The envelope version is older than the vault's persisted minimum
  /// (a v1/v2 payload offered to a vault already migrated to v3).
  downgrade,

  /// The embedded keyId does not match the active session key.
  keyMismatch,

  /// The record id bound to the payload (or the decrypted item id)
  /// does not match the record the caller expected.
  recordMismatch,
}

/// Error thrown when an item payload is refused. Extends [StateError]
/// so existing callers that treat a bad payload as a state error keep
/// working. The [message] never contains plaintext or key material.
final class VaultPayloadRejectedError extends StateError {
  /// Builds the error for [reason] with a non-secret [message].
  VaultPayloadRejectedError(this.reason, super.message);

  /// Machine-readable rejection reason.
  final VaultPayloadRejection reason;
}
