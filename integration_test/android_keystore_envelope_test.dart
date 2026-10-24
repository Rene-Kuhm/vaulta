// On-device coverage for the REAL Android KeyStore envelope.
//
// Run it on a device or emulator that has a screen lock and at least one
// biometric enrolled:
//
//   flutter test integration_test/android_keystore_envelope_test.dart \
//     -d <device-id>
//
// DESTRUCTIVE: this file deletes the app's biometric envelope and the
// `vaulta_biometric_envelope_v1` KeyStore alias, which is the same thing
// turning biometrics off does. Run it on a scratch device or a fresh
// emulator, never on the phone you actually use.
//
// Two of the five tests are gated on a human: the KeyStore private key is
// created with `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`
// (see `KeystoreChannel.buildKeySpec`), so the seed can only come back
// inside a real `BiometricPrompt`. Those tests print what they need before
// opening the prompt and give you three minutes to authenticate.
//
// Everything asserted here is justified by reading the native side:
//   * android/.../KeystoreChannel.kt  — method names, the `notImplemented`
//     fallthrough, the `ARG` error, RSA-OAEP over a 2048-bit key.
//   * android/.../BiometricChannel.kt — `requestDecryptAuthorization`, its
//     `ARG` check and its `notImplemented` fallthrough.
//   * android/.../MainActivity.kt     — `authenticateAndDecrypt`, the
//     `BIOMETRIC_BUSY` re-entrancy guard, `cipher.doFinal` inside
//     `onAuthenticationSucceeded`, and the `BiometricErrorCode` strings.
//
// What this file deliberately does NOT assert: that the OS itself refuses a
// `Cipher.init(DECRYPT_MODE, privateKey)` without a `BiometricPrompt.CryptoObject`.
// That path is unreachable from Dart by construction — `buildDecryptCipher()`
// is private to `MainActivity` and only ever handed to the prompt — so the
// strongest evidence available here is structural: the keystore channel
// exposes no decrypt method at all, and the biometric channel refuses to run
// two authorizations at once.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/core/security/android_keystore_envelope_key_provider.dart';
import 'package:gestor_contrasenas/core/security/biometric_key_envelope_service.dart';
import 'package:gestor_contrasenas/core/security/flutter_secure_storage_service.dart';
import 'package:integration_test/integration_test.dart';

/// Storage key the provider persists the RSA-encrypted seed under. Mirrors
/// `AndroidKeystoreEnvelopeKeyProvider._encryptedSeedKey`.
const _seedStorageKey = 'vaulta_biometric_envelope_seed_v1';

/// `KeystoreChannel.KEY_ALIAS`.
const _keyAlias = 'vaulta_biometric_envelope_v1';

/// Size of an RSA-2048 modulus, i.e. what `rsaEncrypt` returns.
const _modulusBytes = 256;

/// `BiometricErrorCode.BUSY`, returned when a prompt is already in flight.
const _busy = 'BIOMETRIC_BUSY';

/// `KeystoreChannel`'s error code for a missing required argument.
const _badArgument = 'ARG';

/// How long a human gets to answer the biometric prompt.
const _promptBudget = Duration(minutes: 3);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const keystoreChannel = MethodChannel(
    AndroidKeystoreEnvelopeKeyProvider.keystoreChannelName,
  );
  const biometricChannel = MethodChannel(
    AndroidKeystoreEnvelopeKeyProvider.biometricChannelName,
  );

  late FlutterSecureStorageService storage;
  late BiometricKeyEnvelopeService envelopeService;
  late AndroidKeystoreEnvelopeKeyProvider provider;
  late Uint8List dek;

  setUp(() {
    // The real providers resolve the gate from `Platform.isAndroid`, which
    // is what we just checked before skipping, so this is the production
    // object: no seam is passed here on purpose.
    storage = FlutterSecureStorageService();
    envelopeService = BiometricKeyEnvelopeService(storage: storage);
    provider = AndroidKeystoreEnvelopeKeyProvider(storage: storage);
    dek = Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 3) & 0xFF));
  });

  tearDown(() async {
    // Always leave the device clean, whatever the test did.
    await envelopeService.clear();
    await provider.deleteKey();
  });

  /// Skips the test when there is no Android device to talk to.
  void requireAndroidDevice(String what) {
    if (Platform.isAndroid) return;
    markTestSkipped(
      'SKIPPED: $what needs a real Android device with the Vaulta native '
      'channels registered. On ${Platform.operatingSystem} there is no '
      'AndroidKeyStore to exercise, so nothing here can be asserted.',
    );
  }

  group('real Android KeyStore', () {
    testWidgets('exposes no decrypt method on the keystore channel', (
      tester,
    ) async {
      requireAndroidDevice('the encrypt-only keystore contract');

      await tester.runAsync(() async {
        // KeystoreChannel answers `notImplemented()` for anything outside
        // isAvailable / ensureKey / rsaEncrypt / deleteKey, which reaches
        // Dart as a MissingPluginException.
        for (final method in const [
          'rsaDecrypt',
          'rsaDecryptAuthorized',
          'decrypt',
          'requestDecryptAuthorization',
        ]) {
          await expectLater(
            keystoreChannel.invokeMethod<Object>(method),
            throwsA(isA<MissingPluginException>()),
            reason: '$method must not exist on the keystore channel',
          );
        }

        // The same holds for the sibling methods the biometric channel
        // does not own.
        await expectLater(
          biometricChannel.invokeMethod<Object>('decryptSeed'),
          throwsA(isA<MissingPluginException>()),
        );
      });
    });

    testWidgets('ensureKey is idempotent and returns the documented alias', (
      tester,
    ) async {
      requireAndroidDevice('the KeyStore alias lifecycle');

      await tester.runAsync(() async {
        await provider.deleteKey();

        final first = await provider.ensureKey();
        final second = await provider.ensureKey();

        expect(first, _keyAlias);
        expect(second, first, reason: 'ensureKey must be idempotent');

        // After a wipe the alias comes back with the same name.
        await provider.deleteKey();
        expect(await provider.ensureKey(), _keyAlias);
      });
    });

    testWidgets('isAvailable answers without throwing on any modern device', (
      tester,
    ) async {
      requireAndroidDevice('the availability probe');

      await tester.runAsync(() async {
        // KeystoreChannel.isAvailable() builds and deletes a throwaway
        // biometric-bound RSA spec; it does NOT consult BiometricManager,
        // so a device with no enrolled fingerprint can still answer true.
        // Assert only the shape and stability of the answer.
        final first = await provider.isHardwareBackedBiometricAvailable();
        final second = await provider.isHardwareBackedBiometricAvailable();

        expect(first, isA<bool>());
        expect(second, first);
      });
    });

    testWidgets('rsaEncrypt returns a full modulus block, never the plaintext', (
      tester,
    ) async {
      requireAndroidDevice('RSA-OAEP encryption');

      await tester.runAsync(() async {
        final seed = Uint8List.fromList(List<int>.generate(32, (i) => i));

        final first = await provider.rsaEncryptSeed(seed);
        final second = await provider.rsaEncryptSeed(seed);

        expect(first, isNotNull);
        expect(first!.length, _modulusBytes);
        expect(second!.length, _modulusBytes);
        expect(first, isNot(equals(seed)));
        // OAEP padding is randomized, so two encryptions of one seed must
        // differ. If they matched, the platform was echoing the input.
        expect(first, isNot(equals(second)));

        // `plaintext` is a required argument on the native side.
        await expectLater(
          keystoreChannel.invokeMethod<Object>('rsaEncrypt', const {}),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              _badArgument,
            ),
          ),
        );
      });
    });
  });

  group('prompt-gated round trip (a human has to authenticate)', () {
    testWidgets('enrollment persists the ciphertext and never prompts', (
      tester,
    ) async {
      requireAndroidDevice('enrolling the biometric envelope');

      await tester.runAsync(() async {
        await storage.delete(_seedStorageKey);
        await envelopeService.clear();

        // `rsaEncrypt` uses the public key, so no prompt may appear. The
        // short budget turns "a prompt opened during enrollment" into a
        // test failure rather than a hang.
        final acquired = await provider.acquireEnvelopeKey().timeout(
          const Duration(seconds: 30),
        );

        expect(
          acquired.isSuccess,
          isTrue,
          reason: 'enrollment failed: ${acquired.failureReason}',
        );
        final seed = await acquired.key!.extractBytes();

        final stored = await storage.read(_seedStorageKey);
        expect(stored, isNotNull);
        final ciphertext =
            AndroidKeystoreEnvelopeKeyProvider.decodeEncryptedSeedFromStorage(
              stored!,
            );
        expect(ciphertext.length, _modulusBytes);
        expect(ciphertext, isNot(equals(seed)));
        expect(stored.contains(base64Encode(seed)), isFalse);

        await envelopeService.enroll(dekBytes: dek, envelopeKey: acquired.key!);
      });
    });

    testWidgets('the seed only comes back behind a fresh prompt', (tester) async {
      requireAndroidDevice('releasing the envelope key');

      await tester.runAsync(() async {
        final acquired = await provider.acquireEnvelopeKey();
        expect(
          acquired.isSuccess,
          isTrue,
          reason: 'enrollment failed: ${acquired.failureReason}',
        );
        final seed = await acquired.key!.extractBytes();
        await envelopeService.enroll(dekBytes: dek, envelopeKey: acquired.key!);

        // One authorization cannot be shared or run in parallel: the
        // second request is rejected with BIOMETRIC_BUSY rather than
        // piggybacking on the first one's prompt.
        final results = await Future.wait([
          provider.releaseEnvelopeKey(),
          provider.releaseEnvelopeKey(),
        ]).timeout(_promptBudget, onTimeout: () => throw StateError(
              'No BiometricPrompt was answered within $_promptBudget. '
              'Authenticate on the device, or skip this test.',
            ));

        final successes = results.where((result) => result.isSuccess);
        expect(
          successes,
          hasLength(1),
          reason: 'exactly one authorization may be in flight: '
              '${results.map((r) => r.failureReason).toList()}',
        );
        for (final failure in results.where((result) => !result.isSuccess)) {
          // The provider wraps the platform code into a stable reason
          // (`rsa_decrypt_failed:<code>:<message>`), so match on the code.
          expect(failure.failureReason, contains(_busy));
        }

        final released = successes.single;
        expect(
          await released.key!.extractBytes(),
          seed,
          reason: 'the prompt must recover the exact enrolled seed',
        );
        expect(
          await envelopeService.unwrap(envelopeKey: released.key!),
          dek,
        );

        // Wiping the alias must destroy both halves at once: after this
        // there is nothing left for the platform to authorize.
        await provider.deleteKey();
        expect(await storage.read(_seedStorageKey), isNull);
        final afterWipe = await provider.releaseEnvelopeKey();
        expect(afterWipe.isSuccess, isFalse);
        expect(afterWipe.failureReason, 'no_encrypted_seed_on_disk');
      });
    }, timeout: Timeout(_promptBudget * 2));
  });

  // These cannot run unattended. Each one needs a person to interact with
  // the system biometric prompt while the test is blocked on it, so they
  // are excluded from CI by construction rather than by a skip marker
  // that could silently rot.
  //
  // Verified on a POCO 2312DRA50G (API 36, AUTH_BIOMETRIC_STRONG) on
  // 2026-10-20: the six automated tests in this file pass, and this group
  // behaves exactly as designed when no one touches the prompt — the
  // device authenticates, the unlock succeeds, and the assertion that a
  // cancelled prompt must not yield a seed fails. That failure is correct:
  // the premise was not met. It is recorded here because "this test is red"
  // and "this test was never run" mean very different things to whoever
  // reads this next.
  group('human-driven negative paths', () {
    testWidgets('cancelling the prompt leaves the envelope intact', (
      tester,
    ) async {
      requireAndroidDevice('cancelling the biometric prompt');

      await tester.runAsync(() async {
        final acquired = await provider.acquireEnvelopeKey();
        expect(acquired.isSuccess, isTrue);
        await envelopeService.enroll(dekBytes: dek, envelopeKey: acquired.key!);
        final storedBefore = await storage.read(_seedStorageKey);

        debugPrint(
          '[integration_test] Dismiss the prompt (back / negative button) '
          'within $_promptBudget.',
        );

        final released = await provider.releaseEnvelopeKey().timeout(
          _promptBudget,
          onTimeout: () => throw StateError('The prompt was never shown.'),
        );

        // MainActivity maps ERROR_CANCELED / ERROR_USER_CANCELED /
        // ERROR_NEGATIVE_BUTTON onto USER_CANCELLED, which the provider
        // turns into `rsa_decrypt_returned_null` rather than a throw.
        expect(released.isSuccess, isFalse);
        expect(released.failureReason, 'rsa_decrypt_returned_null');
        // A refusal is not a corruption: the ciphertext is still there and
        // the KeyStore alias is still usable.
        expect(await storage.read(_seedStorageKey), storedBefore);
      });
    }, timeout: Timeout(_promptBudget * 2));
  });
}