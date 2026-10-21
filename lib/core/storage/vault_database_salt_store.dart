import 'dart:convert';
import 'dart:math';

import '../security/secure_storage_service.dart';

/// Persists the per-database salt the vault database key is derived from.
///
/// The salt cannot live inside the database: reading it would require the key it
/// is used to derive. It therefore sits in secure storage, next to the wrapped
/// DEK, and is created once per installation.
///
/// A changed salt means a different database key, so the same DEK cannot open
/// another installation's database. That is the point: two devices syncing the
/// same vault keep independent database keys.
class VaultDatabaseSaltStore {
  /// Builds the store over the app's secure storage.
  VaultDatabaseSaltStore({required SecureStorageService storage, Random? random})
    : _storage = storage,
      _random = random ?? Random.secure();

  /// Secure-storage key holding the base64 salt.
  static const String storageKey = 'vault_db_salt_v1';

  /// Length of the HKDF salt, in bytes.
  static const int saltBytes = 16;

  final SecureStorageService _storage;
  final Random _random;

  /// Returns the stored salt, creating it on first call.
  Future<List<int>> readOrCreate() async {
    final existing = await _storage.read(storageKey);
    if (existing != null && existing.isNotEmpty) {
      final decoded = base64Decode(existing);
      if (decoded.length == saltBytes) return decoded;
      // A salt of the wrong length cannot be the one this build wrote. Refusing is
      // safer than silently swapping in a new one and losing access to the
      // current database.
      throw StateError(
        'stored vault database salt has ${decoded.length} bytes, expected '
        '$saltBytes',
      );
    }
    final salt = List<int>.generate(saltBytes, (_) => _random.nextInt(256));
    await _storage.save(storageKey, base64Encode(salt));
    return salt;
  }
}
