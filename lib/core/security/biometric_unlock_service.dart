// ignore_for_file: prefer_const_constructors

import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, visibleForTesting;

import 'biometric_auth_service.dart';
import 'biometric_key_envelope_service.dart';
import 'master_password_record.dart';
import 'secure_storage_service.dart';
import 'vault_session.dart';

/// Result of asking the platform for an envelope key. Carries
/// either the [SecretKey] we wanted or a human-readable
/// [failureReason] explaining why the platform could not produce one
/// right now. The controller surfaces that reason in the unlock
/// screen so the user can tell us *what* went wrong, not just that
/// something did.
class BiometricEnvelopeKeyResult {
  /// Success branch: a usable [SecretKey].
  const BiometricEnvelopeKeyResult.success(SecretKey this.key)
    : failureReason = null;

  /// Unavailable branch: a stable, human-readable reason explaining
  /// why the platform could not produce a key.
  const BiometricEnvelopeKeyResult.unavailable(String this.failureReason)
    : key = null;

  /// True when [key] is non-null and safe to use.
  bool get isSuccess => key != null;

  /// The AES-256 envelope key as a usable [SecretKey]. Null on
  /// failure.
  final SecretKey? key;

  /// Stable, human-readable cause of the failure. Null on success.
  /// Examples:
  ///   * `"platform_no_hardware_backed_biometric"`
  ///   * `"ensure_key_failed:KEYSTORE_ERROR"`
  ///   * `"rsa_encrypt_returned_null"`
  final String? failureReason;

  @override
  String toString() => isSuccess
      ? 'BiometricEnvelopeKeyResult.success'
      : 'BiometricEnvelopeKeyResult.unavailable($failureReason)';
}

/// Abstract source for the platform-protected key that wraps the DEK.
///
/// Implementations must return a [BiometricEnvelopeKeyResult]
/// containing a [SecretKey] that can be used directly with
/// `package:cryptography` (i.e. extractable bytes), or a structured
/// failure when the platform cannot produce one. The envelope
/// service treats the returned key as opaque: it feeds it into
/// HKDF-SHA256 and uses the result to AES-256-GCM encrypt the DEK.
///
/// On Android the provider is expected to:
///   1. Generate or load the hardware-backed RSA-2048 keypair.
///   2. Generate a fresh random AES-256 seed (the actual envelope
///      key).
///   3. RSA-OAEP-encrypt the seed with the public key and store the
///      ciphertext in secure storage (so it survives app restarts).
///   4. Return the *plaintext seed* to the envelope service.
///
/// On unlock, the provider's mirror [releaseEnvelopeKey] is given
/// the same ciphertext to RSA-decrypt with the private key (which
/// requires a fresh BiometricPrompt), yielding the same seed bytes.
/// The two halves of the round-trip are intentionally separate so
/// that enrollment can happen silently (no prompt) while unlock
/// always prompts.
abstract interface class BiometricEnvelopeKeyProvider {
  /// Returns the AES-256 envelope key as a usable [SecretKey], or a
  /// [BiometricEnvelopeKeyResult.unavailable] describing why the
  /// platform cannot back the envelope on this device (no hardware,
  /// user has not enrolled biometrics, KeyStore generation failed,
  /// etc.). The unlock screen surfaces that reason verbatim so the
  /// user can give us an actionable bug report.
  Future<BiometricEnvelopeKeyResult> acquireEnvelopeKey();

  /// Returns the AES-256 envelope key after a fresh biometric
  /// authorization has been collected. Implementations are expected
  /// to block on the BiometricPrompt and only resolve once the user
  /// has authenticated. The failure reason is the same shape as
  /// [acquireEnvelopeKey] so the unlock screen can render both
  /// paths with the same template.
  Future<BiometricEnvelopeKeyResult> releaseEnvelopeKey();
}

/// Outcome of a biometric unlock attempt. Distinguishes "user canceled",
/// "biometrics not enrolled", "no envelope on disk", and "platform
/// rejected the auth" from "we recovered the DEK and built a session".
sealed class BiometricUnlockOutcome {
  const BiometricUnlockOutcome();
}

/// Successful biometric unlock. The wrapped DEK was recovered and
/// turned into a v2 [VaultSession] the same shape a password unlock
/// would produce.
class BiometricUnlockSuccess extends BiometricUnlockOutcome {
  /// Builds a success outcome with the freshly built [session].
  const BiometricUnlockSuccess(this.session);

  /// The unlocked v2 vault session. Feed it into the rest of the
  /// app exactly like a password-derived session.
  final VaultSession session;
}

/// The user (or the platform) rejected the biometric prompt. The
/// caller should fall back to the master password flow.
class BiometricUnlockRejected extends BiometricUnlockOutcome {
  /// Builds a rejection outcome with a human-readable [reason].
  const BiometricUnlockRejected(this.reason);

  /// Why the prompt was rejected (canceled, lockout, platform
  /// refused, etc.). Suitable for surfacing in the unlock UI.
  final String reason;
}

/// The biometric path is not usable on this device or in this state.
/// The caller should fall back to the master password flow.
class BiometricUnlockUnavailable extends BiometricUnlockOutcome {
  /// Builds an "unavailable" outcome with a human-readable [reason].
  const BiometricUnlockUnavailable(this.reason);

  /// Why biometrics can't be tried right now (no hardware, no
  /// enrolled biometric, OS-level block, etc.).
  final String reason;
}

/// Specialization of [BiometricUnlockUnavailable] for the first-run
/// case: biometrics are enabled and the device has them enrolled, but
/// the wrapped-DEK envelope has not been written to disk yet. The
/// user has to unlock with the master password once so we can derive
/// the DEK and wrap it. The unlock screen surfaces this with a
/// single, non-redundant hint instead of a generic "biometrics
/// unavailable" message.
class BiometricUnlockNeedsPasswordFirst extends BiometricUnlockUnavailable {
  /// Forwards [reason] to [BiometricUnlockUnavailable].
  const BiometricUnlockNeedsPasswordFirst(super.reason);
}

/// Orchestrates the biometric unlock path. The flow is:
///   1. Confirm the platform says biometrics are available and enrolled.
///   2. Confirm a wrapped DEK envelope exists in secure storage.
///   3. Prompt the user for biometrics via the platform gate.
///   4. Derive an envelope key from the platform-protected slot, unwrap
///      the DEK, and return a VaultSession the same shape as a
///      password-derived session would produce.
///
/// On non-mobile targets (web, desktop) this still runs, but step 1
/// reports the platform as unsupported and the service degrades to
/// "biometrics not available on this target" without exposing the
/// caller to a native plugin they cannot load.
class BiometricUnlockService {
  /// Wires the unlock service. All dependencies are required; the
  /// optional [envelopeKeyProvider] defaults to a no-op (always
  /// reports "platform not supported") for non-Android targets.
  ///
  /// [isMobileTarget] is the platform gate for step 1. It defaults to
  /// [Platform.isAndroid] || [Platform.isIOS], so production behaviour is
  /// unchanged; tests pass `true` to run the real orchestration against a
  /// stub envelope-key provider on a host that is neither.
  BiometricUnlockService({
    required SecureStorageService storage,
    required BiometricAuthService biometricAuthService,
    required BiometricKeyEnvelopeService envelopeService,
    BiometricEnvelopeKeyProvider? envelopeKeyProvider,
    @visibleForTesting bool? isMobileTarget,
  }) : _storage = storage,
       _biometricAuthService = biometricAuthService,
       _envelopeService = envelopeService,
       _envelopeKeyProvider = envelopeKeyProvider ?? _defaultKeyProvider,
       _isMobileTarget = isMobileTarget ??
           (Platform.isAndroid || Platform.isIOS);

  /// Secure storage key for the platform KeyStore alias reference
  /// (used to invalidate cleanly when biometrics are turned off).
  static const envelopeKeySlotKey = 'vault_biometric_envelope_key_slot_v1';

  final SecureStorageService _storage;
  final BiometricAuthService _biometricAuthService;
  final BiometricKeyEnvelopeService _envelopeService;
  final BiometricEnvelopeKeyProvider _envelopeKeyProvider;

  /// Whether this target can host a biometric prompt at all. The only
  /// place the unlock service reads [Platform].
  final bool _isMobileTarget;

  /// Exposed so the controller can hand the same provider to its
  /// enrollment helper. Hiding this would force every callsite to
  /// build a parallel service.
  BiometricEnvelopeKeyProvider get envelopeKeyProvider => _envelopeKeyProvider;

  /// True when the platform reports biometrics are usable AND an
  /// envelope is enrolled on disk. The controller uses this to decide
  /// whether to surface the biometric unlock option.
  Future<bool> canAttemptUnlock() async {
    if (!await _isBiometricCapableTarget()) {
      return false;
    }
    final availability = await _biometricAuthService.getAvailability();
    if (!availability.canAuthenticate || !availability.hasEnrolledBiometrics) {
      return false;
    }
    return _envelopeService.isEnrolled();
  }

  /// Performs the full biometric unlock flow and returns either a
  /// session or a structured failure.
  Future<BiometricUnlockOutcome> unlock({
    required MasterPasswordRecord record,
  }) async {
    if (record.version < 2 || record.kdf == null || record.dekWrap == null) {
      return const BiometricUnlockUnavailable(
        'Tu master password es de una version anterior. Ingresa la contrasena para re-cifrar y luego podras activar biometria.',
      );
    }

    if (!await _isBiometricCapableTarget()) {
      return const BiometricUnlockUnavailable(
        'La biometria no esta disponible en este dispositivo.',
      );
    }

    final availability = await _biometricAuthService.getAvailability();
    if (!availability.canAuthenticate) {
      return const BiometricUnlockUnavailable(
        'La biometria no esta disponible en este dispositivo.',
      );
    }
    if (!availability.hasEnrolledBiometrics) {
      return const BiometricUnlockUnavailable(
        'No hay biometria registrada. Configura la huella o el reconocimiento facial del dispositivo y reintenta.',
      );
    }

    if (!await _envelopeService.isEnrolled()) {
      // The button is offered because the device has biometrics
      // enrolled and the user has the preference on, but the
      // wrapped-DEK envelope has not been written to disk yet. The
      // only way to create the envelope is to first unlock with the
      // master password so we have the DEK to wrap. Surface this as
      // its own outcome so the controller can show a single, clear
      // hint instead of a generic "biometrics unavailable" message.
      return const BiometricUnlockNeedsPasswordFirst(
        'Para activar la huella por primera vez, desbloquea una vez con la '
        'master password. Las proximas veces podras usar la huella directamente.',
      );
    }

    final authed = await _biometricAuthService.authenticateForUnlock();
    if (!authed) {
      return const BiometricUnlockRejected(
        'No pudimos verificar tu identidad. Ingresa la master password.',
      );
    }

    final envelopeKeyResult = await _envelopeKeyProvider.releaseEnvelopeKey();
    if (!envelopeKeyResult.isSuccess) {
      return BiometricUnlockRejected(
        'La plataforma rechazo la clave biometrica '
        '(${envelopeKeyResult.failureReason ?? "unknown"}). '
        'Re-enrola biometria o usa la master password.',
      );
    }

    try {
      final dekBytes = await _envelopeService.unwrap(
        envelopeKey: envelopeKeyResult.key!,
      );
      final session = VaultSession.v2(
        keyId: record.keyId,
        secretKey: SecretKey(dekBytes),
        kdf: record.kdf!,
        dekWrap: record.dekWrap!,
      );
      return BiometricUnlockSuccess(session);
    } on SecretBoxAuthenticationError {
      return const BiometricUnlockRejected(
        'La plataforma devolvio una clave inconsistente. Ingresa la master password y re-enrola biometria.',
      );
    } catch (error, stack) {
      // Logged, not interpolated. Exception text from a crypto path can
      // carry provider and algorithm detail that does not belong on an
      // unlock screen, and it tells the user nothing they can act on.
      debugPrint('[Vaulta/Biometric] unlock failed: $error\n$stack');
      return const BiometricUnlockRejected(
        'No pudimos recuperar tu sesion con biometria. '
        'Re-enrola biometria o usa la master password.',
      );
    }
  }

  /// Wipes the envelope and the platform key slot reference. Called
  /// when biometrics are turned off, the master password changes, or
  /// a biometric unlock fails in a way that should not leave a stale
  /// envelope on disk.
  Future<void> invalidate() async {
    await _envelopeService.clear();
    final provider = _envelopeKeyProvider;
    if (provider is BiometricEnvelopeKeyInvalidator) {
      await (provider as BiometricEnvelopeKeyInvalidator).deleteKey();
    }
    await _storage.delete(envelopeKeySlotKey);
  }

  Future<bool> _isBiometricCapableTarget() async {
    return _isMobileTarget;
  }

  /// Default provider for non-Android targets (web, desktop, iOS in
  /// the future). It always reports that no envelope key is
  /// available, which makes the unlock service report "biometrics
  /// not available" instead of crashing.
  static final BiometricEnvelopeKeyProvider _defaultKeyProvider =
      _NoopEnvelopeKeyProvider();
}

/// Side-channel interface implemented by providers that can wipe
/// their own platform key (e.g. the Android KeyStore RSA alias).
abstract interface class BiometricEnvelopeKeyInvalidator {
  /// Asks the platform to delete the hardware-backed key and any
  /// associated state. Idempotent: safe to call when no key exists.
  Future<void> deleteKey();
}

class _NoopEnvelopeKeyProvider implements BiometricEnvelopeKeyProvider {
  const _NoopEnvelopeKeyProvider();

  @override
  Future<BiometricEnvelopeKeyResult> acquireEnvelopeKey() async {
    return const BiometricEnvelopeKeyResult.unavailable(
      'platform_not_supported',
    );
  }

  @override
  Future<BiometricEnvelopeKeyResult> releaseEnvelopeKey() async {
    return const BiometricEnvelopeKeyResult.unavailable(
      'platform_not_supported',
    );
  }
}
