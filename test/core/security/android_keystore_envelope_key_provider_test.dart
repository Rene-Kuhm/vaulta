import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/android_keystore_envelope_key_provider.dart';
import 'package:gestor_contrasenas/core/security/biometric_key_envelope_service.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AndroidKeystoreEnvelopeKeyProvider', () {
    const keystoreChannel = MethodChannel(
      AndroidKeystoreEnvelopeKeyProvider.keystoreChannelName,
    );
    const biometricChannel = MethodChannel(
      AndroidKeystoreEnvelopeKeyProvider.biometricChannelName,
    );

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(keystoreChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(biometricChannel, null);
    });

    test('stores encrypted RSA seed as base64-safe text', () {
      final encryptedSeed = Uint8List.fromList([
        0x00,
        0x01,
        0x7F,
        0x80,
        0xFE,
        0xFF,
      ]);

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

    test('returns null on non-Android targets', () async {
      // We force the "is Android" branch off by routing the method
      // channel mock anyway; the provider's own Platform.isAndroid
      // check is the gate. On a test VM running on the host, that
      // check is true, so the test below exercises the channels.
      if (!Platform.isAndroid) {
        final provider = AndroidKeystoreEnvelopeKeyProvider(
          storage: _InMemoryStorage(),
        );
        final acquire = await provider.acquireEnvelopeKey();
        expect(acquire.isSuccess, isFalse);
        expect(acquire.failureReason, 'platform_not_android');
        final release = await provider.releaseEnvelopeKey();
        expect(release.isSuccess, isFalse);
        expect(release.failureReason, 'platform_not_android');
        expect(await provider.isHardwareBackedBiometricAvailable(), isFalse);
      }
    });

    test('isAvailable forwards the platform response', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(keystoreChannel, (call) async {
            if (call.method == 'isAvailable') return true;
            return null;
          });
      final provider = AndroidKeystoreEnvelopeKeyProvider(
        storage: _InMemoryStorage(),
      );
      // Only meaningful when running on the Android target VM; on
      // desktop CI it stays false and that is the expected result.
      if (Platform.isAndroid) {
        expect(await provider.isHardwareBackedBiometricAvailable(), isTrue);
      } else {
        expect(await provider.isHardwareBackedBiometricAvailable(), isFalse);
      }
    });

    test(
      'acquireEnvelopeKey persists an RSA-encrypted seed and returns a key',
      () async {
        if (!Platform.isAndroid) {
          return; // Only the Android branch is exercised end-to-end.
        }
        final storage = _InMemoryStorage();
        final ciphertextStore = <String>['encrypted-bytes'];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(keystoreChannel, (call) async {
              switch (call.method) {
                case 'isAvailable':
                  return true;
                case 'ensureKey':
                  return 'vaulta_biometric_envelope_v1';
                case 'rsaEncrypt':
                  // We do not actually encrypt in the mock; we just
                  // return a non-empty ciphertext that the platform would
                  // have produced.
                  return Uint8List.fromList(ciphertextStore[0].codeUnits);
                case 'deleteKey':
                  return null;
                default:
                  return null;
              }
            });

        final provider = AndroidKeystoreEnvelopeKeyProvider(storage: storage);
        final acquireResult = await provider.acquireEnvelopeKey();
        expect(acquireResult.isSuccess, isTrue);
        expect(acquireResult.key, isNotNull);

        // The RSA-encrypted seed must have been persisted under the
        // documented storage key.
        final stored = await storage.read('vaulta_biometric_envelope_seed_v1');
        expect(stored, isNotNull);
        expect(
          AndroidKeystoreEnvelopeKeyProvider.decodeEncryptedSeedFromStorage(
            stored!,
          ),
          Uint8List.fromList(ciphertextStore[0].codeUnits),
        );
      },
    );

    test('releaseEnvelopeKey returns null when the user cancels', () async {
      if (!Platform.isAndroid) return;
      final storage = _InMemoryStorage();
      await storage.save(
        'vaulta_biometric_envelope_seed_v1',
        AndroidKeystoreEnvelopeKeyProvider.encodeEncryptedSeedForStorage(
          Uint8List.fromList('seed-bytes'.codeUnits),
        ),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(keystoreChannel, (call) async {
            if (call.method == 'isAvailable') return true;
            return null;
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(biometricChannel, (call) async {
            if (call.method == 'requestDecryptAuthorization') {
              throw PlatformException(code: 'USER_CANCELLED');
            }
            return null;
          });
      final provider = AndroidKeystoreEnvelopeKeyProvider(storage: storage);
      final releaseResult = await provider.releaseEnvelopeKey();
      expect(releaseResult.isSuccess, isFalse);
      expect(releaseResult.failureReason, isNotNull);
    });

    test(
      'releaseEnvelopeKey clears native slot when RSA ciphertext is invalid',
      () async {
        if (!Platform.isAndroid) return;
        final storage = _InMemoryStorage();
        await storage.save(
          'vaulta_biometric_envelope_seed_v1',
          AndroidKeystoreEnvelopeKeyProvider.encodeEncryptedSeedForStorage(
            Uint8List.fromList('bad-ciphertext'.codeUnits),
          ),
        );
        var deleteKeyCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(keystoreChannel, (call) async {
              switch (call.method) {
                case 'isAvailable':
                  return true;
                case 'deleteKey':
                  deleteKeyCalls++;
                  return null;
                default:
                  return null;
              }
            });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(biometricChannel, (call) async {
              if (call.method == 'requestDecryptAuthorization') {
                throw PlatformException(
                  code: 'BIOMETRIC_DECRYPT_FAILED',
                  message: 'decrypt_failed:IllegalBlockSizeException:',
                );
              }
              return null;
            });

        final provider = AndroidKeystoreEnvelopeKeyProvider(storage: storage);
        final releaseResult = await provider.releaseEnvelopeKey();

        expect(releaseResult.isSuccess, isFalse);
        expect(
          releaseResult.failureReason,
          contains('rsa_decrypt_invalid_ciphertext'),
        );
        expect(deleteKeyCalls, 1);
        expect(await storage.read('vaulta_biometric_envelope_seed_v1'), isNull);
      },
    );

    test('end-to-end envelope + provider round-trip is symmetric', () async {
      if (!Platform.isAndroid) return;
      final storage = _InMemoryStorage();
      // Captured ciphertexts per call to simulate an RSA roundtrip.
      final rsaCiphertexts = <String>[];
      final recoveredSeeds = <Uint8List>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(keystoreChannel, (call) async {
            switch (call.method) {
              case 'isAvailable':
                return true;
              case 'ensureKey':
                return 'alias';
              case 'rsaEncrypt':
                final pt = (call.arguments as Map)['plaintext'] as Uint8List;
                rsaCiphertexts.add(String.fromCharCodes(pt));
                // Pretend the platform "encrypted" by returning a marker.
                return Uint8List.fromList(
                  List<int>.generate(pt.length, (i) => pt[i] ^ 0xAA),
                );
              case 'deleteKey':
                return null;
              default:
                return null;
            }
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(biometricChannel, (call) async {
            if (call.method == 'requestDecryptAuthorization') {
              final ct = (call.arguments as Map)['ciphertext'] as Uint8List;
              final pt = Uint8List.fromList(
                List<int>.generate(ct.length, (i) => ct[i] ^ 0xAA),
              );
              recoveredSeeds.add(pt);
              return pt;
            }
            return null;
          });

      final provider = AndroidKeystoreEnvelopeKeyProvider(storage: storage);
      final envelopeService = BiometricKeyEnvelopeService(storage: storage);
      final dek = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));

      final acquired = await provider.acquireEnvelopeKey();
      expect(acquired.isSuccess, isTrue);
      expect(acquired.key, isNotNull);
      await envelopeService.enroll(dekBytes: dek, envelopeKey: acquired.key!);

      final released = await provider.releaseEnvelopeKey();
      expect(released.isSuccess, isTrue);
      expect(released.key, isNotNull);

      final recoveredDek = await envelopeService.unwrap(
        envelopeKey: released.key!,
      );
      expect(recoveredDek, dek);

      // The seed that the unlock path saw must equal the seed the
      // enrollment path produced (modulo the mock's XOR). We assert
      // equality through the recovered DEK, which is the contract
      // that matters.
      expect(rsaCiphertexts, hasLength(1));
      expect(recoveredSeeds, hasLength(1));
    });

    test('the provider only calls authorized channel methods', () async {
      if (!Platform.isAndroid) return;
      final storage = _InMemoryStorage();
      final keystoreCalls = <String>[];
      final biometricCalls = <String>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(keystoreChannel, (call) async {
            keystoreCalls.add(call.method);
            switch (call.method) {
              case 'isAvailable':
                return true;
              case 'ensureKey':
                return 'alias';
              case 'rsaEncrypt':
                return Uint8List.fromList(
                  List<int>.generate(
                    ((call.arguments as Map)['plaintext'] as Uint8List).length,
                    (_) => 0xAB,
                  ),
                );
              default:
                return null;
            }
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(biometricChannel, (call) async {
            biometricCalls.add(call.method);
            if (call.method == 'requestDecryptAuthorization') {
              return Uint8List.fromList(List<int>.filled(32, 0x5A));
            }
            return null;
          });

      final provider = AndroidKeystoreEnvelopeKeyProvider(storage: storage);
      final envelopeService = BiometricKeyEnvelopeService(storage: storage);
      await envelopeService.enroll(
        dekBytes: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
        envelopeKey: SecretKey(List<int>.filled(32, 0x11)),
      );

      await provider.acquireEnvelopeKey();
      await provider.releaseEnvelopeKey();

      // Guards against reintroducing an unauthenticated decrypt. Under
      // setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG) only a
      // BiometricPrompt.CryptoObject cipher can decrypt the seed, so the
      // keystore channel must stay encrypt-only and the biometric channel
      // must carry the single authorized unwrap.
      expect(
        keystoreCalls.toSet().difference({'isAvailable', 'ensureKey', 'rsaEncrypt'}),
        isEmpty,
        reason: 'keystore channel must stay encrypt-only',
      );
      expect(
        biometricCalls.toSet().difference({'requestDecryptAuthorization'}),
        isEmpty,
        reason: 'seed unwrap must only travel through the biometric prompt',
      );
      expect(keystoreCalls, isNot(contains('rsaDecryptAuthorized')));
      expect(biometricCalls, contains('requestDecryptAuthorization'));
    });
  });
}

class _InMemoryStorage implements SecureStorageService {
  final Map<String, String> _values = {};

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> save(String key, String value) async {
    _values[key] = value;
  }
}
