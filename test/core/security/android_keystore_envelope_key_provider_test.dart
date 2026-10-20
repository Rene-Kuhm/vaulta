// Coverage for the Android KeyStore envelope provider.
//
// Every test in this file runs on the host. The provider takes an
// `isAndroid` seam (defaulting to `Platform.isAndroid`) so the real
// Dart-side logic executes on Linux with a fake MethodChannel standing
// in for the AndroidKeyStore + BiometricPrompt side. Nothing here may
// branch on the host platform: a test that quietly returns on a
// non-Android host is what left the most security-sensitive code in the
// app with zero coverage.

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/android_keystore_envelope_key_provider.dart';
import 'package:gestor_contrasenas/core/security/biometric_key_envelope_service.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';

/// Storage key the provider persists the RSA-encrypted seed under.
/// Mirrors `AndroidKeystoreEnvelopeKeyProvider._encryptedSeedKey`, which
/// is private; the tests below pin that the provider keeps using it.
const _seedStorageKey = 'vaulta_biometric_envelope_seed_v1';

/// Size of an RSA-2048 modulus block, which is what `rsaEncrypt`
/// returns for any seed shorter than the OAEP limit.
const _modulusBytes = 256;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const keystoreChannel = MethodChannel(
    AndroidKeystoreEnvelopeKeyProvider.keystoreChannelName,
  );
  const biometricChannel = MethodChannel(
    AndroidKeystoreEnvelopeKeyProvider.biometricChannelName,
  );

  late _FakeAndroidPlatform platform;

  setUp(() {
    platform = _FakeAndroidPlatform();
    platform.install(keystoreChannel, biometricChannel);
  });

  tearDown(() {
    platform.uninstall(keystoreChannel, biometricChannel);
  });

  group('AndroidKeystoreEnvelopeKeyProvider', () {
    test('the seed released at unlock is the seed enrolled', () async {
      final storage = _SpyStorage();
      final provider = _androidProvider(storage);

      final acquired = await provider.acquireEnvelopeKey();
      expect(acquired.isSuccess, isTrue, reason: acquired.failureReason ?? '');
      expect(acquired.key, isNotNull);
      final enrolledSeed = await acquired.key!.extractBytes();

      // Enrollment wraps the DEK under the acquired key...
      final envelopeService = BiometricKeyEnvelopeService(storage: storage);
      final dek = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      await envelopeService.enroll(dekBytes: dek, envelopeKey: acquired.key!);

      // ...and unlock must recover the *same* seed, not merely a seed.
      final released = await provider.releaseEnvelopeKey();
      expect(released.isSuccess, isTrue, reason: released.failureReason ?? '');
      expect(await released.key!.extractBytes(), enrolledSeed);

      // The symmetric round trip is the contract that protects the DEK:
      // the same envelope key must unwrap the same DEK.
      expect(
        await envelopeService.unwrap(envelopeKey: released.key!),
        dek,
      );

      // Enrollment rebuilds the alias and never prompts; only the unlock
      // half may open a BiometricPrompt.
      expect(platform.keystoreCalls, [
        'isAvailable',
        'deleteKey',
        'ensureKey',
        'rsaEncrypt',
        'isAvailable',
      ]);
      expect(platform.biometricCalls, ['requestDecryptAuthorization']);
      expect(platform.plaintextSeeds, hasLength(1));
      expect(platform.plaintextSeeds.single, enrolledSeed);
      expect(platform.encryptedSeeds.single, hasLength(_modulusBytes));
    });

    test('enrollment persists only the RSA-encrypted seed', () async {
      final storage = _SpyStorage();
      final provider = _androidProvider(storage);

      final acquired = await provider.acquireEnvelopeKey();
      expect(acquired.isSuccess, isTrue, reason: acquired.failureReason ?? '');

      final seed = await acquired.key!.extractBytes();
      final ciphertext = platform.encryptedSeeds.single;
      final stored = await storage.read(_seedStorageKey);

      expect(ciphertext, hasLength(_modulusBytes));
      expect(ciphertext, isNot(equals(seed)));

      expect(stored, isNotNull);
      expect(
        AndroidKeystoreEnvelopeKeyProvider.decodeEncryptedSeedFromStorage(
          stored!,
        ),
        ciphertext,
        reason: 'the platform ciphertext must be persisted unmodified',
      );

      // The plaintext seed must exist nowhere in persisted state: not as
      // the value, and not as a substring of any value.
      expect(stored.contains(base64Encode(seed)), isFalse);
      expect(
        storage.writtenValues.any((v) => v.contains(base64Encode(seed))),
        isFalse,
      );
      expect(
        storage.writes.map((write) => write.key).toSet(),
        {_seedStorageKey},
        reason: 'enrollment must not scatter seed material under other keys',
      );
    });

    test('re-enrollment produces a fresh seed and overwrites the envelope', () async {
      final storage = _SpyStorage();
      final provider = _androidProvider(storage);

      final first = await provider.acquireEnvelopeKey();
      final firstStored = await storage.read(_seedStorageKey);
      final second = await provider.acquireEnvelopeKey();
      final secondStored = await storage.read(_seedStorageKey);

      expect(first.isSuccess && second.isSuccess, isTrue);
      expect(
        await first.key!.extractBytes(),
        isNot(await second.key!.extractBytes()),
      );
      expect(secondStored, isNot(firstStored));
      expect(platform.encryptedSeeds, hasLength(2));
      // Enrollment always rebuilds the alias before encrypting.
      expect(
        platform.keystoreCalls.where((method) => method == 'deleteKey'),
        hasLength(2),
      );
    });

    test('no hardware-backed biometric: unavailable, nothing persisted', () async {
      platform.available = false;
      final storage = _SpyStorage();
      final provider = _androidProvider(storage);

      final acquired = await provider.acquireEnvelopeKey();
      expect(acquired.isSuccess, isFalse);
      expect(acquired.key, isNull);
      expect(
        acquired.failureReason,
        'platform_no_hardware_backed_biometric',
      );

      final released = await provider.releaseEnvelopeKey();
      expect(released.isSuccess, isFalse);
      expect(
        released.failureReason,
        'platform_no_hardware_backed_biometric',
      );

      // Nothing was generated and nothing was written.
      expect(platform.keystoreCalls, ['isAvailable', 'isAvailable']);
      expect(platform.biometricCalls, isEmpty);
      expect(platform.encryptedSeeds, isEmpty);
      expect(storage.writes, isEmpty);
      expect(await storage.read(_seedStorageKey), isNull);
      expect(await provider.isHardwareBackedBiometricAvailable(), isFalse);
    });

    test('no hardware-backed biometric: an enrolled envelope is left intact', () async {
      // Hardware can become temporarily unavailable. Losing the ciphertext
      // would force a full re-enrollment for something the user cannot
      // act on, and the OS invalidates the KeyStore alias on its own when
      // biometric enrollment changes.
      final storage = _SpyStorage();
      await storage.save(_seedStorageKey, 'pre-existing-ciphertext');
      final provider = _androidProvider(storage);
      platform.available = false;

      final released = await provider.releaseEnvelopeKey();

      expect(released.isSuccess, isFalse);
      expect(
        released.failureReason,
        'platform_no_hardware_backed_biometric',
      );
      expect(platform.biometricCalls, isEmpty);
      expect(platform.keystoreCalls, ['isAvailable']);
      expect(
        await storage.read(_seedStorageKey),
        'pre-existing-ciphertext',
        reason: 'a capability loss must not destroy the envelope',
      );
    });

    test('a Keystore failure during enrollment is structured and inert', () async {
      platform.ensureKeyError = PlatformException(
        code: 'KEYSTORE',
        message: 'KeyStore unavailable',
      );
      final storage = _SpyStorage();
      final provider = _androidProvider(storage);

      final acquired = await provider.acquireEnvelopeKey();

      expect(acquired.isSuccess, isFalse);
      expect(acquired.key, isNull);
      expect(acquired.failureReason, 'ensure_key_failed:KEYSTORE');
      // "Leaves nothing behind": no key was kept and nothing written.
      expect(platform.keystoreCalls, ['isAvailable', 'deleteKey', 'ensureKey']);
      expect(platform.encryptedSeeds, isEmpty);
      expect(storage.writes, isEmpty);
      expect(await storage.read(_seedStorageKey), isNull);
    });

    test('a storage failure inside the enrollment wipe is reported', () async {
      // deleteKey() runs before ensureKey() so the alias is rebuilt; a
      // secure-storage failure there is not a PlatformException and must
      // still surface as a structured reason instead of escaping.
      final storage = _SpyStorage()..failDeletes = true;
      final provider = _androidProvider(storage);

      final acquired = await provider.acquireEnvelopeKey();

      expect(acquired.isSuccess, isFalse);
      expect(acquired.key, isNull);
      expect(acquired.failureReason, 'ensure_key_unexpected:StateError');
      expect(platform.keystoreCalls, ['isAvailable', 'deleteKey']);
      expect(platform.encryptedSeeds, isEmpty);
    });

    test('rsaEncrypt returning null persists nothing', () async {
      platform.encryptReturnsNull = true;
      final storage = _SpyStorage();
      final provider = _androidProvider(storage);

      final acquired = await provider.acquireEnvelopeKey();

      expect(acquired.isSuccess, isFalse);
      expect(acquired.failureReason, 'rsa_encrypt_returned_null');
      expect(platform.keystoreCalls, contains('rsaEncrypt'));
      expect(platform.encryptedSeeds, isEmpty);
      expect(await storage.read(_seedStorageKey), isNull);
    });

    test('a storage failure while persisting the ciphertext is reported', () async {
      final storage = _SpyStorage()..failSaves = true;
      final provider = _androidProvider(storage);

      final acquired = await provider.acquireEnvelopeKey();

      expect(acquired.isSuccess, isFalse);
      expect(
        acquired.failureReason,
        startsWith('persist_encrypted_seed_failed:'),
      );
      // The caller must not be handed a key it could never re-obtain.
      expect(acquired.key, isNull);
      expect(await storage.read(_seedStorageKey), isNull);
    });

    test('a user cancellation is unavailable, not an escaping exception', () async {
      final storage = _SpyStorage();
      await storage.save(_seedStorageKey, base64Encode([1, 2, 3, 4]));
      final provider = _androidProvider(storage);
      platform.userCancels = true;

      final released = await provider.releaseEnvelopeKey();

      expect(released.isSuccess, isFalse);
      expect(released.key, isNull);
      expect(released.failureReason, 'rsa_decrypt_returned_null');
      expect(platform.biometricCalls, ['requestDecryptAuthorization']);
      // A cancellation is not a corruption: the envelope stays put.
      expect(platform.keystoreCalls, ['isAvailable']);
      expect(await storage.read(_seedStorageKey), isNotNull);
    });

    test('an unauthorized decrypt returns a structured reason', () async {
      final storage = _SpyStorage();
      await storage.save(
        _seedStorageKey,
        base64Encode(Uint8List(_modulusBytes)),
      );
      final provider = _androidProvider(storage);
      platform.decryptError = PlatformException(
        code: 'BIOMETRIC_LOCKOUT_PERMANENT',
        message: 'Too many attempts',
      );

      final released = await provider.releaseEnvelopeKey();

      expect(released.isSuccess, isFalse);
      expect(
        released.failureReason,
        'rsa_decrypt_failed:BIOMETRIC_LOCKOUT_PERMANENT:Too many attempts',
      );
      // A lockout is transient, so the envelope survives.
      expect(await storage.read(_seedStorageKey), isNotNull);
    });

    test('a ciphertext the private key rejects wipes key and seed', () async {
      final storage = _SpyStorage();
      await storage.save(
        _seedStorageKey,
        base64Encode(Uint8List(_modulusBytes)),
      );
      final provider = _androidProvider(storage);
      // BadPaddingException is the *common* case for a corrupted or
      // tampered OAEP ciphertext, and the case the previous
      // IllegalBlockSizeException-only check missed: the seed survived on
      // disk with a live alias and every later attempt failed the same way.
      platform.decryptError = PlatformException(
        code: 'BIOMETRIC_DECRYPT_FAILED',
        message: 'decrypt_failed:BadPaddingException:Message does not look '
            'like a valid ciphertext',
      );

      final released = await provider.releaseEnvelopeKey();

      expect(released.isSuccess, isFalse);
      expect(
        released.failureReason,
        contains('rsa_decrypt_invalid_ciphertext'),
      );
      expect(platform.keystoreCalls, ['isAvailable', 'deleteKey']);
      expect(await storage.read(_seedStorageKey), isNull);
    });

    test('any decrypt failure wipes, regardless of the exception class',
        () async {
      // The prompt already succeeded when doFinal throws, so the key is
      // fine and the input is what is wrong. That is a structural
      // argument, so it must not depend on which class the provider chose
      // to raise.
      for (final message in [
        'decrypt_failed:BadPaddingException:',
        'decrypt_failed:IllegalBlockSizeException:',
        'decrypt_failed:SomeFutureException:message RSA may not be safely '
            'used, consider using another key',
        'decrypt_failed:',
      ]) {
        final storage = _SpyStorage();
        await storage.save(
          _seedStorageKey,
          base64Encode(Uint8List(_modulusBytes)),
        );
        final provider = _androidProvider(storage);
        platform.decryptError = PlatformException(
          code: 'BIOMETRIC_DECRYPT_FAILED',
          message: message,
        );

        final released = await provider.releaseEnvelopeKey();

        expect(
          released.failureReason,
          contains('rsa_decrypt_invalid_ciphertext'),
          reason: 'must wipe for: $message',
        );
        expect(
          await storage.read(_seedStorageKey),
          isNull,
          reason: 'seed must be gone for: $message',
        );
      }
    });

    test('a missing or invalidated KeyStore alias also wipes the seed',
        () async {
      // The stored ciphertext is encrypted to a key that no longer exists.
      // Keeping it means re-enrolling can never succeed and the user has
      // no path back except clearing app data.
      for (final code in [
        'BIOMETRIC_KEY_MISSING',
        'BIOMETRIC_KEY_INVALIDATED',
      ]) {
        final storage = _SpyStorage();
        await storage.save(
          _seedStorageKey,
          base64Encode(Uint8List(_modulusBytes)),
        );
        final provider = _androidProvider(storage);
        platform.decryptError = PlatformException(code: code);

        final released = await provider.releaseEnvelopeKey();

        expect(
          released.failureReason,
          contains('rsa_decrypt_invalid_ciphertext'),
          reason: 'must wipe for $code',
        );
        expect(
          await storage.read(_seedStorageKey),
          isNull,
          reason: 'seed must be gone for $code',
        );
      }
    });

    test('a stored seed that is not valid base64 is refused and wiped', () async {
      final storage = _SpyStorage();
      await storage.save(_seedStorageKey, 'not!valid!base64');
      final provider = _androidProvider(storage);

      final released = await provider.releaseEnvelopeKey();

      expect(released.isSuccess, isFalse);
      expect(released.key, isNull);
      expect(released.failureReason, 'encrypted_seed_not_base64');
      // Refused means the platform key is gone too, not just the blob.
      expect(platform.keystoreCalls, ['isAvailable', 'deleteKey']);
      expect(platform.biometricCalls, isEmpty);
      expect(await storage.read(_seedStorageKey), isNull);
    });

    test('release with no envelope on disk does not prompt', () async {
      final provider = _androidProvider(_SpyStorage());

      final released = await provider.releaseEnvelopeKey();

      expect(released.isSuccess, isFalse);
      expect(released.failureReason, 'no_encrypted_seed_on_disk');
      expect(platform.biometricCalls, isEmpty);
      expect(platform.keystoreCalls, ['isAvailable']);
    });

    test('deleteKey clears both halves and is idempotent', () async {
      final storage = _SpyStorage();
      await storage.save(_seedStorageKey, 'ciphertext');
      final provider = _androidProvider(storage);

      await provider.deleteKey();
      expect(platform.keystoreCalls, ['deleteKey']);
      expect(await storage.read(_seedStorageKey), isNull);

      await provider.deleteKey();
      await provider.deleteKey();
      expect(
        platform.keystoreCalls,
        ['deleteKey', 'deleteKey', 'deleteKey'],
      );
      expect(await storage.read(_seedStorageKey), isNull);

      // After the wipe the unlock half has nothing left to release.
      final released = await provider.releaseEnvelopeKey();
      expect(released.failureReason, 'no_encrypted_seed_on_disk');
    });

    test('deleteKey clears the seed even when the platform throws', () async {
      final storage = _SpyStorage();
      await storage.save(_seedStorageKey, 'ciphertext');
      final provider = _androidProvider(storage);
      platform.deleteKeyError =
          PlatformException(code: 'KEYSTORE', message: 'no alias');

      await provider.deleteKey();

      expect(platform.keystoreCalls, ['deleteKey']);
      expect(
        await storage.read(_seedStorageKey),
        isNull,
        reason: 'a platform failure must not strand the encrypted seed',
      );
    });

    test('only authorized keystore methods are ever called', () async {
      final storage = _SpyStorage();
      final provider = _androidProvider(storage);

      await provider.acquireEnvelopeKey();
      await provider.releaseEnvelopeKey();
      await provider.deleteKey();
      await provider.ensureKey();
      await provider.rsaEncryptSeed(Uint8List(32));
      await provider.isHardwareBackedBiometricAvailable();

      // The low-level helper rethrows anything that is not a cancellation;
      // releaseEnvelopeKey is the layer that turns it into a reason.
      await expectLater(
        provider.rsaDecryptSeedAuthorized(Uint8List(32)),
        throwsA(isA<PlatformException>()),
      );

      // Guards against reintroducing an unauthenticated decrypt. Under
      // setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG) only a
      // BiometricPrompt.CryptoObject cipher can decrypt the seed, so the
      // keystore channel must stay encrypt-only and the biometric channel
      // must carry the single authorized unwrap.
      const authorizedKeystore = {
        'isAvailable',
        'ensureKey',
        'rsaEncrypt',
        'deleteKey',
      };
      const authorizedBiometric = {'requestDecryptAuthorization'};

      expect(
        platform.keystoreCalls.toSet().difference(authorizedKeystore),
        isEmpty,
        reason: 'keystore channel must stay encrypt-only',
      );
      expect(
        platform.biometricCalls.toSet().difference(authorizedBiometric),
        isEmpty,
        reason: 'seed unwrap must only travel through the biometric prompt',
      );
      expect(platform.keystoreCalls, isNot(contains('rsaDecryptAuthorized')));
      expect(platform.keystoreCalls, isNot(contains('rsaDecrypt')));
      expect(platform.biometricCalls, contains('requestDecryptAuthorization'));
    });

    test('isAvailable forwards the platform answer', () async {
      final provider = _androidProvider(_SpyStorage());

      expect(await provider.isHardwareBackedBiometricAvailable(), isTrue);
      expect(platform.keystoreCalls, ['isAvailable']);

      platform.available = false;
      expect(await provider.isHardwareBackedBiometricAvailable(), isFalse);
    });

    test('isAvailable treats a platform failure as unavailable', () async {
      platform.availableError = PlatformException(code: 'KEYSTORE');
      final provider = _androidProvider(_SpyStorage());

      expect(await provider.isHardwareBackedBiometricAvailable(), isFalse);
    });

    test('stores encrypted RSA seed as base64-safe text', () {
      final encryptedSeed =
          Uint8List.fromList([0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF]);

      final stored =
          AndroidKeystoreEnvelopeKeyProvider.encodeEncryptedSeedForStorage(
        encryptedSeed,
      );

      expect(stored, isNot(String.fromCharCodes(encryptedSeed)));
      expect(
        AndroidKeystoreEnvelopeKeyProvider.decodeEncryptedSeedFromStorage(
          stored,
        ),
        encryptedSeed,
      );
    });
  });

  // The production gate must survive the seam: on a real non-Android
  // target the provider is inert and touches neither channel nor storage.
  group('AndroidKeystoreEnvelopeKeyProvider on a non-Android platform', () {
    test('every gated entry point is inert', () async {
      final storage = _SpyStorage();
      await storage.save(_seedStorageKey, 'untouched');
      storage.writes.clear();
      final provider = AndroidKeystoreEnvelopeKeyProvider(
        storage: storage,
        isAndroid: false,
      );

      final acquire = await provider.acquireEnvelopeKey();
      final release = await provider.releaseEnvelopeKey();

      expect(acquire.isSuccess, isFalse);
      expect(acquire.key, isNull);
      expect(acquire.failureReason, 'platform_not_android');
      expect(release.isSuccess, isFalse);
      expect(release.key, isNull);
      expect(release.failureReason, 'platform_not_android');
      expect(await provider.isHardwareBackedBiometricAvailable(), isFalse);
      expect(await provider.rsaEncryptSeed(Uint8List(32)), isNull);
      expect(await provider.rsaDecryptSeedAuthorized(Uint8List(4)), isNull);
      await provider.deleteKey();

      expect(platform.keystoreCalls, isEmpty);
      expect(platform.biometricCalls, isEmpty);
      expect(storage.writes, isEmpty);
      expect(storage.deletes, isEmpty);
      expect(
        await storage.read(_seedStorageKey),
        'untouched',
        reason: 'the platform gate must not wipe storage on desktop/web',
      );
    });

    test('ensureKey is gated by its callers, not by itself', () async {
      // ensureKey() carries no platform check of its own; in production it
      // is only reachable from the gated acquire path. Pinned here so
      // adding or removing that gate is a deliberate, reviewed change.
      final provider = AndroidKeystoreEnvelopeKeyProvider(
        storage: _SpyStorage(),
        isAndroid: false,
      );

      expect(await provider.ensureKey(), 'vaulta_biometric_envelope_v1');
      expect(platform.keystoreCalls, ['ensureKey']);
    });
  });
}

/// Builds a provider whose platform gate is open, i.e. one that behaves
/// exactly as it does on a real Android device.
AndroidKeystoreEnvelopeKeyProvider _androidProvider(
  SecureStorageService storage,
) {
  return AndroidKeystoreEnvelopeKeyProvider(
    storage: storage,
    isAndroid: true,
  );
}

/// Stands in for the AndroidKeyStore + BiometricPrompt side of the app.
///
/// It models the three properties the Dart code actually depends on:
///   * `rsaEncrypt` is keyed and length-changing (RSA-2048/OAEP always
///     returns a full modulus block), so a test can tell a real
///     ciphertext from a plaintext seed;
///   * the private-key half is only reachable through the biometric
///     channel, exactly like `MainActivity.authenticateAndDecrypt`;
///   * every method name is recorded, so the authorized-surface contract
///     is asserted rather than assumed.
///
/// The failure knobs let a test inject the exact platform rejections the
/// production code maps onto structured reasons.
class _FakeAndroidPlatform {
  /// Whether `isAvailable` reports a hardware-backed biometric.
  bool available = true;

  /// Thrown by `isAvailable` instead of answering, when set.
  PlatformException? availableError;

  /// Thrown by `ensureKey`, when set.
  PlatformException? ensureKeyError;

  /// Thrown by `deleteKey`, when set.
  PlatformException? deleteKeyError;

  /// Makes `rsaEncrypt` answer `null` (a platform that refuses to wrap).
  bool encryptReturnsNull = false;

  /// Thrown by `requestDecryptAuthorization` for a user cancellation.
  bool userCancels = false;

  /// Thrown by `requestDecryptAuthorization` on any other rejection.
  PlatformException? decryptError;

  /// Method names seen on each channel, in call order.
  final List<String> keystoreCalls = <String>[];
  final List<String> biometricCalls = <String>[];

  /// Ciphertexts `rsaEncrypt` handed back to Dart.
  final List<Uint8List> encryptedSeeds = <Uint8List>[];

  /// Plaintext seeds handed to `rsaEncrypt`.
  final List<Uint8List> plaintextSeeds = <Uint8List>[];

  /// The "private key": only ciphertexts it produced can be unwrapped.
  final Map<String, Uint8List> _privateKey = <String, Uint8List>{};

  void install(MethodChannel keystore, MethodChannel biometric) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(keystore, _handleKeystore);
    messenger.setMockMethodCallHandler(biometric, _handleBiometric);
  }

  void uninstall(MethodChannel keystore, MethodChannel biometric) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(keystore, null);
    messenger.setMockMethodCallHandler(biometric, null);
  }

  Future<Object?> _handleKeystore(MethodCall call) async {
    keystoreCalls.add(call.method);
    switch (call.method) {
      case 'isAvailable':
        final error = availableError;
        if (error != null) throw error;
        return available;
      case 'ensureKey':
        final error = ensureKeyError;
        if (error != null) throw error;
        return 'vaulta_biometric_envelope_v1';
      case 'rsaEncrypt':
        if (encryptReturnsNull) return null;
        return _encrypt(_plaintextArgument(call));
      case 'deleteKey':
        final error = deleteKeyError;
        if (error != null) throw error;
        _privateKey.clear();
        return null;
      default:
        // The real KeystoreChannel answers notImplemented() for anything
        // outside its surface: there is no decrypt method there at all.
        throw MissingPluginException('no handler for ${call.method}');
    }
  }

  Future<Object?> _handleBiometric(MethodCall call) async {
    biometricCalls.add(call.method);
    if (call.method != 'requestDecryptAuthorization') {
      throw MissingPluginException('no handler for ${call.method}');
    }
    if (userCancels) {
      throw PlatformException(code: 'USER_CANCELLED', message: 'cancelled');
    }
    final error = decryptError;
    if (error != null) throw error;
    return _decrypt(_ciphertextArgument(call));
  }

  Uint8List _plaintextArgument(MethodCall call) {
    final arguments = call.arguments as Map<Object?, Object?>;
    return arguments['plaintext']! as Uint8List;
  }

  Uint8List _ciphertextArgument(MethodCall call) {
    final arguments = call.arguments as Map<Object?, Object?>;
    return arguments['ciphertext']! as Uint8List;
  }

  /// Keyed, length-changing, invertible transform standing in for
  /// RSA-OAEP: the plaintext is XORed with an alias-derived keystream and
  /// padded out to a full modulus block.
  Future<Uint8List> _encrypt(Uint8List plaintext) async {
    final keystream = await _keystream(_modulusBytes);
    final out = Uint8List(_modulusBytes);
    for (var i = 0; i < _modulusBytes; i++) {
      out[i] = keystream[i] ^ (i < plaintext.length ? plaintext[i] : 0);
    }
    _privateKey[base64Encode(out)] = plaintext;
    plaintextSeeds.add(Uint8List.fromList(plaintext));
    encryptedSeeds.add(Uint8List.fromList(out));
    return out;
  }

  /// Mirrors `Cipher.doFinal` behind a `BiometricPrompt.CryptoObject`:
  /// anything the public half did not produce is rejected.
  Uint8List _decrypt(Uint8List ciphertext) {
    final plaintext = _privateKey[base64Encode(ciphertext)];
    if (plaintext == null) {
      throw PlatformException(
        code: 'BIOMETRIC_DECRYPT_FAILED',
        message: 'decrypt_failed:BadPaddingException:Decryption error',
      );
    }
    return Uint8List.fromList(plaintext);
  }

  Future<Uint8List> _keystream(int length) async {
    final hmac = Hmac.sha256();
    final key = SecretKeyData(List<int>.generate(32, (i) => i * 7 + 1));
    final blocks = <int>[];
    for (var counter = 0; blocks.length < length; counter++) {
      final mac = await hmac.calculateMac(
        List<int>.filled(32, counter),
        secretKey: key,
      );
      blocks.addAll(mac.bytes);
    }
    return Uint8List.fromList(blocks.sublist(0, length));
  }
}

/// In-memory [SecureStorageService] that records every mutation so tests
/// can assert what enrollment did and did not persist, and can simulate an
/// unavailable keystore.
class _SpyStorage implements SecureStorageService {
  final Map<String, String> _values = <String, String>{};

  /// Every `save` call, in order.
  final List<_Write> writes = <_Write>[];

  /// Keys passed to `delete`, in order.
  final List<String> deletes = <String>[];

  /// Values handed to `save`, in order.
  List<String> get writtenValues =>
      writes.map((write) => write.value).toList(growable: false);

  /// When true, `save` throws instead of persisting.
  bool failSaves = false;

  /// When true, `delete` throws instead of removing anything.
  bool failDeletes = false;

  @override
  Future<void> delete(String key) async {
    deletes.add(key);
    if (failDeletes) {
      throw StateError('secure storage unavailable');
    }
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> save(String key, String value) async {
    writes.add(_Write(key, value));
    if (failSaves) {
      throw StateError('secure storage unavailable');
    }
    _values[key] = value;
  }
}

/// One recorded `save`.
class _Write {
  const _Write(this.key, this.value);

  final String key;
  final String value;
}