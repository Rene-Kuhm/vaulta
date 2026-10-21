import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/features/totp/domain/otp_auth_uri.dart';
import 'package:gestor_contrasenas/features/totp/domain/totp.dart';

void main() {
  group('parseOtpAuthUri', () {
    test('parses the canonical Google Authenticator URI', () {
      final parsed = parseOtpAuthUri(
        'otpauth://totp/GitHub:leo@example.com'
        '?secret=JBSWY3DPEHPK3PXP&issuer=GitHub',
      );

      expect(parsed.issuer, 'GitHub');
      expect(parsed.account, 'leo@example.com');
      expect(parsed.secret, 'JBSWY3DPEHPK3PXP');
      expect(parsed.digits, 6);
      expect(parsed.period, 30);
      expect(parsed.algorithm, TotpAlgorithm.sha1);
    });

    test('parses percent-encoded labels and every parameter', () {
      final parsed = parseOtpAuthUri(
        'otpauth://totp/ACME%20Co%3Ajohn.doe%40email.com'
        '?secret=JBSWY3DPEHPK3PXP'
        '&issuer=ACME%20Co&algorithm=SHA256&digits=8&period=60',
      );

      expect(parsed.issuer, 'ACME Co');
      expect(parsed.account, 'john.doe@email.com');
      expect(parsed.digits, 8);
      expect(parsed.period, 60);
      expect(parsed.algorithm, TotpAlgorithm.sha256);
    });

    test(
      'takes the issuer from the label prefix when the parameter is absent',
      () {
        final parsed = parseOtpAuthUri(
          'otpauth://totp/Bank%3Aalice%40bank.test?secret=JBSWY3DPEHPK3PXP',
        );

        expect(parsed.issuer, 'Bank');
        expect(parsed.account, 'alice@bank.test');
      },
    );

    test('keeps an account without an issuer prefix', () {
      final parsed = parseOtpAuthUri(
        'otpauth://totp/alice%40bank.test?secret=JBSWY3DPEHPK3PXP',
      );

      expect(parsed.issuer, isNull);
      expect(parsed.account, 'alice@bank.test');
    });

    test('defaults algorithm to SHA1 and period to 30 when omitted', () {
      final parsed = parseOtpAuthUri(
        'otpauth://totp/alice?secret=JBSWY3DPEHPK3PXP',
      );

      expect(parsed.algorithm, TotpAlgorithm.sha1);
      expect(parsed.period, 30);
      expect(parsed.digits, 6);
    });

    test('exposes a ready-to-use TOTP configuration', () {
      final parsed = parseOtpAuthUri(
        'otpauth://totp/GitHub:leo@example.com'
        '?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&digits=8&period=45',
      );

      final config = parsed.totpConfig;
      expect(config.digits, 8);
      expect(config.period, 45);
      expect(config.algorithm, TotpAlgorithm.sha1);
      expect(config.secret.length, 10);
    });

    test('produces the code a phone authenticator shows', () {
      // RFC 6238 Appendix B seed "12345678901234567890", base32-encoded,
      // at T=59 must give the published 94287082 with eight digits and
      // 287082 with six.
      const rfcSeed = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
      final at = DateTime.fromMillisecondsSinceEpoch(59000, isUtc: true);

      expect(
        generateTotpCode(
          parseOtpAuthUri(
            'otpauth://totp/Example:alice@example.com'
            '?secret=$rfcSeed&digits=8',
          ).totpConfig,
          at,
        ),
        '94287082',
      );
      expect(
        generateTotpCode(
          parseOtpAuthUri(
            'otpauth://totp/Example:alice@example.com?secret=$rfcSeed',
          ).totpConfig,
          at,
        ),
        '287082',
      );
    });

    test('rejects HOTP URIs explicitly', () {
      expect(
        () => parseOtpAuthUri(
          'otpauth://hotp/Example:alice?secret=JBSWY3DPEHPK3PXP&counter=0',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('HOTP'),
          ),
        ),
      );
    });

    test('rejects a URI without a secret', () {
      expect(
        () => parseOtpAuthUri('otpauth://totp/Example:alice?issuer=Example'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('secret'),
          ),
        ),
      );
    });

    test('rejects a malformed base32 secret', () {
      expect(
        () => parseOtpAuthUri('otpauth://totp/alice?secret=NOT-BASE32'),
        throwsFormatException,
      );
    });

    test('rejects unsupported digit counts', () {
      expect(
        () => parseOtpAuthUri(
          'otpauth://totp/alice?secret=JBSWY3DPEHPK3PXP&digits=7',
        ),
        throwsFormatException,
      );
    });

    test('rejects unsupported algorithms', () {
      expect(
        () => parseOtpAuthUri(
          'otpauth://totp/alice?secret=JBSWY3DPEHPK3PXP&algorithm=MD5',
        ),
        throwsFormatException,
      );
    });

    test('rejects a non-positive period', () {
      for (final period in ['0', '-30', 'abc']) {
        expect(
          () => parseOtpAuthUri(
            'otpauth://totp/alice?secret=JBSWY3DPEHPK3PXP&period=$period',
          ),
          throwsFormatException,
          reason: 'period $period must be rejected',
        );
      }
    });

    test('rejects unknown types and foreign schemes', () {
      expect(
        () => parseOtpAuthUri('otpauth://motp/alice?secret=JBSWY3DPEHPK3PXP'),
        throwsFormatException,
      );
      expect(
        () => parseOtpAuthUri('https://example.com/?secret=JBSWY3DPEHPK3PXP'),
        throwsFormatException,
      );
      expect(() => parseOtpAuthUri('not a uri at all'), throwsFormatException);
    });

    test('rejects a URI without an account label', () {
      expect(
        () => parseOtpAuthUri('otpauth://totp/?secret=JBSWY3DPEHPK3PXP'),
        throwsFormatException,
      );
    });
  });
}
