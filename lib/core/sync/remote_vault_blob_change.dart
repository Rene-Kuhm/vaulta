import 'sync_item_payload_codec.dart';

/// One row of the remote change feed. Combines the
/// `vault_ops.id` cursor with the current `vault_blobs` row, so the
/// pull path can advance its cursor and apply the change in a
/// single pass.
class RemoteVaultBlobChange {
  /// Builds a [RemoteVaultBlobChange] from the already-decoded
  /// fields. All payload fields (ciphertext, nonce, gcmTag,
  /// deletedAt) default to null so callers can build tombstones
  /// without supplying encryption material.
  const RemoteVaultBlobChange({
    required this.opCursor,
    required this.recordId,
    required this.version,
    required this.keyVersion,
    required this.updatedAt,
    this.ciphertext,
    this.nonce,
    this.gcmTag,
    this.itemKeySalt,
    this.itemKeyVersion,
    this.deletedAt,
  });

  /// Monotonic op id from `vault_ops.id`. The pull path advances
  /// its cursor to this value after applying the change.
  final int opCursor;

  /// Remote record id (stable across upserts; the local side
  /// maps it to a local id via the record-id mapping table).
  final String recordId;

  /// Vault record version. Strictly monotonic per record; CAS
  /// checks against this value.
  final int version;

  /// Item payload format version (backend `key_version` column).
  /// Version 3 marks a record-bound payload whose [ciphertext] uses
  /// the `SyncItemPayloadCodec` wire form; a vault migrated to v3
  /// refuses anything lower. Version 4 marks a payload sealed under its
  /// own item key, which additionally needs [itemKeySalt] and
  /// [itemKeyVersion].
  final int keyVersion;

  /// Base64 ciphertext. Null for tombstones.
  final String? ciphertext;

  /// Base64 nonce. Null for tombstones.
  final String? nonce;

  /// Base64 GCM auth tag. Null for tombstones.
  final String? gcmTag;

  /// Base64 salt of the per-item key, from the backend
  /// `item_key_salt` column. Null unless [keyVersion] is at least
  /// `SyncItemPayloadCodec.itemKeyPayloadVersion`: a payload sealed
  /// under the DEK has no item key, and neither has a tombstone.
  final String? itemKeySalt;

  /// Item key version from the backend `item_key_version` column, under
  /// the same gate as [itemKeySalt].
  final int? itemKeyVersion;

  /// When the record was tombstoned. Non-null marks the change as
  /// a delete.
  final DateTime? deletedAt;

  /// When the record was last modified on the backend.
  final DateTime updatedAt;

  /// True when this change is a delete (tombstone).
  bool get isTombstone => deletedAt != null;

  /// Builds a [RemoteVaultBlobChange] from the two Supabase rows
  /// the pull query returned (the `vault_ops` row carries the
  /// cursor, the `vault_blobs` row carries the payload).
  factory RemoteVaultBlobChange.fromSupabaseRows({
    required Map<String, dynamic> opRow,
    required Map<String, dynamic> blobRow,
  }) {
    final opCursor = _readRequiredInt(opRow, 'id');
    final recordId = _readRequiredString(blobRow, 'record_id');

    final deletedRaw = blobRow['deleted_at'];
    final deletedAt = deletedRaw == null
        ? null
        : DateTime.parse(deletedRaw as String).toUtc();

    final updatedRaw = blobRow['updated_at'];
    final updatedAt = updatedRaw == null
        ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
        : DateTime.parse(updatedRaw as String).toUtc();

    final keyVersion = _readRequiredInt(blobRow, 'key_version');
    final isItemKeyed =
        keyVersion >= SyncItemPayloadCodec.itemKeyPayloadVersion &&
        deletedAt == null;

    return RemoteVaultBlobChange(
      opCursor: opCursor,
      recordId: recordId,
      version: _readRequiredInt(blobRow, 'version'),
      keyVersion: keyVersion,
      ciphertext: deletedAt == null ? blobRow['ciphertext'] as String? : null,
      nonce: deletedAt == null ? blobRow['nonce'] as String? : null,
      gcmTag: deletedAt == null ? _readNullableGcmTag(blobRow) : null,
      // Read only for an item-keyed payload. A client older than this
      // one cannot clear these columns when it rewrites the row down to
      // an older payload, so a stale salt can survive there; it describes
      // no key that row has and must not be reported as one.
      itemKeySalt: isItemKeyed ? _readNullableSalt(blobRow) : null,
      itemKeyVersion: isItemKeyed ? _readNullableItemKeyVersion(blobRow) : null,
      deletedAt: deletedAt,
      updatedAt: updatedAt,
    );
  }

  /// Serializes the change for local persistence (used by the
  /// staging blob during rekey, never sent to the backend).
  Map<String, dynamic> toJson() {
    return {
      'opCursor': opCursor,
      'recordId': recordId,
      'version': version,
      'keyVersion': keyVersion,
      'ciphertext': ciphertext,
      'nonce': nonce,
      'gcmTag': gcmTag,
      'itemKeySalt': itemKeySalt,
      'itemKeyVersion': itemKeyVersion,
      'deletedAt': deletedAt?.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  /// Inverse of [toJson].
  factory RemoteVaultBlobChange.fromJson(Map<String, dynamic> json) {
    return RemoteVaultBlobChange(
      opCursor: json['opCursor'] as int,
      recordId: json['recordId'] as String,
      version: json['version'] as int,
      keyVersion: json['keyVersion'] as int,
      ciphertext: json['ciphertext'] as String?,
      nonce: json['nonce'] as String?,
      gcmTag: _readNullableGcmTag(json),
      itemKeySalt: json['itemKeySalt'] as String?,
      itemKeyVersion: _readNullableItemKeyVersion(json),
      deletedAt: json['deletedAt'] == null
          ? null
          : DateTime.parse(json['deletedAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
    );
  }

  static int _readRequiredInt(Map<String, dynamic> row, String key) {
    final value = row[key];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    throw FormatException('Missing numeric field: $key');
  }

  static String _readRequiredString(Map<String, dynamic> row, String key) {
    final value = row[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw FormatException('Missing string field: $key');
  }

  static String? _readNullableGcmTag(Map<String, dynamic> row) {
    final value = row['gcmTag'] ?? row['gcm_tag'] ?? row['aad'];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// Reads the base64 item key salt under either the backend column
  /// name (`item_key_salt`) or the persisted local name (`itemKeySalt`).
  static String? _readNullableSalt(Map<String, dynamic> row) {
    final value = row['itemKeySalt'] ?? row['item_key_salt'];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// Reads the item key version under either name. A value that is not
  /// a positive integer reads as `null` so a malformed row fails closed
  /// downstream instead of deriving a key under version 0.
  static int? _readNullableItemKeyVersion(Map<String, dynamic> row) {
    final value = row['itemKeyVersion'] ?? row['item_key_version'];
    final parsed = value is num ? value.toInt() : null;
    return parsed != null && parsed > 0 ? parsed : null;
  }
}

/// Mutable-in-memory shape used by the pull path before applying the
/// change to the local vault. Distinct from
/// [RemoteVaultBlobChange] in that it does NOT carry the
/// `vault_ops.id` cursor (which is consumed by the cursor advance,
/// not by the vault writer).
class RemoteVaultBlobSnapshot {
  /// Builds a [RemoteVaultBlobSnapshot]. Same semantics as
  /// [RemoteVaultBlobChange] minus the op cursor.
  const RemoteVaultBlobSnapshot({
    required this.recordId,
    required this.version,
    required this.keyVersion,
    required this.updatedAt,
    this.ciphertext,
    this.nonce,
    this.gcmTag,
    this.itemKeySalt,
    this.itemKeyVersion,
    this.deletedAt,
  });

  /// Remote record id.
  final String recordId;

  /// Vault record version.
  final int version;

  /// Item payload format version (see [RemoteVaultBlobChange.keyVersion]).
  final int keyVersion;

  /// Base64 ciphertext. Null for tombstones.
  final String? ciphertext;

  /// Base64 nonce. Null for tombstones.
  final String? nonce;

  /// Base64 GCM auth tag. Null for tombstones.
  final String? gcmTag;

  /// Base64 salt of the per-item key. Null unless [keyVersion] is an
  /// item-keyed payload version (see
  /// `SyncItemPayloadCodec.itemKeyPayloadVersion`). The vault refuses a
  /// payload that claims that version without it.
  final String? itemKeySalt;

  /// Item key version, under the same gate as [itemKeySalt].
  final int? itemKeyVersion;

  /// When the record was tombstoned.
  final DateTime? deletedAt;

  /// When the record was last modified.
  final DateTime updatedAt;

  /// True when this snapshot is a delete (tombstone).
  bool get isTombstone => deletedAt != null;

  /// Builds a [RemoteVaultBlobSnapshot] from a freshly-decoded
  /// [RemoteVaultBlobChange] (strips the op cursor).
  factory RemoteVaultBlobSnapshot.fromChange(RemoteVaultBlobChange change) {
    return RemoteVaultBlobSnapshot(
      recordId: change.recordId,
      version: change.version,
      keyVersion: change.keyVersion,
      ciphertext: change.ciphertext,
      nonce: change.nonce,
      gcmTag: change.gcmTag,
      itemKeySalt: change.itemKeySalt,
      itemKeyVersion: change.itemKeyVersion,
      deletedAt: change.deletedAt,
      updatedAt: change.updatedAt,
    );
  }

  /// Serializes the snapshot for local persistence.
  Map<String, dynamic> toJson() {
    return {
      'recordId': recordId,
      'version': version,
      'keyVersion': keyVersion,
      'ciphertext': ciphertext,
      'nonce': nonce,
      'gcmTag': gcmTag,
      'itemKeySalt': itemKeySalt,
      'itemKeyVersion': itemKeyVersion,
      'deletedAt': deletedAt?.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  /// Inverse of [toJson]. Accepts the legacy `aad` / `gcm_tag`
  /// field names for [gcmTag] to stay compatible with old persisted
  /// data. Snapshots persisted before item-keyed payloads existed carry
  /// neither item key field and load with both null.
  factory RemoteVaultBlobSnapshot.fromJson(Map<String, dynamic> json) {
    return RemoteVaultBlobSnapshot(
      recordId: json['recordId'] as String,
      version: json['version'] as int,
      keyVersion: json['keyVersion'] as int,
      ciphertext: json['ciphertext'] as String?,
      nonce: json['nonce'] as String?,
      gcmTag: RemoteVaultBlobChange._readNullableGcmTag(json),
      itemKeySalt: json['itemKeySalt'] as String?,
      itemKeyVersion: RemoteVaultBlobChange._readNullableItemKeyVersion(json),
      deletedAt: json['deletedAt'] == null
          ? null
          : DateTime.parse(json['deletedAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
    );
  }
}
