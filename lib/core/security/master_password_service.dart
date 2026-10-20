import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'master_password_record.dart';
import 'password_policy.dart';

/// Owns the master-password key derivation (Argon2id) and the
/// master-password record lifecycle (create / verify / rekey).
///
/// Production code constructs it with the default parameters. Tests
/// use [MasterPasswordService.test] for a fast, low-iteration KDF
/// that asserts on `FLUTTER_TEST=true`.
class MasterPasswordService {
  /// Builds a [MasterPasswordService] with the supplied parameters.
  /// Defaults match `docs/architecture/ADR-001-crypto.md` (Argon2id
  /// 64 MiB, 3 iterations, parallelism 1, 64-byte output split with
  /// HKDF-SHA256). [useFastTestKdf] is gated to the test runner via an
  /// assertion.
  MasterPasswordService({
    int encryptionIterations = _defaultIterations,
    int argon2MemoryKiB = _defaultArgon2MemoryKiB,
    int argon2Parallelism = _defaultArgon2Parallelism,
    bool useFastTestKdf = false,
    PasswordPolicy? passwordPolicy,
  })  : assert(
          !useFastTestKdf || _isRunningInFlutterTest(),
          'useFastTestKdf is only valid inside flutter_test. Use the .test() '
          'factory or guard the caller explicitly.',
        ),
        _encryptionIterations = encryptionIterations,
        _argon2MemoryKiB = argon2MemoryKiB,
        _argon2Parallelism = argon2Parallelism,
        _useFastTestKdf = useFastTestKdf,
        _passwordPolicy = passwordPolicy ?? const PasswordPolicy();

  /// Test-only factory: uses a 1-iteration, 1 MiB KDF so the suite
  /// stays fast. The `useFastTestKdf` flag inside the constructor
  /// asserts that this is only constructed under `flutter_test`.
  factory MasterPasswordService.test() {
    return MasterPasswordService(
      encryptionIterations: 1,
      argon2MemoryKiB: 1024,
      useFastTestKdf: true,
    );
  }

  /// Minimum length for an accepted master password. Kept in step with
  /// [PasswordPolicy.defaultMinimumLength].
  static const minimumLength = PasswordPolicy.defaultMinimumLength;
  static const _recordVersion = MasterPasswordRecord.currentVersion;
  static const _defaultIterations = 3;
  static const _keyBytes = 32;

  /// Length of the single Argon2id output that both the verifier and the
  /// KEK are split from. 64 bytes: one SHA-256-sized half for each.
  static const _masterKeyBytes = 64;

  /// HKDF `info` label for the verifier half of the master key.
  static const _verifierInfo = 'vaulta:v3:verifier';

  /// HKDF `info` label for the KEK half of the master key.
  static const _kekInfo = 'vaulta:v3:kek';

  static const _defaultArgon2MemoryKiB = 65536;
  static const _defaultArgon2Parallelism = 1;
  static final _wrapAlgorithm = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: _keyBytes);
  static final _verifierInfoBytes = utf8.encode(_verifierInfo);
  static final _kekInfoBytes = utf8.encode(_kekInfo);

  /// True only when running under `package:flutter_test`. The Dart VM
  /// does not expose a "is this a test" flag, but the flutter test
  /// runner sets `FLUTTER_TEST=true` in the process environment, which
  /// is enough to keep the test KDF from ever being constructed in
  /// production.
  static bool _isRunningInFlutterTest() {
    final value = Platform.environment['FLUTTER_TEST'];
    return value == 'true' || value == '1';
  }

  final int _encryptionIterations;
  final int _argon2MemoryKiB;
  final int _argon2Parallelism;
  final bool _useFastTestKdf;
  final PasswordPolicy _passwordPolicy;

  /// Password policy applied by [validate]. Exposed for tests and for
  /// surfaces that need to describe the policy without re-deriving it.
  PasswordPolicy get passwordPolicy => _passwordPolicy;

  /// Returns `null` if [password] is acceptable, or a user-facing hint
  /// explaining why it is not.
  ///
  /// Enforces length bounds and the breached-password blocklist. It
  /// deliberately does **not** require character-class diversity: NIST
  /// SP 800-63B §3.1.1.2 recommends against composition rules because
  /// they push users to predictable patterns while rejecting non-Latin
  /// scripts for no security benefit.
  ///
  /// Also deliberately does not block paste or autofill, and does not
  /// force rotation; both are recommended against by the same section.
  String? validate(String password) {
    final verdict = _passwordPolicy.evaluate(password);
    return PasswordPolicy.explain(verdict, _passwordPolicy.minimumLength);
  }

  /// Creates a fresh [MasterPasswordRecord] for a brand new vault.
  ///
  /// Runs Argon2id **once**: a single 64-byte master key is derived from
  /// one salt and then split with HKDF-SHA256 into the verifier half and
  /// the KEK half. The previous scheme ran Argon2id twice with two
  /// independent salts, which doubled the memory-hard work on every
  /// unlock for no security gain.
  ///
  /// A fresh 32-byte DEK is generated and wrapped under the KEK half.
  /// Call once at onboarding.
  Future<MasterPasswordRecord> createRecord(String password) async {
    final normalized = PasswordPolicy.normalize(password);
    final salt = _randomBytes(16);
    final masterKey = await _deriveMasterKey(
      password: normalized,
      salt: salt,
      iterations: _encryptionIterations,
      memoryKiB: _argon2MemoryKiB,
      parallelism: _argon2Parallelism,
      outputBytes: _masterKeyBytes,
    );
    final halves = await _splitMasterKey(masterKey);
    final dekBytes = _randomBytes(_keyBytes);
    final dekWrap = await _wrapDek(dekBytes: dekBytes, kek: halves.kek);

    return MasterPasswordRecord(
      version: _recordVersion,
      verifierIterations: _encryptionIterations,
      verifierSalt: base64Encode(salt),
      verifier: base64Encode(halves.verifier),
      encryptionIterations: _encryptionIterations,
      encryptionSalt: base64Encode(salt),
      keyId: base64UrlEncode(_randomBytes(12)),
      createdAt: DateTime.now().toUtc(),
      kdf: {
        'name': 'argon2id',
        'salt_b64': base64Encode(salt),
        'memory_kib': _argon2MemoryKiB,
        'iterations': _encryptionIterations,
        'parallelism': _argon2Parallelism,
        'dk_len': _masterKeyBytes,
        'split': 'hkdf-sha256-v3',
      },
      dekWrap: dekWrap,
      pwNorm: MasterPasswordRecord.nfcMarker,
    );
  }

  /// Verifies [password] against the stored verifier in [record] using
  /// a constant-time compare. Returns true on match. Does NOT derive
  /// the vault key; pair with [deriveVaultKey] on a positive result.
  ///
  /// v3 records hash the NFC-normalized password; v1/v2 records hashed the
  /// raw input and still do, so an existing vault is never locked out by
  /// the normalization change.
  Future<bool> verify({
    required MasterPasswordRecord record,
    required String password,
  }) async {
    if (record.version >= _recordVersion) {
      final normalized = PasswordPolicy.normalize(password);
      final kdf = record.kdf;
      if (kdf == null) {
        return false;
      }
      final masterKey = await _deriveMasterKey(
        password: normalized,
        salt: base64Decode(kdf['salt_b64'] as String),
        iterations: kdf['iterations'] as int,
        memoryKiB: kdf['memory_kib'] as int,
        parallelism: kdf['parallelism'] as int,
        outputBytes: _masterKeyBytes,
      );
      final verifier = (await _splitMasterKey(masterKey)).verifier;
      return _constantTimeEquals(verifier, base64Decode(record.verifier));
    }

    final verifier = record.version < 2
        ? await _deriveLegacyVerifier(
            password: password,
            salt: base64Decode(record.verifierSalt),
            iterations: record.verifierIterations,
          )
        : await _deriveVerifier(
            password: password,
            salt: base64Decode(record.verifierSalt),
            iterations: record.verifierIterations,
          );

    return _constantTimeEquals(verifier, base64Decode(record.verifier));
  }

  /// Derives the in-memory [SecretKey] (the DEK) from [password] and the
  /// wrapped-DEK metadata in [record]. Throws if the record is
  /// inconsistent.
  Future<SecretKey> deriveVaultKey({
    required MasterPasswordRecord record,
    required String password,
  }) async {
    // v1 records predate the Argon2id KDF and genuinely used PBKDF2.
    if (record.version < 2 || record.kdf == null) {
      return _deriveLegacyVaultKey(record: record, password: password);
    }

    final kdf = record.kdf!;
    final dekWrap = record.dekWrap;
    if (dekWrap == null) {
      throw StateError('Vault record is missing its wrapped DEK.');
    }

    // A v2 record hashed the raw password and took the Argon2id output
    // directly as the KEK. Branching on the *current* version instead of
    // the record's own version sends v2 records down the PBKDF2 path and
    // returns the wrong key, which locks every owner out: verify() passes
    // (its own branch is correct) and then the vault silently fails to
    // open.
    if (record.version < _recordVersion) {
      final legacyKek = await _deriveMasterKey(
        password: password,
        salt: base64Decode(kdf['salt_b64'] as String),
        iterations: kdf['iterations'] as int,
        memoryKiB: kdf['memory_kib'] as int,
        parallelism: kdf['parallelism'] as int,
        outputBytes: kdf['dk_len'] as int,
      );
      return SecretKey(await _unwrapDek(dekWrap: dekWrap, kek: legacyKek));
    }

    final normalized = PasswordPolicy.normalize(password);
    final masterKey = await _deriveMasterKey(
      password: normalized,
      salt: base64Decode(kdf['salt_b64'] as String),
      iterations: kdf['iterations'] as int,
      memoryKiB: kdf['memory_kib'] as int,
      parallelism: kdf['parallelism'] as int,
      outputBytes: kdf['dk_len'] as int,
    );
    final kek = (await _splitMasterKey(masterKey)).kek;
    final dekBytes = await _unwrapDek(dekWrap: dekWrap, kek: kek);
    return SecretKey(dekBytes);
  }

  /// Splits a 64-byte master key into its verifier and KEK halves.
  ///
  /// Domain-separated by `info`, so the verifier half can never be
  /// confused with the KEK half even though both come from one KDF run.
  Future<_MasterKeyHalves> _splitMasterKey(SecretKey masterKey) async {
    final verifier = await _hkdf.deriveKey(
      secretKey: masterKey,
      info: _verifierInfoBytes,
    );
    final kek = await _hkdf.deriveKey(
      secretKey: masterKey,
      info: _kekInfoBytes,
    );
    return _MasterKeyHalves(
      verifier: await verifier.extractBytes(),
      kek: kek,
    );
  }

  Future<SecretKey> _deriveLegacyVaultKey({
    required MasterPasswordRecord record,
    required String password,
  }) {
    final algorithm = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: record.encryptionIterations,
      bits: _keyBytes * 8,
    );

    return algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: base64Decode(record.encryptionSalt),
    );
  }

  /// Returns a base64url-encoded 32-byte random seed used as the
  /// salt for [VaultSession.keyId] uniqueness.
  String generateSessionSeed() {
    return base64UrlEncode(_randomBytes(32));
  }

  Future<List<int>> _deriveVerifier({
    required String password,
    required List<int> salt,
    required int iterations,
  }) async {
    if (_useFastTestKdf) {
      return _deriveFastTestBytes(
        password: password,
        salt: salt,
        iterations: iterations,
      );
    }

    final algorithm = Argon2id(
      memory: _argon2MemoryKiB,
      parallelism: _argon2Parallelism,
      iterations: iterations,
      hashLength: _keyBytes,
    );

    final secretKey = await algorithm.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );

    return secretKey.extractBytes();
  }

  Future<List<int>> _deriveLegacyVerifier({
    required String password,
    required List<int> salt,
    required int iterations,
  }) async {
    final algorithm = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: _keyBytes * 8,
    );
    final secretKey = await algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return secretKey.extractBytes();
  }

  /// Derives the single master key that both the verifier and the KEK are
  /// split from. One Argon2id run per unlock.
  Future<SecretKey> _deriveMasterKey({
    required String password,
    required List<int> salt,
    required int iterations,
    required int memoryKiB,
    required int parallelism,
    required int outputBytes,
  }) {
    if (_useFastTestKdf) {
      final fast = _deriveFastTestBytes(
        password: password,
        salt: salt,
        iterations: iterations,
        outputBytes: outputBytes,
      );
      return Future.value(SecretKey(fast));
    }

    final algorithm = Argon2id(
      memory: memoryKiB,
      parallelism: parallelism,
      iterations: iterations,
      hashLength: outputBytes,
    );
    return algorithm.deriveKeyFromPassword(password: password, nonce: salt);
  }

  Future<Map<String, dynamic>> _wrapDek({
    required List<int> dekBytes,
    required SecretKey kek,
  }) async {
    final box = await _wrapAlgorithm.encrypt(dekBytes, secretKey: kek);
    return {
      'alg': 'AES-256-GCM',
      'nonce_b64': base64Encode(box.nonce),
      'ciphertext_b64': base64Encode(box.cipherText),
      'tag_b64': base64Encode(box.mac.bytes),
    };
  }

  Future<List<int>> _unwrapDek({
    required Map<String, dynamic> dekWrap,
    required SecretKey kek,
  }) {
    if (dekWrap['alg'] != 'AES-256-GCM') {
      throw StateError('Unsupported DEK wrap algorithm.');
    }
    return _wrapAlgorithm.decrypt(
      SecretBox(
        base64Decode(dekWrap['ciphertext_b64'] as String),
        nonce: base64Decode(dekWrap['nonce_b64'] as String),
        mac: Mac(base64Decode(dekWrap['tag_b64'] as String)),
      ),
      secretKey: kek,
    );
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  List<int> _deriveFastTestBytes({
    required String password,
    required List<int> salt,
    required int iterations,
    int outputBytes = _keyBytes,
  }) {
    final seed = <int>[
      ...utf8.encode(password),
      ...salt,
      iterations & 0xff,
      (iterations >> 8) & 0xff,
    ];
    final output = List<int>.filled(outputBytes, 0);
    for (var round = 0; round < iterations + 1; round += 1) {
      for (var index = 0; index < output.length; index += 1) {
        final value = seed[(index + round) % seed.length];
        output[index] = (output[index] + value + index + round) & 0xff;
      }
    }
    return output;
  }

  bool _constantTimeEquals(List<int> left, List<int> right) {
    if (left.length != right.length) {
      return false;
    }

    var diff = 0;
    for (var index = 0; index < left.length; index++) {
      diff |= left[index] ^ right[index];
    }

    return diff == 0;
  }
}

/// The two roles derived from a single 64-byte master key.
///
/// Both halves come from one Argon2id run and are domain-separated by
/// their HKDF `info` label, so neither can be mistaken for the other.
class _MasterKeyHalves {
  const _MasterKeyHalves({required this.verifier, required this.kek});

  /// Half used to prove knowledge of the master password without
  /// revealing the KEK.
  final List<int> verifier;

  /// Half used to unwrap the DEK.
  final SecretKey kek;
}
