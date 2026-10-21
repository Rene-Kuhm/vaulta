import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// Hash algorithm behind a TOTP secret.
///
/// RFC 6238 defines the code for SHA-1, SHA-256 and SHA-512. SHA-1 is
/// what Bitwarden, Google Authenticator and most `otpauth://` URIs
/// emit by default, so it is the fallback when the URI says nothing.
enum TotpAlgorithm {
  /// HMAC-SHA1, the default in the wild.
  sha1('SHA1'),

  /// HMAC-SHA256.
  sha256('SHA256'),

  /// HMAC-SHA512.
  sha512('SHA512');

  const TotpAlgorithm(this.otpName);

  /// Canonical name used by the `algorithm=` parameter of an
  /// `otpauth://` URI.
  final String otpName;

  /// Resolves the value of an `algorithm=` parameter, case-insensitively.
  ///
  /// Throws a [FormatException] for any other algorithm instead of
  /// falling back to SHA-1: a wrong algorithm produces wrong codes.
  static TotpAlgorithm fromOtpName(String name) {
    final normalized = name.trim().toUpperCase();
    for (final algorithm in values) {
      if (algorithm.otpName == normalized) {
        return algorithm;
      }
    }
    throw FormatException(
      'Unsupported TOTP algorithm "$name": expected SHA1, SHA256 or SHA512.',
    );
  }
}

/// Everything needed to compute the codes of one TOTP entry.
class TotpConfig {
  /// Builds a configuration from raw [secret] bytes.
  ///
  /// [digits] must be 6 or 8 (the only lengths RFC 6238 and the
  /// authenticator apps agree on) and [period] must be positive; any
  /// other value throws a [FormatException] so a malformed entry can
  /// never render a plausible but wrong code.
  TotpConfig({
    required Uint8List secret,
    this.digits = 6,
    this.period = 30,
    this.algorithm = TotpAlgorithm.sha1,
  }) : secret = Uint8List.fromList(secret) {
    if (this.secret.isEmpty) {
      throw const FormatException('The TOTP secret is empty.');
    }
    if (digits != 6 && digits != 8) {
      throw FormatException(
        'Unsupported TOTP digit count $digits: expected 6 or 8.',
      );
    }
    if (period <= 0) {
      throw FormatException(
        'Unsupported TOTP period ${period}s: expected a positive number of '
        'seconds.',
      );
    }
  }

  /// Raw HMAC key decoded from the base32 secret.
  final Uint8List secret;

  /// Number of digits in the generated code: 6 or 8.
  final int digits;

  /// Length of one time step, in seconds.
  final int period;

  /// Hash algorithm used for the HMAC.
  final TotpAlgorithm algorithm;
}

/// Computes the TOTP code of [config] for the time step that contains
/// [time] (RFC 6238, section 4).
///
/// The result is always exactly [TotpConfig.digits] long, zero-padded,
/// and identical to what an authenticator app seeded with the same URI
/// shows at that instant.
String generateTotpCode(TotpConfig config, DateTime time) {
  final counter = _timeStep(config, time);
  final mac = _hmac(config.algorithm, config.secret, _counterBytes(counter));

  // Dynamic truncation (RFC 4226, section 5.3): the low nibble of the
  // last byte selects a four-byte window whose top bit is masked off.
  final offset = mac[mac.length - 1] & 0x0F;
  final binary =
      ((mac[offset] & 0x7F) << 24) |
      ((mac[offset + 1] & 0xFF) << 16) |
      ((mac[offset + 2] & 0xFF) << 8) |
      (mac[offset + 3] & 0xFF);

  final modulus = config.digits == 8 ? 100000000 : 1000000;
  return (binary % modulus).toString().padLeft(config.digits, '0');
}

/// Seconds left in the current time step of [config] at [time].
///
/// Always in `1..period`, so a countdown can show "1s remaining"
/// without ever hitting zero for a frame.
int totpSecondsRemaining(TotpConfig config, DateTime time) {
  final elapsedSeconds = time.toUtc().millisecondsSinceEpoch ~/ 1000;
  final secondsIntoStep = elapsedSeconds % config.period;
  return config.period - secondsIntoStep;
}

int _timeStep(TotpConfig config, DateTime time) {
  final elapsedSeconds = time.toUtc().millisecondsSinceEpoch ~/ 1000;
  return elapsedSeconds ~/ config.period;
}

/// Big-endian 64-bit counter, as required by RFC 4226 for the HMAC
/// message.
Uint8List _counterBytes(int counter) {
  final bytes = Uint8List(8);
  var remaining = counter;
  for (var index = 7; index >= 0; index--) {
    bytes[index] = remaining & 0xFF;
    remaining >>= 8;
  }
  return bytes;
}

List<int> _hmac(TotpAlgorithm algorithm, List<int> key, List<int> message) {
  final mac = switch (algorithm) {
    TotpAlgorithm.sha1 => DartHmac.sha1(),
    TotpAlgorithm.sha256 => DartHmac.sha256(),
    TotpAlgorithm.sha512 => DartHmac.sha512(),
  };

  return mac
      .calculateMacSync(
        message,
        secretKeyData: SecretKeyData(key),
        nonce: const <int>[],
      )
      .bytes;
}
