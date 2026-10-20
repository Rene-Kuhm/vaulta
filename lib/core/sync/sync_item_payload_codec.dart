import 'dart:convert';

/// Wire codec for the `ciphertext` field of record-bound (v3) sync
/// payloads.
///
/// A v3 item ciphertext is authenticated together with its record id
/// (see `AesGcmVaultCryptoService.itemAssociatedData`), so a receiving
/// device must know that id *before* it can decrypt. The backend row is
/// keyed by a remote UUID that, for non-UUID local ids, is a one-way
/// derivation of `userId + localRecordId`
/// (`BidirectionalSyncService._remoteRecordIdFor`), so the receiver
/// cannot recover the local id from the row alone. The bound record id
/// therefore travels next to the ciphertext, inside the opaque
/// `ciphertext` column the backend already stores verbatim:
///
/// ```text
/// <base64url-no-padding(utf8(recordId))> "." <base64(ciphertext)>
/// ```
///
/// Neither base64 alphabet contains `.`, so the split is unambiguous.
/// The record id is not secret (it is GCM-authenticated, not
/// encrypted). The receiver must still check that the decoded id maps
/// to the row it arrived under; the sync service does that before the
/// payload reaches the vault.
abstract final class SyncItemPayloadCodec {
  /// First `key_version` value whose `ciphertext` uses this codec.
  static const boundPayloadVersion = 3;

  /// Packs [recordId] and the base64 [ciphertextB64] into the wire
  /// `ciphertext` value.
  static String encode({
    required String recordId,
    required String ciphertextB64,
  }) {
    final encodedId = base64Url
        .encode(utf8.encode(recordId))
        .replaceAll('=', '');
    return '$encodedId.$ciphertextB64';
  }

  /// Unpacks a wire `ciphertext` value. Returns `null` when [wire] is
  /// not a well-formed bound payload; callers must treat that as an
  /// invalid payload, never fall back to legacy decoding.
  static ({String recordId, String ciphertextB64})? decode(String? wire) {
    if (wire == null) {
      return null;
    }
    final separator = wire.indexOf('.');
    if (separator <= 0 || separator == wire.length - 1) {
      return null;
    }
    final encodedId = wire.substring(0, separator);
    final ciphertextB64 = wire.substring(separator + 1);
    try {
      final recordId = utf8.decode(
        base64Url.decode(base64Url.normalize(encodedId)),
      );
      if (recordId.isEmpty) {
        return null;
      }
      return (recordId: recordId, ciphertextB64: ciphertextB64);
    } on FormatException {
      return null;
    }
  }
}
