import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'biometric_unlock_service.dart';
import 'secure_storage_service.dart';

/// Android KeyStore-backed implementation of [BiometricEnvelopeKeyProvider].
///
/// Generates an RSA-2048 keypair in the AndroidKeyStore provider with
/// `setUserAuthenticationRequired(true)`. The private half is
/// hardware-backed and never leaves the secure element; using it
/// requires a fresh `BiometricPrompt`.
///
/// The flow the controller sees is symmetric:
///   * [acquireEnvelopeKey] runs *at enrollment time* with no prompt
///     (the public key is a public key). It returns a real
///     `SecretKey` backed by a freshly generated AES-256 seed.
///   * [releaseEnvelopeKey] runs *at unlock time* behind a
///     `BiometricPrompt` and returns the same `SecretKey`. The
///     platform is the only place that touches the private key.
///
/// The RSA-encrypted seed is persisted in [SecureStorageService] on
/// enrollment so the unlock side can hand it back to the platform.
class AndroidKeystoreEnvelopeKeyProvider
    implements BiometricEnvelopeKeyProvider, BiometricEnvelopeKeyInvalidator {
  /// Uses [storage] for the encrypted seed persistence, plus optional
  /// [keystoreChannel] and [biometricChannel] (defaults to the bundled
  /// `MethodChannel`s) and an optional [random] for tests.
  ///
  /// [isAndroid] is the platform gate. It defaults to
  /// [Platform.isAndroid], so production behaviour is unchanged; tests
  /// pass `true` to run the real logic against a fake MethodChannel on a
  /// non-Android host, which is the only way this file gets any coverage
  /// at all in CI.
  AndroidKeystoreEnvelopeKeyProvider({
    required SecureStorageService storage,
    MethodChannel? keystoreChannel,
    MethodChannel? biometricChannel,
    Random? random,
    @visibleForTesting bool? isAndroid,
  }) : _storage = storage,
       _keystoreChannel =
           keystoreChannel ?? const MethodChannel(keystoreChannelName),
       _biometricChannel =
           biometricChannel ?? const MethodChannel(biometricChannelName),
       _random = random ?? Random.secure(),
       _isAndroid = isAndroid ?? Platform.isAndroid;

  /// MethodChannel name for the Android KeyStore native side.
  static const keystoreChannelName = 'com.insyd.vaulta/keystore';

  /// MethodChannel name for the Android BiometricPrompt native side.
  static const biometricChannelName = 'com.insyd.vaulta/biometric';
  static const _encryptedSeedKey = 'vaulta_biometric_envelope_seed_v1';

  final SecureStorageService _storage;
  final MethodChannel _keystoreChannel;
  final MethodChannel _biometricChannel;
  final Random _random;

  /// The platform gate. Every native call in this class is behind it;
  /// nothing else in the class reads [Platform] directly.
  final bool _isAndroid;

  @override
  Future<BiometricEnvelopeKeyResult> acquireEnvelopeKey() async {
    if (!_isAndroid) {
      debugPrint('[Vaulta/KeyStore] acquire skipped: not Android');
      return const BiometricEnvelopeKeyResult.unavailable(
        'platform_not_android',
      );
    }
    if (!await isHardwareBackedBiometricAvailable()) {
      debugPrint(
        '[Vaulta/KeyStore] acquire skipped: hardware-backed '
        'biometric not available on this device',
      );
      return const BiometricEnvelopeKeyResult.unavailable(
        'platform_no_hardware_backed_biometric',
      );
    }

    try {
      // Always rebuild the AndroidKeyStore alias during enrollment.
      // Older app versions could leave an alias generated with a
      // different biometric contract, and reusing it makes the next
      // unlock fail with BIOMETRIC_UNAVAILABLE even though the UI can
      // show the fingerprint button.
      //
      // A failure in this wipe is reported, not swallowed. The platform
      // delete can succeed while the storage delete fails, which leaves
      // the alias gone and the ciphertext still on disk. Swallowing that
      // would enroll a fresh seed against a possibly stale alias, which
      // is exactly what the wipe exists to prevent, and it would hide the
      // half-deleted state from the user. Surfacing it is correct even
      // though it means re-enrollment has to start over.
      await deleteKey();
      await ensureKey();
    } on PlatformException catch (error) {
      debugPrint(
        '[Vaulta/KeyStore] ensureKey failed: ${error.code} '
        '${error.message}',
      );
      return BiometricEnvelopeKeyResult.unavailable(
        'ensure_key_failed:${error.code}',
      );
    } catch (error, stack) {
      debugPrint('[Vaulta/KeyStore] ensureKey unexpected: $error\n$stack');
      return BiometricEnvelopeKeyResult.unavailable(
        'ensure_key_unexpected:${error.runtimeType}',
      );
    }

    final seed = _randomBytes(32);
    final rsaEncrypted = await rsaEncryptSeed(seed);
    if (rsaEncrypted == null) {
      debugPrint('[Vaulta/KeyStore] rsaEncrypt returned null');
      return const BiometricEnvelopeKeyResult.unavailable(
        'rsa_encrypt_returned_null',
      );
    }

    // Persist the RSA-encrypted seed for the unlock path. We never
    // persist the plaintext seed.
    try {
      await _storage.save(
        _encryptedSeedKey,
        encodeEncryptedSeedForStorage(rsaEncrypted),
      );
    } catch (error, stack) {
      debugPrint(
        '[Vaulta/KeyStore] persist encrypted seed failed: '
        '$error\n$stack',
      );
      return BiometricEnvelopeKeyResult.unavailable(
        'persist_encrypted_seed_failed:${error.runtimeType}',
      );
    }

    debugPrint(
      '[Vaulta/KeyStore] acquire OK: '
      'envelope seed encrypted and persisted (${rsaEncrypted.length} bytes)',
    );
    return BiometricEnvelopeKeyResult.success(SecretKey(seed));
  }

  @override
  Future<BiometricEnvelopeKeyResult> releaseEnvelopeKey() async {
    if (!_isAndroid) {
      return const BiometricEnvelopeKeyResult.unavailable(
        'platform_not_android',
      );
    }
    if (!await isHardwareBackedBiometricAvailable()) {
      debugPrint('[Vaulta/KeyStore] release skipped: hardware not available');
      return const BiometricEnvelopeKeyResult.unavailable(
        'platform_no_hardware_backed_biometric',
      );
    }

    final stored = await _storage.read(_encryptedSeedKey);
    if (stored == null || stored.isEmpty) {
      debugPrint(
        '[Vaulta/KeyStore] release skipped: no encrypted seed on disk',
      );
      return const BiometricEnvelopeKeyResult.unavailable(
        'no_encrypted_seed_on_disk',
      );
    }
    final Uint8List ciphertext;
    try {
      ciphertext = decodeEncryptedSeedFromStorage(stored);
    } on FormatException {
      debugPrint(
        '[Vaulta/KeyStore] release skipped: encrypted seed is not base64',
      );
      await deleteKey();
      return const BiometricEnvelopeKeyResult.unavailable(
        'encrypted_seed_not_base64',
      );
    }

    try {
      final seed = await rsaDecryptSeedAuthorized(ciphertext);
      if (seed == null) {
        debugPrint(
          '[Vaulta/KeyStore] release: rsaDecrypt returned null '
          '(user cancelled or platform rejected the private key)',
        );
        return const BiometricEnvelopeKeyResult.unavailable(
          'rsa_decrypt_returned_null',
        );
      }
      debugPrint(
        '[Vaulta/KeyStore] release OK: seed recovered '
        '(${seed.length} bytes)',
      );
      return BiometricEnvelopeKeyResult.success(SecretKey(seed));
    } on PlatformException catch (error) {
      debugPrint(
        '[Vaulta/KeyStore] release: rsaDecrypt threw '
        '${error.code} ${error.message}',
      );
      if (_corruptsStoredEnvelope(error)) {
        await deleteKey();
        return BiometricEnvelopeKeyResult.unavailable(
          _platformFailure('rsa_decrypt_invalid_ciphertext', error),
        );
      }
      return BiometricEnvelopeKeyResult.unavailable(
        _platformFailure('rsa_decrypt_failed', error),
      );
    } catch (error, stack) {
      debugPrint('[Vaulta/KeyStore] release unexpected: $error\n$stack');
      return BiometricEnvelopeKeyResult.unavailable(
        'rsa_decrypt_unexpected:${error.runtimeType}',
      );
    }
  }

  /// True if the platform reports the biometric-bound RSA key is
  /// available. We probe with `isAvailable` rather than calling
  /// `ensureKey` here, because we do not want to create the key
  /// until the user explicitly enrolls.
  Future<bool> isHardwareBackedBiometricAvailable() async {
    if (!_isAndroid) return false;
    try {
      final result = await _keystoreChannel.invokeMethod<bool>('isAvailable');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Generates the hardware-backed RSA keypair. Idempotent.
  Future<String> ensureKey() async {
    final alias = await _keystoreChannel.invokeMethod<String>('ensureKey');
    return alias ?? '';
  }

  /// Wipes the hardware-backed RSA keypair and the encrypted seed.
  /// The next call to `acquireEnvelopeKey` will return null until the
  /// user re-enrolls.
  @override
  Future<void> deleteKey() async {
    if (!_isAndroid) return;
    try {
      await _keystoreChannel.invokeMethod<void>('deleteKey');
    } on PlatformException {
      // Best-effort: a missing alias is fine.
    }
    await _storage.delete(_encryptedSeedKey);
  }

  /// Asks the native side to RSA-OAEP-encrypt [plaintext] with the
  /// hardware-backed public key. Returns the ciphertext or `null` on
  /// any platform failure (or when not running on Android).
  Future<Uint8List?> rsaEncryptSeed(Uint8List plaintext) async {
    if (!_isAndroid) return null;
    try {
      final result = await _keystoreChannel.invokeMethod<Uint8List>(
        'rsaEncrypt',
        {'plaintext': plaintext},
      );
      return result;
    } on PlatformException catch (error) {
      debugPrint(
        '[Vaulta/KeyStore] rsaEncrypt threw ${error.code} '
        '${error.message}',
      );
      return null;
    }
  }

  /// Drives a full biometric unlock round-trip:
  ///   1. Asks the platform to open a BiometricPrompt.
  ///   2. The platform binds the prompt to the RSA private-key
  ///      `Cipher` via `BiometricPrompt.CryptoObject`.
  ///   3. On success, native code returns the unwrapped seed bytes.
  Future<Uint8List?> rsaDecryptSeedAuthorized(Uint8List ciphertext) async {
    if (!_isAndroid) return null;
    try {
      final plaintext = await _biometricChannel.invokeMethod<Uint8List>(
        'requestDecryptAuthorization',
        {'ciphertext': ciphertext},
      );
      return plaintext;
    } on PlatformException catch (error) {
      if (error.code == 'USER_CANCELLED') {
        return null;
      }
      rethrow;
    }
  }

  Uint8List _randomBytes(int length) {
    return Uint8List.fromList(
      List<int>.generate(length, (_) => _random.nextInt(256)),
    );
  }

  String _platformFailure(String prefix, PlatformException error) {
    final message = error.message;
    if (message == null || message.isEmpty) {
      return '$prefix:${error.code}';
    }
    return '$prefix:${error.code}:$message';
  }

  /// True when this failure means the stored envelope can never open again
  /// and must be wiped rather than retried.
  ///
  /// The reasoning is structural, not a string match on one exception
  /// class. Reaching here means `BiometricPrompt` already succeeded, so
  /// the private key authorized correctly: if `cipher.doFinal` then
  /// throws, the input is what is wrong. That holds for every decrypt
  /// failure, and it holds regardless of which exception the provider
  /// chose to raise.
  ///
  /// The previous check matched only `IllegalBlockSizeException` in the
  /// message. Under `RSA/ECB/OAEPWithSHA-256AndMGF1Padding` the common
  /// case for a corrupted or tampered ciphertext is `BadPaddingException`,
  /// which that check missed: the corrupt seed stayed on disk with a live
  /// alias and every later unlock attempt failed the same way, with no
  /// recovery path short of the user clearing app data.
  ///
  /// `BIOMETRIC_KEY_MISSING` and `BIOMETRIC_KEY_INVALIDATED` also wipe,
  /// because the stored ciphertext is encrypted to a key that no longer
  /// exists and re-enrolling cannot reuse it.
  bool _corruptsStoredEnvelope(PlatformException error) {
    return switch (error.code) {
      'BIOMETRIC_DECRYPT_FAILED' => true,
      'BIOMETRIC_KEY_MISSING' => true,
      'BIOMETRIC_KEY_INVALIDATED' => true,
      _ => false,
    };
  }

  /// Base64-encodes [encryptedSeed] for persistence. Test-only.
  @visibleForTesting
  static String encodeEncryptedSeedForStorage(Uint8List encryptedSeed) {
    return base64Encode(encryptedSeed);
  }

  /// Reverses [encodeEncryptedSeedForStorage]. Test-only.
  @visibleForTesting
  static Uint8List decodeEncryptedSeedFromStorage(String stored) {
    return Uint8List.fromList(base64Decode(stored));
  }
}
