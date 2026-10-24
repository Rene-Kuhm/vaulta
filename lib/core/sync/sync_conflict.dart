/// What kind of operation produced a [SyncConflictRecord]. Used by
/// the conflict-resolver UI to render the right call-to-action
/// ("Keep local edit" vs. "Keep local delete").
enum SyncConflictOperationKind {
  /// Local side did an upsert; remote side already had a newer
  /// version of the same record.
  upsert,

  /// Local side did a delete; remote side has a newer version of
  /// the same record.
  delete,
}

/// What the user chose to resolve a [SyncConflictRecord].
enum SyncConflictResolution {
  /// Keep the local version, drop the remote change. The local
  /// mutation is re-pushed with a fresh idempotency key.
  keepLocal,

  /// Drop the local change and pull the remote version. The local
  /// vault item is overwritten and the push queue item is removed.
  keepRemote,
}

/// Read-side projection of a single vault record at a known
/// version. Used by the conflict-resolver UI to show "your version
/// vs. their version" side-by-side.
class SyncConflictSnapshot {
  /// Builds a [SyncConflictSnapshot] from the known fields. All
  /// payload fields are optional because tombstones carry none.
  const SyncConflictSnapshot({
    required this.version,
    this.keyVersion,
    this.ciphertext,
    this.nonce,
    this.gcmTag,
    this.itemKeySalt,
    this.itemKeyVersion,
    this.deletedAt,
    this.updatedAt,
  });

  /// Vault record version. Null only for very old payloads predating
  /// the version field.
  final int? version;

  /// DEK version used to encrypt this payload. The conflict
  /// resolver surfaces mismatches between local and remote as a
  /// hint that a rekey is in flight.
  final int? keyVersion;

  /// Base64 ciphertext. Null for tombstones.
  final String? ciphertext;

  /// Base64 nonce. Null for tombstones.
  final String? nonce;

  /// Base64 GCM auth tag. Null for tombstones.
  final String? gcmTag;

  /// Base64 salt of the per-item key, for payloads sealed under their own
  /// key. Null for DEK-sealed payloads and tombstones. Carried so the
  /// conflict view shows the same payload the queue would re-ship.
  final String? itemKeySalt;

  /// Item key version, under the same gate as [itemKeySalt].
  final int? itemKeyVersion;

  /// When the record was tombstoned. Non-null marks the snapshot
  /// as a delete.
  final DateTime? deletedAt;

  /// When the record was last modified. Null only for very old
  /// payloads.
  final DateTime? updatedAt;

  /// Inverse of [toJson]. Accepts the legacy `aad` field name as a
  /// fallback for [gcmTag] so old persisted conflicts keep loading.
  /// Records persisted before item-keyed payloads existed carry neither
  /// item key field and load with both null.
  factory SyncConflictSnapshot.fromJson(Map<String, dynamic> json) {
    return SyncConflictSnapshot(
      version: json['version'] as int?,
      keyVersion: json['keyVersion'] as int?,
      ciphertext: json['ciphertext'] as String?,
      nonce: json['nonce'] as String?,
      gcmTag: (json['gcmTag'] ?? json['aad']) as String?,
      itemKeySalt: json['itemKeySalt'] as String?,
      itemKeyVersion: json['itemKeyVersion'] as int?,
      deletedAt: json['deletedAt'] == null
          ? null
          : DateTime.parse(json['deletedAt'] as String).toUtc(),
      updatedAt: json['updatedAt'] == null
          ? null
          : DateTime.parse(json['updatedAt'] as String).toUtc(),
    );
  }

  /// Serializes the snapshot for persistence in the conflict log.
  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'keyVersion': keyVersion,
      'ciphertext': ciphertext,
      'nonce': nonce,
      'gcmTag': gcmTag,
      'itemKeySalt': itemKeySalt,
      'itemKeyVersion': itemKeyVersion,
      'deletedAt': deletedAt?.toUtc().toIso8601String(),
      'updatedAt': updatedAt?.toUtc().toIso8601String(),
    };
  }
}

/// One pending conflict between the local mutation and the remote
/// version. Persisted in the conflict log and surfaced by the
/// [SyncConflictResolver] until the user picks
/// [SyncConflictResolution.keepLocal] or [keepRemote].
class SyncConflictRecord {
  /// Builds a [SyncConflictRecord]. [id], [opId], [localRecordId],
  /// [remoteRecordId], [kind], [createdAt] and [updatedAt] are
  /// required; everything else is optional metadata.
  const SyncConflictRecord({
    required this.id,
    required this.opId,
    required this.localRecordId,
    required this.remoteRecordId,
    required this.kind,
    required this.createdAt,
    required this.updatedAt,
    this.lastResultCode,
    this.message,
    this.expectedVersion,
    this.currentVersion,
    this.localSnapshot,
    this.remoteSnapshot,
  });

  /// UUID generated at conflict-detection time. Stable across app
  /// restarts and used to identify the row in the conflict log.
  final String id;

  /// The original push opId that triggered the CAS conflict. Useful
  /// for correlating the conflict with the originating push attempt.
  final String opId;

  /// Local vault record id (the slug/uuid the user sees).
  final String localRecordId;

  /// Backend-side record id (after the local→remote mapping).
  final String remoteRecordId;

  /// Whether the local mutation was an upsert or a delete.
  final SyncConflictOperationKind kind;

  /// When the conflict was first detected.
  final DateTime createdAt;

  /// When the record was last touched (every retry bumps this).
  final DateTime updatedAt;

  /// Most recent backend result code (e.g. `cas_conflict`). Null
  /// for the initial creation.
  final String? lastResultCode;

  /// Most recent backend message, human-readable.
  final String? message;

  /// The version the local side sent in its push RPC. The backend
  /// reported [currentVersion] instead.
  final int? expectedVersion;

  /// The version the backend holds right now.
  final int? currentVersion;

  /// Snapshot of the local mutation at conflict time.
  final SyncConflictSnapshot? localSnapshot;

  /// Snapshot of the remote version at conflict time.
  final SyncConflictSnapshot? remoteSnapshot;

  /// Returns a copy with the supplied fields replaced. Useful for
  /// bumping [updatedAt] / refreshing [message] / [lastResultCode]
  /// after a retry or a user action.
  SyncConflictRecord copyWith({
    DateTime? updatedAt,
    String? lastResultCode,
    String? message,
    int? expectedVersion,
    int? currentVersion,
    SyncConflictSnapshot? localSnapshot,
    SyncConflictSnapshot? remoteSnapshot,
  }) {
    return SyncConflictRecord(
      id: id,
      opId: opId,
      localRecordId: localRecordId,
      remoteRecordId: remoteRecordId,
      kind: kind,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastResultCode: lastResultCode ?? this.lastResultCode,
      message: message ?? this.message,
      expectedVersion: expectedVersion ?? this.expectedVersion,
      currentVersion: currentVersion ?? this.currentVersion,
      localSnapshot: localSnapshot ?? this.localSnapshot,
      remoteSnapshot: remoteSnapshot ?? this.remoteSnapshot,
    );
  }

  /// Inverse of [toJson]. Used at app startup to rehydrate the
  /// conflict log from disk.
  factory SyncConflictRecord.fromJson(Map<String, dynamic> json) {
    return SyncConflictRecord(
      id: json['id'] as String,
      opId: json['opId'] as String,
      localRecordId: json['localRecordId'] as String,
      remoteRecordId: json['remoteRecordId'] as String,
      kind: _kindFromString(json['kind'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      lastResultCode: json['lastResultCode'] as String?,
      message: json['message'] as String?,
      expectedVersion: json['expectedVersion'] as int?,
      currentVersion: json['currentVersion'] as int?,
      localSnapshot: json['localSnapshot'] == null
          ? null
          : SyncConflictSnapshot.fromJson(
              json['localSnapshot'] as Map<String, dynamic>,
            ),
      remoteSnapshot: json['remoteSnapshot'] == null
          ? null
          : SyncConflictSnapshot.fromJson(
              json['remoteSnapshot'] as Map<String, dynamic>,
            ),
    );
  }

  /// Serializes the record for persistence in the conflict log.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'opId': opId,
      'localRecordId': localRecordId,
      'remoteRecordId': remoteRecordId,
      'kind': kind.name,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      'lastResultCode': lastResultCode,
      'message': message,
      'expectedVersion': expectedVersion,
      'currentVersion': currentVersion,
      'localSnapshot': localSnapshot?.toJson(),
      'remoteSnapshot': remoteSnapshot?.toJson(),
    };
  }

  static SyncConflictOperationKind _kindFromString(String raw) {
    return switch (raw) {
      'upsert' => SyncConflictOperationKind.upsert,
      'delete' => SyncConflictOperationKind.delete,
      _ => SyncConflictOperationKind.upsert,
    };
  }
}
