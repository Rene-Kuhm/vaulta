import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../features/vault/domain/vault_item.dart';

/// Why a `.vaulta` backup could not be opened. See
/// `docs/architecture/ADR-006-encrypted-backup.md`.
enum VaultBackupFailure {
  /// The file is not a well-formed `.vaulta` envelope (bad JSON,
  /// missing or mistyped fields, out-of-range sizes, oversized file).
  malformed,

  /// The envelope declares a format version this build cannot read.
  unsupportedVersion,

  /// The envelope declares KDF parameters below the import floor
  /// (downgrade defense). Refused before any key derivation.
  insecureKdf,

  /// AES-GCM authentication failed: wrong backup password, or the
  /// header, ciphertext or tag were modified.
  decryptionFailed,
}

/// Thrown by [VaultBackupService] when a backup cannot be produced or
/// opened. [failure] is the machine-readable reason; the message never
/// contains secrets or vault content.
class VaultBackupException implements Exception {
  /// Builds an exception for [failure].
  const VaultBackupException(this.failure);

  /// Machine-readable reason.
  final VaultBackupFailure failure;

  @override
  String toString() => 'VaultBackupException(${failure.name})';
}

/// Public metadata of a `.vaulta` envelope, readable without the
/// backup password. Every field is covered by the AES-GCM AAD, so it
/// is only trustworthy once [VaultBackupService.decrypt] succeeded.
class VaultBackupHeader {
  /// Builds a header snapshot.
  const VaultBackupHeader({
    required this.version,
    required this.createdAt,
    required this.appVersion,
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
  });

  /// Envelope format version (`v`).
  final int version;

  /// When the backup was created (UTC).
  final DateTime createdAt;

  /// App version that produced the backup.
  final String appVersion;

  /// Argon2id memory cost in KiB.
  final int memoryKiB;

  /// Argon2id iteration count.
  final int iterations;

  /// Argon2id parallelism.
  final int parallelism;
}

/// Decrypted content of a `.vaulta` backup.
class VaultBackupContents {
  /// Builds the decrypted contents.
  const VaultBackupContents({
    required this.header,
    required this.items,
    required this.exportedAt,
  });

  /// Authenticated envelope header.
  final VaultBackupHeader header;

  /// Every vault item stored in the backup, in export order.
  final List<VaultItem> items;

  /// Timestamp written inside the encrypted payload (UTC).
  final DateTime exportedAt;
}

/// Produces and opens Vaulta's encrypted backup format (`.vaulta`,
/// ADR-006).
///
/// The backup key is derived with Argon2id from a *backup password*
/// chosen at export time; the vault DEK is never reused, so a backup
/// restores on a new device without the old secure storage. The
/// envelope header (everything but `ciphertext_b64` and `tag_b64`) is
/// canonicalized and bound as AES-GCM AAD, so tampering with the KDF
/// parameters, version or any other header field fails decryption.
///
/// Plaintext only ever exists in memory: [export] returns the sealed
/// envelope bytes and [decrypt] returns parsed items. Buffers this
/// class owns are zeroed best-effort after use (Dart strings cannot be
/// wiped; see ADR-006).
class VaultBackupService {
  /// Builds a service whose exports use the given Argon2id cost.
  /// Throws [ArgumentError] when the parameters are weaker than the
  /// vault's own KDF (64 MiB, 3 iterations, ADR-001): a backup must
  /// never be cheaper to brute-force than the vault it copies.
  /// [clock] defaults to [DateTime.now]. [useFastTestKdf] is only
  /// accepted under `flutter_test`; use [VaultBackupService.test].
  VaultBackupService({
    int memoryKiB = vaultMemoryKiB,
    int iterations = vaultIterations,
    int parallelism = 1,
    DateTime Function()? clock,
    bool useFastTestKdf = false,
  }) : _memoryKiB = memoryKiB,
       _iterations = iterations,
       _parallelism = parallelism,
       _clock = clock ?? DateTime.now,
       _useFastTestKdf = useFastTestKdf {
    if (memoryKiB < vaultMemoryKiB ||
        iterations < vaultIterations ||
        parallelism < 1 ||
        parallelism > maxParallelism) {
      throw ArgumentError(
        'Backup KDF parameters must be at least as strong as the vault KDF.',
      );
    }
    if (useFastTestKdf && !_isRunningInFlutterTest()) {
      // Fail closed: never ship a backup derived with the test KDF.
      throw StateError('useFastTestKdf is only valid inside flutter_test.');
    }
  }

  /// Test-only factory: writes production KDF parameters into the
  /// header (so the import floor checks run as in production) but
  /// derives the key with a fast HKDF instead of Argon2id. Throws
  /// outside `flutter_test`.
  factory VaultBackupService.test({DateTime Function()? clock}) {
    return VaultBackupService(clock: clock, useFastTestKdf: true);
  }

  /// File extension (without the dot) of a Vaulta backup.
  static const fileExtension = 'vaulta';

  /// Value of the envelope `format` field.
  static const formatName = 'vaulta-backup';

  /// Envelope version written by this build and the only one it reads.
  static const currentVersion = 1;

  /// Vault KDF memory cost (ADR-001); the export floor.
  static const vaultMemoryKiB = 65536;

  /// Vault KDF iteration count (ADR-001); the export floor.
  static const vaultIterations = 3;

  /// Import floor for Argon2id memory (OWASP minimum, 19 MiB). An
  /// envelope below it is refused before any derivation.
  static const minImportMemoryKiB = 19456;

  /// Import floor for Argon2id iterations.
  static const minImportIterations = 2;

  /// Import ceiling for Argon2id memory (1 GiB): a crafted file must
  /// not be able to make the app allocate unbounded memory.
  static const maxImportMemoryKiB = 1048576;

  /// Import ceiling for Argon2id iterations (bounds CPU time).
  static const maxImportIterations = 20;

  /// Upper bound for Argon2id parallelism, on export and import.
  static const maxParallelism = 16;

  /// Largest envelope accepted on import (32 MiB).
  static const maxEnvelopeBytes = 32 * 1024 * 1024;

  static const _keyBytes = 32;
  static const _saltBytes = 16;
  static const _nonceBytes = 12;
  static const _tagBytes = 16;
  static const _kdfName = 'argon2id';
  static const _cipherName = 'AES-256-GCM';
  static const _envelopeKeys = {
    'format',
    'v',
    'created_at',
    'app_version',
    'kdf',
    'cipher',
    'ciphertext_b64',
    'tag_b64',
  };
  static const _kdfKeys = {
    'name',
    'salt_b64',
    'memory_kib',
    'iterations',
    'parallelism',
    'dk_len',
  };
  static const _cipherKeys = {'alg', 'nonce_b64'};
  static final _aesGcm = AesGcm.with256bits();

  final int _memoryKiB;
  final int _iterations;
  final int _parallelism;
  final DateTime Function() _clock;
  final bool _useFastTestKdf;

  static bool _isRunningInFlutterTest() {
    final value = Platform.environment['FLUTTER_TEST'];
    return value == 'true' || value == '1';
  }

  /// Seals [items] into a `.vaulta` envelope encrypted under a key
  /// derived from [backupPassword]. Returns the UTF-8 JSON bytes of
  /// the envelope, ready to be written to a user-chosen location.
  /// The caller is responsible for the password policy check.
  Future<Uint8List> export({
    required List<VaultItem> items,
    required String backupPassword,
    required String appVersion,
  }) async {
    final now = _clock().toUtc();
    final salt = _randomBytes(_saltBytes);
    final nonce = _randomBytes(_nonceBytes);
    final header = <String, Object?>{
      'format': formatName,
      'v': currentVersion,
      'created_at': now.toIso8601String(),
      'app_version': appVersion,
      'kdf': {
        'name': _kdfName,
        'salt_b64': base64Encode(salt),
        'memory_kib': _memoryKiB,
        'iterations': _iterations,
        'parallelism': _parallelism,
        'dk_len': _keyBytes,
      },
      'cipher': {'alg': _cipherName, 'nonce_b64': base64Encode(nonce)},
    };

    final plaintext = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'items': [for (final item in items) item.toJson()],
          'exported_at': now.toIso8601String(),
          'item_count': items.length,
        }),
      ),
    );
    final key = await _deriveKey(
      password: backupPassword,
      salt: salt,
      memoryKiB: _memoryKiB,
      iterations: _iterations,
      parallelism: _parallelism,
    );
    try {
      final box = await _aesGcm.encrypt(
        plaintext,
        secretKey: key,
        nonce: nonce,
        aad: canonicalHeaderBytes(header),
      );
      final envelope = <String, Object?>{
        ...header,
        'ciphertext_b64': base64Encode(box.cipherText),
        'tag_b64': base64Encode(box.mac.bytes),
      };
      return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
    } finally {
      _wipe(plaintext);
      _destroy(key);
    }
  }

  /// Parses and validates the public header of [bytes] without the
  /// password. Throws [VaultBackupException] with
  /// [VaultBackupFailure.malformed], [VaultBackupFailure.unsupportedVersion]
  /// or [VaultBackupFailure.insecureKdf]. The values are not yet
  /// authenticated; only [decrypt] proves they were not tampered with.
  VaultBackupHeader readHeader(Uint8List bytes) => _parseEnvelope(bytes).header;

  /// Validates the envelope, derives the backup key from
  /// [backupPassword] and decrypts the items. Throws
  /// [VaultBackupException]; a wrong password and any modification of
  /// the header, ciphertext or tag both surface as
  /// [VaultBackupFailure.decryptionFailed].
  Future<VaultBackupContents> decrypt({
    required Uint8List bytes,
    required String backupPassword,
  }) async {
    final envelope = _parseEnvelope(bytes);
    final key = await _deriveKey(
      password: backupPassword,
      salt: envelope.salt,
      memoryKiB: envelope.header.memoryKiB,
      iterations: envelope.header.iterations,
      parallelism: envelope.header.parallelism,
    );
    List<int> clear;
    try {
      clear = await _aesGcm.decrypt(
        SecretBox(
          envelope.ciphertext,
          nonce: envelope.nonce,
          mac: envelope.tag,
        ),
        secretKey: key,
        aad: envelope.aad,
      );
    } on SecretBoxAuthenticationError {
      throw const VaultBackupException(VaultBackupFailure.decryptionFailed);
    } finally {
      _destroy(key);
    }
    try {
      return _parsePayload(clear, envelope.header);
    } finally {
      _wipe(clear);
    }
  }

  /// Canonical UTF-8 encoding of an envelope header, used as AES-GCM
  /// AAD: object keys sorted by code unit at every level, no
  /// insignificant whitespace, `dart:convert` string escaping. Values
  /// are limited to strings, integers and nested objects.
  static Uint8List canonicalHeaderBytes(Map<String, Object?> header) {
    return Uint8List.fromList(utf8.encode(jsonEncode(_canonicalize(header))));
  }

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonicalize(value[key])};
    }
    if (value is List) {
      return [for (final entry in value) _canonicalize(entry)];
    }
    return value;
  }

  _ParsedEnvelope _parseEnvelope(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxEnvelopeBytes) {
      throw const VaultBackupException(VaultBackupFailure.malformed);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const VaultBackupException(VaultBackupFailure.malformed);
    }
    if (decoded is! Map<String, Object?> || decoded['format'] != formatName) {
      throw const VaultBackupException(VaultBackupFailure.malformed);
    }
    final version = decoded['v'];
    if (version is! int) {
      throw const VaultBackupException(VaultBackupFailure.malformed);
    }
    if (version != currentVersion) {
      throw const VaultBackupException(VaultBackupFailure.unsupportedVersion);
    }
    if (!_hasExactKeys(decoded, _envelopeKeys)) {
      throw const VaultBackupException(VaultBackupFailure.malformed);
    }

    final kdf = decoded['kdf'];
    final cipher = decoded['cipher'];
    if (kdf is! Map<String, Object?> ||
        cipher is! Map<String, Object?> ||
        !_hasExactKeys(kdf, _kdfKeys) ||
        !_hasExactKeys(cipher, _cipherKeys) ||
        kdf['name'] != _kdfName ||
        cipher['alg'] != _cipherName) {
      throw const VaultBackupException(VaultBackupFailure.malformed);
    }

    final memoryKiB = kdf['memory_kib'];
    final iterations = kdf['iterations'];
    final parallelism = kdf['parallelism'];
    final dkLen = kdf['dk_len'];
    if (memoryKiB is! int ||
        iterations is! int ||
        parallelism is! int ||
        dkLen is! int) {
      throw const VaultBackupException(VaultBackupFailure.malformed);
    }
    // Downgrade defense: refuse cheap parameters before deriving.
    if (memoryKiB < minImportMemoryKiB ||
        iterations < minImportIterations ||
        parallelism < 1) {
      throw const VaultBackupException(VaultBackupFailure.insecureKdf);
    }
    // Resource-exhaustion defense and fixed key size.
    if (memoryKiB > maxImportMemoryKiB ||
        iterations > maxImportIterations ||
        parallelism > maxParallelism ||
        memoryKiB < 8 * parallelism ||
        dkLen != _keyBytes) {
      throw const VaultBackupException(VaultBackupFailure.malformed);
    }

    final createdAtRaw = decoded['created_at'];
    final appVersion = decoded['app_version'];
    final createdAt = createdAtRaw is String
        ? DateTime.tryParse(createdAtRaw)
        : null;
    if (createdAt == null || appVersion is! String) {
      throw const VaultBackupException(VaultBackupFailure.malformed);
    }

    final salt = _decodeB64(kdf['salt_b64']);
    final nonce = _decodeB64(cipher['nonce_b64']);
    final ciphertext = _decodeB64(decoded['ciphertext_b64']);
    final tag = _decodeB64(decoded['tag_b64']);
    if (salt.length < _saltBytes ||
        salt.length > 64 ||
        nonce.length != _nonceBytes ||
        tag.length != _tagBytes) {
      throw const VaultBackupException(VaultBackupFailure.malformed);
    }

    final header = Map<String, Object?>.of(decoded)
      ..remove('ciphertext_b64')
      ..remove('tag_b64');
    return _ParsedEnvelope(
      header: VaultBackupHeader(
        version: version,
        createdAt: createdAt.toUtc(),
        appVersion: appVersion,
        memoryKiB: memoryKiB,
        iterations: iterations,
        parallelism: parallelism,
      ),
      aad: canonicalHeaderBytes(header),
      salt: salt,
      nonce: nonce,
      ciphertext: ciphertext,
      tag: Mac(tag),
    );
  }

  VaultBackupContents _parsePayload(List<int> clear, VaultBackupHeader header) {
    try {
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('payload is not an object');
      }
      final rawItems = decoded['items'];
      final count = decoded['item_count'];
      final exportedAtRaw = decoded['exported_at'];
      if (rawItems is! List ||
          count is! int ||
          count != rawItems.length ||
          exportedAtRaw is! String) {
        throw const FormatException('payload fields');
      }
      final items = [
        for (final raw in rawItems)
          VaultItem.fromJson(Map<String, dynamic>.from(raw as Map)),
      ];
      return VaultBackupContents(
        header: header,
        items: List.unmodifiable(items),
        exportedAt: DateTime.parse(exportedAtRaw).toUtc(),
      );
    } on Object catch (error) {
      if (error is VaultBackupException) rethrow;
      // TypeError / FormatException from an authenticated but
      // unreadable payload. Do not surface the error text: it may
      // echo payload content.
      throw const VaultBackupException(VaultBackupFailure.malformed);
    }
  }

  Future<SecretKey> _deriveKey({
    required String password,
    required List<int> salt,
    required int memoryKiB,
    required int iterations,
    required int parallelism,
  }) async {
    if (_useFastTestKdf) {
      // Test-only: binds password, salt and parameters, costs ~nothing.
      return Hkdf(hmac: Hmac.sha256(), outputLength: _keyBytes).deriveKey(
        secretKey: SecretKey(utf8.encode(password)),
        nonce: salt,
        info: utf8.encode(
          'vaulta-backup-test:$memoryKiB:$iterations:$parallelism',
        ),
      );
    }
    return Argon2id(
      memory: memoryKiB,
      parallelism: parallelism,
      iterations: iterations,
      hashLength: _keyBytes,
    ).deriveKeyFromPassword(password: password, nonce: salt);
  }

  static bool _hasExactKeys(Map<String, Object?> map, Set<String> keys) {
    return map.length == keys.length && map.keys.every(keys.contains);
  }

  static Uint8List _decodeB64(Object? value) {
    if (value is! String) {
      throw const VaultBackupException(VaultBackupFailure.malformed);
    }
    try {
      return base64Decode(value);
    } on FormatException {
      throw const VaultBackupException(VaultBackupFailure.malformed);
    }
  }

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  static void _wipe(List<int> buffer) {
    try {
      buffer.fillRange(0, buffer.length, 0);
    } on UnsupportedError {
      // Unmodifiable view returned by a library: nothing we can wipe.
    }
  }

  static void _destroy(SecretKey key) {
    if (key is SecretKeyData) {
      key.destroy();
    }
  }
}

class _ParsedEnvelope {
  const _ParsedEnvelope({
    required this.header,
    required this.aad,
    required this.salt,
    required this.nonce,
    required this.ciphertext,
    required this.tag,
  });

  final VaultBackupHeader header;
  final Uint8List aad;
  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Mac tag;
}
