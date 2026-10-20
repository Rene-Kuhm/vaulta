import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'common_password_blocklist.dart';

/// Why a candidate master password was rejected.
enum PasswordPolicyVerdict {
  /// The password is acceptable.
  acceptable,

  /// Shorter than the configured minimum.
  tooShort,

  /// Longer than the configured maximum. Bounds the Argon2id input so a
  /// multi-megabyte paste cannot turn unlock into a denial of service
  /// against the device's own user.
  tooLong,

  /// Present in the shipped blocklist, or a trivial character-class
  /// mutation of a blocklist entry.
  breached,
}

/// Decides whether a candidate master password is acceptable, and
/// normalizes it to the canonical bytes the KDF must consume.
///
/// ## Why normalization lives here
///
/// The same logical password typed two ways must derive the same key.
/// `café` can arrive as U+00E9 (precomposed) or as `e` + U+0301
/// (decomposed); those are different byte sequences that render
/// identically. NFC makes them one. Every KDF entry point routes through
/// [normalize] so the guarantee holds.
///
/// ## Why composition rules are gone
///
/// NIST SP 800-63B §3.1.1.2 recommends against character-class rules:
/// they push users toward predictable patterns (`Password1!`) that are
/// *weaker* than a long passphrase, and they reject non-Latin scripts for
/// no security benefit. This class enforces length, a blocklist, and an
/// upper bound, and deliberately nothing else. NIST also recommends
/// against arbitrary periodic rotation and against blocking paste or
/// password-manager autofill; neither is done here.
class PasswordPolicy {
  /// Creates a policy with explicit bounds.
  const PasswordPolicy({
    this.minimumLength = defaultMinimumLength,
    this.maximumLength = defaultMaximumLength,
  });

  /// Default lower bound. Above the NIST minimum of 8 because Vaulta is
  /// the only thing standing between a stolen vault blob and every
  /// credential the owner holds.
  static const int defaultMinimumLength = 12;

  /// Upper bound on KDF input. 1024 characters is far past any usable
  /// passphrase and keeps Argon2id's memory-hungry preprocessing bounded.
  static const int defaultMaximumLength = 1024;

  /// Minimum acceptable length.
  final int minimumLength;

  /// Maximum acceptable length.
  final int maximumLength;

  /// True when [password] is on the blocklist or folds onto an entry.
  ///
  /// Checks the raw lowercase form first, then the folded form against
  /// the *folded* list, so that both `password1234` and `p@ssw0rd1234`
  /// are caught: each folds to the same value, and the raw list entry
  /// `password1234` is what puts that value in the folded list.
  static bool isCommon(String password) {
    final lower = password.toLowerCase();
    if (isListedPassword(lower)) {
      return true;
    }

    final folded = foldForBlocklist(lower);
    if (isListedFoldedPassword(folded)) {
      return true;
    }

    // "letmein12345" is the shape people reach for when they know the
    // base word is weak. The fold alone does not catch it.
    return isListedPassword(stripTrailingDigits(lower)) ||
        isListedFoldedPassword(stripTrailingDigits(folded));
  }

  /// Classifies [password]. Does not throw and does not mutate.
  PasswordPolicyVerdict evaluate(String password) {
    final normalized = normalize(password);
    if (normalized.length < minimumLength) {
      return PasswordPolicyVerdict.tooShort;
    }
    if (normalized.length > maximumLength) {
      return PasswordPolicyVerdict.tooLong;
    }
    if (isCommon(normalized)) {
      return PasswordPolicyVerdict.breached;
    }
    return PasswordPolicyVerdict.acceptable;
  }

  /// Normalizes [password] to NFC, the canonical form the KDF consumes.
  static String normalize(String password) => unorm.nfc(password);

  /// User-facing explanation for a non-acceptable [verdict].
  ///
  /// Returns `null` when [verdict] is [PasswordPolicyVerdict.acceptable].
  static String? explain(PasswordPolicyVerdict verdict, int minimum) {
    return switch (verdict) {
      PasswordPolicyVerdict.acceptable => null,
      PasswordPolicyVerdict.tooShort =>
        'Usa al menos $minimum caracteres.',
      PasswordPolicyVerdict.tooLong =>
        'Usa como máximo ${PasswordPolicy.defaultMaximumLength} caracteres.',
      PasswordPolicyVerdict.breached =>
        'Esa contraseña aparece en listas de contraseñas filtradas. '
        'Elegí otra.',
    };
  }
}