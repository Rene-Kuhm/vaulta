/// Contract for the remote side of the vault-key sync loop.
///
/// The vault key is the serialized [MasterPasswordRecord] (`record_json`): the
/// wrapped DEK, the KDF parameters, the verifier and the key id. It is the one
/// piece of state that must travel between devices before any item can open,
/// because every item key is derived from the DEK.
///
/// Shaped around the sync need, not the transport. See
/// `docs/adr/0001-crypto-key-derivation-and-encrypted-blob.md` and `odd/tasks/vault-key-cross-device-sync.md`.
abstract interface class VaultKeySyncRepository {
  /// Returns the remote `record_json` for the current user, or `null` when the
  /// user has never pushed a vault key.
  Future<String?> readRemoteKey();

  /// Upserts the remote `record_json` under [keyId]. Idempotent: a second push
  /// with the same key overwrites the row with identical content.
  Future<void> putRemoteKey({
    required String keyId,
    required String recordJson,
  });
}
