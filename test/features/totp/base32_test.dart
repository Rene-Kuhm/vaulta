import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/features/totp/domain/base32.dart';

void main() {
  group('base32Decode', () {
    test('decodes the RFC 4648 test vectors', () {
      const vectors = {
        'MY======': 'f',
        'MZXQ====': 'fo',
        'MZXW6===': 'foo',
        'MZXW6YQ=': 'foob',
        'MZXW6YTB': 'fooba',
        'MZXW6YTBOI======': 'foobar',
      };

      vectors.forEach((encoded, expected) {
        expect(
          utf8.decode(base32Decode(encoded)),
          expected,
          reason: 'decoding $encoded',
        );
      });
    });

    test('accepts lowercase input', () {
      expect(utf8.decode(base32Decode('mzxw6ytboi======')), 'foobar');
    });

    test('ignores spaces and padding', () {
      expect(utf8.decode(base32Decode('MZXW 6YTB OI')), 'foobar');
      expect(utf8.decode(base32Decode('mzxw 6ytb oi======')), 'foobar');
      expect(utf8.decode(base32Decode('MZXW6YTB')), 'fooba');
    });

    test('decodes a realistic authenticator secret', () {
      // "Hello!\xDE\xAD\xBE\xEF" is the RFC 4226 / Google
      // Authenticator example secret used in most tutorials.
      expect(base32Decode('JBSWY3DPEHPK3PXP').toList(), [
        72,
        101,
        108,
        108,
        111,
        33,
        222,
        173,
        190,
        239,
      ]);
    });

    test('rejects an empty secret', () {
      expect(() => base32Decode(''), throwsFormatException);
      expect(() => base32Decode('   '), throwsFormatException);
      expect(() => base32Decode('========'), throwsFormatException);
    });

    test('rejects characters outside the base32 alphabet', () {
      for (final input in ['MZXW6YTB1', 'MZXW6YTB0', 'MZXW6YTB!', 'MZXW-YTB']) {
        expect(
          () => base32Decode(input),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('base32'),
            ),
          ),
          reason: 'input $input must be rejected',
        );
      }
    });

    test('rejects an impossible length', () {
      for (final input in ['A', 'ABC', 'ABCDEF']) {
        expect(() => base32Decode(input), throwsFormatException);
      }
    });

    test('rejects padding in the middle of the secret', () {
      expect(() => base32Decode('MZ=XW6YTB'), throwsFormatException);
    });

    test('rejects a padded secret whose block length is wrong', () {
      expect(() => base32Decode('MZXW6YTB='), throwsFormatException);
    });
  });
}
