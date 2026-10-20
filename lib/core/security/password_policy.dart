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

  /// Breached-password screening, checked offline.
  ///
  /// Catches the curated list plus, once [loadBreachCorpus] has run, the
  /// NCSC 100k corpus indexed by digest. Never reaches the network.
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
  /// Checks four forms of the candidate: the lowercased password, its folded
  /// form, and both with trailing digits stripped, so that `password1234`
  /// and `p@ssw0rd1234` are both caught. Every form is checked against the
  /// in-source curated list *and* against the loaded corpus, and both sides
  /// are indexed with the same fold (`foldForBlocklist`,
  /// `stripTrailingDigits` — see `common_password_blocklist.dart`).
  ///
  /// The curated list is consulted first and needs no I/O. If the corpus is
  /// not loaded yet, this returns exactly what it always returned: a screen
  /// that is weaker, never one that is wrong. Read
  /// [isBreachCorpusLoaded] to tell the two states apart.
  static bool isCommon(String password) {
    final lower = password.toLowerCase();
    final folded = foldForBlocklist(lower);
    final withoutDigits = stripTrailingDigits(lower);
    final foldedWithoutDigits = stripTrailingDigits(folded);

    if (isListedPassword(lower) ||
        isListedFoldedPassword(folded) ||
        isListedPassword(withoutDigits) ||
        isListedFoldedPassword(foldedWithoutDigits)) {
      return true;
    }

    if (!isBreachCorpusLoaded) {
      return false;
    }
    return breachCorpus.containsAny([
      lower,
      folded,
      withoutDigits,
      foldedWithoutDigits,
    ]);
  }

  /// True once the breach corpus asset has been loaded into memory.
  ///
  /// `false` means "not loaded yet", which is a gap in coverage, not a
  /// verdict: the screen is the curated in-source list until it flips. The
  /// UI uses this to decide whether to say anything about screening depth.
  static bool get isBreachCorpusLoaded => breachCorpus.isLoaded;

  /// Number of corpus digests in memory, or 0 while [isBreachCorpusLoaded]
  /// is false.
  static int get breachDigestCount => breachCorpus.digestCount;

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