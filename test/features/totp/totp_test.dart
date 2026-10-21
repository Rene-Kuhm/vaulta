import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/features/totp/domain/base32.dart';
import 'package:gestor_contrasenas/features/totp/domain/totp.dart';

void main() {
  group('RFC 6238 Appendix B vectors', () {
    // The seed is the ASCII string "12345678901234567890", extended
    // to the hash length by repeating it, exactly as RFC 6238
    // Appendix B specifies for the SHA-256 and SHA-512 vectors.
    const seedText = '12345678901234567890';
    final seed = ascii.encode(seedText);
    final seed256 = ascii.encode('12345678901234567890123456789012');
    final seed512 = ascii.encode(
      '1234567890123456789012345678901234567890123456789012345678901234',
    );

    const vectors = <({int time, String sha1, String sha256, String sha512})>[
      (time: 59, sha1: '94287082', sha256: '46119246', sha512: '90693936'),
      (
        time: 1111111109,
        sha1: '07081804',
        sha256: '68084774',
        sha512: '25091201',
      ),
      (
        time: 1111111111,
        sha1: '14050471',
        sha256: '67062674',
        sha512: '99943326',
      ),
      (
        time: 1234567890,
        sha1: '89005924',
        sha256: '91819424',
        sha512: '93441116',
      ),
      (
        time: 2000000000,
        sha1: '69279037',
        sha256: '90698825',
        sha512: '38618901',
      ),
      (
        time: 20000000000,
        sha1: '65353130',
        sha256: '77737706',
        sha512: '47863826',
      ),
    ];

    for (final vector in vectors) {
      final at = DateTime.fromMillisecondsSinceEpoch(
        vector.time * 1000,
        isUtc: true,
      );

      test('SHA-1 at T=${vector.time}', () {
        expect(
          generateTotpCode(
            TotpConfig(secret: seed, digits: 8, algorithm: TotpAlgorithm.sha1),
            at,
          ),
          vector.sha1,
        );
      });

      test('SHA-256 at T=${vector.time}', () {
        expect(
          generateTotpCode(
            TotpConfig(
              secret: seed256,
              digits: 8,
              algorithm: TotpAlgorithm.sha256,
            ),
            at,
          ),
          vector.sha256,
        );
      });

      test('SHA-512 at T=${vector.time}', () {
        expect(
          generateTotpCode(
            TotpConfig(
              secret: seed512,
              digits: 8,
              algorithm: TotpAlgorithm.sha512,
            ),
            at,
          ),
          vector.sha512,
        );
      });
    }
  });

  group('generateTotpCode', () {
    final secret = base32TestSecret;

    test('truncates the same counter to six digits', () {
      final at = DateTime.fromMillisecondsSinceEpoch(59000, isUtc: true);
      final eight = generateTotpCode(TotpConfig(secret: secret, digits: 8), at);
      final six = generateTotpCode(TotpConfig(secret: secret), at);

      expect(six.length, 6);
      expect(six, eight.substring(2));
    });

    test('keeps leading zeros', () {
      // A code whose numeric value has fewer digits than the requested
      // length must be left-padded, never shortened: the published
      // eight-digit vector 07081804 starts with a zero.
      final config = TotpConfig(
        secret: Uint8List.fromList(ascii.encode('12345678901234567890')),
        digits: 8,
      );
      final codes = <String>[];
      for (var step = 0; step < 200; step++) {
        codes.add(
          generateTotpCode(
            config,
            DateTime.fromMillisecondsSinceEpoch(
              1111111080 * 1000 + step * 30000,
              isUtc: true,
            ),
          ),
        );
      }

      expect(codes.every((code) => code.length == 8), isTrue);
      expect(codes, contains('07081804'));
    });

    test('is stable inside one period and changes on the boundary', () {
      final config = TotpConfig(secret: secret, period: 30);
      // 1111111080 is a multiple of 30, so it starts a time step.
      final start = DateTime.fromMillisecondsSinceEpoch(
        1111111080 * 1000,
        isUtc: true,
      );

      final insidePeriod = generateTotpCode(config, start);
      expect(
        generateTotpCode(config, start.add(const Duration(seconds: 29))),
        insidePeriod,
      );
      expect(
        generateTotpCode(config, start.add(const Duration(seconds: 30))),
        isNot(insidePeriod),
      );
    });

    test('honours a custom period', () {
      final config = TotpConfig(secret: secret, period: 60);
      // 1111111080 is also a multiple of 60.
      final start = DateTime.fromMillisecondsSinceEpoch(
        1111111080 * 1000,
        isUtc: true,
      );

      expect(
        generateTotpCode(config, start.add(const Duration(seconds: 59))),
        generateTotpCode(config, start),
      );
      expect(
        generateTotpCode(config, start.add(const Duration(seconds: 60))),
        isNot(generateTotpCode(config, start)),
      );
    });

    test('uses UTC counter steps regardless of the local timezone', () {
      final config = TotpConfig(secret: secret);
      final utc = DateTime.fromMillisecondsSinceEpoch(
        1234567890 * 1000,
        isUtc: true,
      );
      final local = utc.toLocal();

      expect(generateTotpCode(config, local), generateTotpCode(config, utc));
    });
  });

  group('totpSecondsRemaining', () {
    final secret = base32TestSecret;

    test('counts down from the period to one', () {
      final config = TotpConfig(secret: secret, period: 30);
      // 1111111080 is a multiple of 30, so it starts a time step.
      final start = DateTime.fromMillisecondsSinceEpoch(
        1111111080 * 1000,
        isUtc: true,
      );

      expect(totpSecondsRemaining(config, start), 30);
      expect(
        totpSecondsRemaining(config, start.add(const Duration(seconds: 1))),
        29,
      );
      expect(
        totpSecondsRemaining(config, start.add(const Duration(seconds: 29))),
        1,
      );
      expect(
        totpSecondsRemaining(config, start.add(const Duration(seconds: 30))),
        30,
      );
    });

    test('never returns zero', () {
      final config = TotpConfig(secret: secret, period: 30);
      for (var second = 0; second < 90; second++) {
        final value = totpSecondsRemaining(
          config,
          DateTime.fromMillisecondsSinceEpoch(
            1111111080 * 1000 + second * 1000,
            isUtc: true,
          ),
        );
        expect(value, inInclusiveRange(1, 30));
      }
    });
  });

  group('TotpAlgorithm', () {
    test('parses the otpauth names case-insensitively', () {
      expect(TotpAlgorithm.fromOtpName('SHA1'), TotpAlgorithm.sha1);
      expect(TotpAlgorithm.fromOtpName('sha256'), TotpAlgorithm.sha256);
      expect(TotpAlgorithm.fromOtpName('Sha512'), TotpAlgorithm.sha512);
    });

    test('rejects unknown algorithms', () {
      expect(() => TotpAlgorithm.fromOtpName('MD5'), throwsFormatException);
    });
  });
}

/// "Hello!\xDE\xAD\xBE\xEF": the example secret from RFC 4226 that most
/// authenticator tutorials use, base32-encoded.
final Uint8List base32TestSecret = base32Decode('JBSWY3DPEHPK3PXP');
