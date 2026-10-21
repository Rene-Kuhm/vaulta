import 'base32.dart';
import 'totp.dart';

/// A parsed `otpauth://totp/...` key URI, the format every
/// authenticator app exports and imports.
///
/// Only the TOTP type is modelled: `otpauth://hotp/` codes are
/// counter-based and deliberately rejected by [parseOtpAuthUri].
class OtpAuthUri {
  /// Builds a key URI description. [secret] is the base32 secret as
  /// written in the URI; it is decoded (and validated) by
  /// [totpConfig].
  const OtpAuthUri({
    required this.account,
    required this.secret,
    this.issuer,
    this.digits = 6,
    this.period = 30,
    this.algorithm = TotpAlgorithm.sha1,
  });

  /// Issuer shown next to the code ("GitHub"), or `null` when the URI
  /// carries neither an `issuer=` parameter nor an `Issuer:` label
  /// prefix.
  final String? issuer;

  /// Account the code belongs to, usually an email or username.
  final String account;

  /// Base32 secret, still encoded exactly as it appeared in the URI.
  final String secret;

  /// Number of digits of the generated code: 6 or 8.
  final int digits;

  /// Length of one time step, in seconds.
  final int period;

  /// Hash algorithm used for the HMAC.
  final TotpAlgorithm algorithm;

  /// The ready-to-use configuration for [generateTotpCode].
  ///
  /// Throws a [FormatException] when [secret] is not valid base32.
  TotpConfig get totpConfig => TotpConfig(
    secret: base32Decode(secret),
    digits: digits,
    period: period,
    algorithm: algorithm,
  );
}

/// Parses an `otpauth://totp/...` URI into [OtpAuthUri].
///
/// Accepts the shapes real apps emit: an `Issuer:Account` label with
/// percent-encoded characters, an explicit `issuer=` parameter that
/// wins over the label prefix, and the optional `digits`, `period` and
/// `algorithm` parameters (defaults: 6 digits, 30 s, SHA1).
///
/// Throws a [FormatException] with a human-readable message when the
/// URI is not a TOTP key URI, is missing its secret, uses HOTP
/// (counter-based and out of scope), or carries a value this app
/// cannot honour — an unsupported algorithm, a digit count other than
/// 6 or 8, a non-positive period, or a secret that is not valid
/// base32.
OtpAuthUri parseOtpAuthUri(String uri) {
  final parsed = Uri.tryParse(uri.trim());
  if (parsed == null) {
    throw const FormatException('Not a valid otpauth:// URI.');
  }
  if (parsed.scheme.toLowerCase() != 'otpauth') {
    throw FormatException(
      'Not an otpauth:// URI: expected the otpauth scheme, got '
      '"${parsed.scheme}".',
    );
  }

  final type = parsed.host.toLowerCase();
  if (type == 'hotp') {
    throw const FormatException(
      'This entry uses HOTP (otpauth://hotp/), which is counter-based and '
      'not supported. TOTP codes are time-based.',
    );
  }
  if (type != 'totp') {
    throw FormatException(
      'Unsupported otpauth:// type "${parsed.host}": expected totp.',
    );
  }

  final label = parsed.pathSegments.isEmpty
      ? ''
      : parsed.pathSegments.join('/').trim();
  if (label.isEmpty) {
    throw const FormatException(
      'The otpauth:// URI is missing its account label.',
    );
  }

  final separator = label.indexOf(':');
  final labelIssuer = separator < 0
      ? null
      : label.substring(0, separator).trim();
  final labelAccount = (separator < 0 ? label : label.substring(separator + 1))
      .trim();
  if (labelAccount.isEmpty) {
    throw const FormatException(
      'The otpauth:// URI is missing its account label.',
    );
  }

  final parameters = <String, String>{
    for (final entry in parsed.queryParameters.entries)
      entry.key.toLowerCase(): entry.value,
  };

  final secret = (parameters['secret'] ?? '').trim();
  if (secret.isEmpty) {
    throw const FormatException(
      'The otpauth:// URI is missing its secret parameter.',
    );
  }
  // Decode once here so a malformed secret is rejected as a parse
  // error, with the decoder's own message, instead of surfacing when
  // the code is first rendered.
  base32Decode(secret);

  final digits = _parseDigits(parameters['digits']);
  final period = _parsePeriod(parameters['period']);
  final algorithmParameter = parameters['algorithm']?.trim();
  final algorithm = algorithmParameter == null || algorithmParameter.isEmpty
      ? TotpAlgorithm.sha1
      : TotpAlgorithm.fromOtpName(algorithmParameter);

  final issuerParameter = parameters['issuer']?.trim();
  final issuer = issuerParameter != null && issuerParameter.isNotEmpty
      ? issuerParameter
      : (labelIssuer != null && labelIssuer.isNotEmpty ? labelIssuer : null);

  return OtpAuthUri(
    issuer: issuer,
    account: labelAccount,
    secret: secret,
    digits: digits,
    period: period,
    algorithm: algorithm,
  );
}

int _parseDigits(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return 6;
  }
  final digits = int.tryParse(raw.trim());
  if (digits == null || (digits != 6 && digits != 8)) {
    throw FormatException(
      'Unsupported digits value "${raw.trim()}": expected 6 or 8.',
    );
  }
  return digits;
}

int _parsePeriod(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return 30;
  }
  final period = int.tryParse(raw.trim());
  if (period == null || period <= 0) {
    throw FormatException(
      'Unsupported period value "${raw.trim()}": expected a positive number '
      'of seconds.',
    );
  }
  return period;
}
