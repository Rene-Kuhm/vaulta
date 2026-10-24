import 'dart:io';

import 'package:local_auth/local_auth.dart';

/// Snapshot of what the platform reports about biometric availability.
/// Returned by [BiometricAuthService.getAvailability] and rendered in
/// the security screen to explain to the user what is and isn't
/// possible on this device.
class BiometricAvailability {
  /// Creates a [BiometricAvailability] snapshot. All flags default to
  /// `false`; pass the real values from the platform.
  const BiometricAvailability({
    required this.deviceSupported,
    required this.canCheckBiometrics,
    required this.availableBiometrics,
  });

  /// True when the OS reports biometric hardware exists on the device.
  final bool deviceSupported;

  /// True when the OS allows the app to invoke the biometric check.
  final bool canCheckBiometrics;

  /// Which biometric factors are enrolled (face, fingerprint, strong,
  /// weak). Empty when none are enrolled yet.
  final List<BiometricType> availableBiometrics;

  /// True if the platform can host a biometric prompt for us at all
  /// (either hardware is present or the device supports a fallback).
  bool get canAuthenticate => deviceSupported || canCheckBiometrics;

  /// True when the user has enrolled at least one biometric factor
  /// that the OS is willing to gate us behind.
  bool get hasEnrolledBiometrics => availableBiometrics.isNotEmpty;

  /// Human-readable label of the strongest enrolled biometric, used
  /// in UI copy. Falls back to a generic phrase when no biometric
  /// is enrolled.
  String get label {
    if (availableBiometrics.contains(BiometricType.face)) {
      return 'reconocimiento facial';
    }

    if (availableBiometrics.contains(BiometricType.fingerprint) ||
        availableBiometrics.contains(BiometricType.strong)) {
      return 'huella o biometria fuerte';
    }

    if (availableBiometrics.contains(BiometricType.weak)) {
      return 'biometria del dispositivo';
    }

    if (Platform.isWindows) {
      return 'Windows Hello';
    }

    return 'autenticacion del dispositivo';
  }
}

/// Abstraction over the platform's biometric prompt. [LocalBiometricAuthService]
/// is the production implementation; tests substitute fakes.
///
/// The two production implementations differ in *who opens the prompt*,
/// and that difference is a security property, not an implementation
/// detail, so it lives in the type system rather than in a runtime flag
/// somewhere in the bootstrap. See [PromptingBiometricAuthService] and
/// [NonPromptingBiometricAuthService].
abstract interface class BiometricAuthService {
  /// Probes the platform and returns what kinds of biometric factors
  /// are available, without prompting the user.
  Future<BiometricAvailability> getAvailability();

  /// Triggers the platform biometric prompt. Returns `true` if the
  /// user authenticated, `false` if the user cancelled or the prompt
  /// was unavailable for an expected reason.
  Future<bool> authenticateForUnlock();
}

/// A gate that opens its own `BiometricPrompt` inside
/// [BiometricAuthService.authenticateForUnlock]. Only for platforms with
/// no platform-protected envelope key to authorize.
abstract interface class PromptingBiometricAuthService
    implements BiometricAuthService {}

/// A gate whose [BiometricAuthService.authenticateForUnlock] is only an
/// availability probe and NEVER opens a prompt.
///
/// On Android the prompt is opened by the envelope key provider, bound
/// to the KeyStore private key through `BiometricPrompt.CryptoObject`, so
/// anything that also opened one here would show the user a second,
/// pointless prompt. Pairing a [PromptingBiometricAuthService] with a
/// prompting provider is the double-prompt bug; keeping the two
/// capabilities in separate types is what stops it from being written.
abstract interface class NonPromptingBiometricAuthService
    implements BiometricAuthService {}

/// Production [BiometricAuthService] backed by `package:local_auth`.
///
/// This variant owns the prompt: [authenticateForUnlock] shows one. It
/// is therefore only correct for a platform with no envelope key
/// provider behind it, which today means every non-Android target.
class LocalBiometricAuthService implements PromptingBiometricAuthService {
  /// Optional [auth] override for tests. Defaults to a fresh
  /// [LocalAuthentication] instance.
  LocalBiometricAuthService({LocalAuthentication? auth})
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<BiometricAvailability> getAvailability() async {
    try {
      final canCheckBiometrics = await _auth.canCheckBiometrics;
      final deviceSupported = await _auth.isDeviceSupported();
      final availableBiometrics = await _auth.getAvailableBiometrics();

      return BiometricAvailability(
        deviceSupported: deviceSupported,
        canCheckBiometrics: canCheckBiometrics,
        availableBiometrics: availableBiometrics,
      );
    } on LocalAuthException {
      return const BiometricAvailability(
        deviceSupported: false,
        canCheckBiometrics: false,
        availableBiometrics: [],
      );
    }
  }

  @override
  Future<bool> authenticateForUnlock() async {
    try {
      return await _auth.authenticate(
        localizedReason:
            'Desbloquea Vaulta para recuperar tu sesion protegida.',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } on LocalAuthException catch (error) {
      if (error.code == LocalAuthExceptionCode.noBiometricsEnrolled ||
          error.code == LocalAuthExceptionCode.noBiometricHardware ||
          error.code ==
              LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable ||
          error.code == LocalAuthExceptionCode.temporaryLockout ||
          error.code == LocalAuthExceptionCode.biometricLockout ||
          error.code == LocalAuthExceptionCode.userCanceled) {
        return false;
      }

      rethrow;
    }
  }
}
