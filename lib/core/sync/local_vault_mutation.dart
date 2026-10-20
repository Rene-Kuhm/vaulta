/// Description of a local vault mutation emitted by the repository
/// and consumed by the push sync service. Carries the encrypted
/// payload (when applicable) so the sync layer can ship it to the
/// remote backend without re-deriving any key material.
class LocalVaultMutation {
  const LocalVaultMutation._({
    required this.kind,
    required this.localRecordId,
    required this.occurredAt,
    this.ciphertext,
    this.nonce,
    this.gcmTag,
    this.keyVersion,
  });

  /// Builds an upsert mutation. All encryption material is required.
  factory LocalVaultMutation.upsert({
    required String localRecordId,
    required String ciphertext,
    required String nonce,
    String? gcmTag,
    required int keyVersion,
    required DateTime occurredAt,
  }) {
    return LocalVaultMutation._(
      kind: LocalVaultMutationKind.upsert,
      localRecordId: localRecordId,
      ciphertext: ciphertext,
      nonce: nonce,
      gcmTag: gcmTag,
      keyVersion: keyVersion,
      occurredAt: occurredAt,
    );
  }

  /// Builds a delete (tombstone) mutation. No ciphertext needed.
  factory LocalVaultMutation.delete({
    required String localRecordId,
    required DateTime occurredAt,
  }) {
    return LocalVaultMutation._(
      kind: LocalVaultMutationKind.delete,
      localRecordId: localRecordId,
      occurredAt: occurredAt,
    );
  }

  /// Discriminator ([LocalVaultMutationKind.upsert] or `.delete]).
  final LocalVaultMutationKind kind;

  /// Local vault record id (UUID or short slug) that the mutation
  /// targets. The sync layer maps this to a remote record id before
  /// dispatch.
  final String localRecordId;

  /// Ciphertext (upsert only). Null for deletes. Plain base64 for
  /// legacy v1/v2 payloads; for v3 it is the record-bound wire form
  /// produced by `SyncItemPayloadCodec.encode`.
  final String? ciphertext;

  /// Base64 nonce (upsert only). Null for deletes.
  final String? nonce;

  /// Base64 GCM auth tag (upsert only). Null for deletes.
  final String? gcmTag;

  /// Item payload format version (1, 2 or 3), shipped as the backend
  /// `key_version` column so other devices know how to decode the
  /// payload. Version 3 means the ciphertext is bound to its record id
  /// and key id through AES-GCM associated data.
  final int? keyVersion;

  /// When the local mutation happened. The push queue uses this to
  /// order dispatch and to merge with the remote's last-seen-at.
  final DateTime occurredAt;
}

/// Discriminator for [LocalVaultMutation]: upsert (new or updated
/// ciphertext) or delete (tombstone).
enum LocalVaultMutationKind {
  /// Local side created or updated the record. Carries a fresh
  /// ciphertext.
  upsert,

  /// Local side deleted the record. The push RPC ships a tombstone
  /// (no ciphertext, just the record id + expected version).
  delete,
}

/// Consumer of local vault mutations. Implemented by
/// [BidirectionalSyncService] (the previous [IncrementalPushSyncService]
/// implementation was removed in T5 of ADR-004) to receive the
/// stream of upserts and deletes as they happen, so they can be
/// drained to the remote.
abstract interface class LocalVaultMutationSink {
  /// Hands a [LocalVaultMutation] to the sink. The sink should
  /// enqueue + trigger an async drain; the call site doesn't wait.
  Future<void> onLocalMutation(LocalVaultMutation mutation);
}

/// Pass-through sink: a [LocalVaultMutationSink] whose delegate can
/// be (re)attached at runtime. The vault repository writes to this
/// relay, the relay forwards to the currently-attached sync service.
/// This indirection lets the sync service be replaced or wired up
/// after the repository is constructed (e.g. after Supabase
/// initialization) without touching the repository.
class RelayLocalVaultMutationSink implements LocalVaultMutationSink {
  /// Attaches [delegate] as the forward target. Pass `null` (or
  /// re-attach) to redirect. Only one delegate at a time.
  void attach(LocalVaultMutationSink delegate) {
    _delegate = delegate;
  }

  @override
  Future<void> onLocalMutation(LocalVaultMutation mutation) async {
    final delegate = _delegate;
    if (delegate == null) {
      return;
    }

    await delegate.onLocalMutation(mutation);
  }

  LocalVaultMutationSink? _delegate;
}
