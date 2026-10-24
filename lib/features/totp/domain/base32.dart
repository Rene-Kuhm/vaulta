import 'dart:typed_data';

/// The RFC 4648 base32 alphabet, uppercase. Decoding is
/// case-insensitive, so this is never exposed to callers.
const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// Characters that carry no bits in a base32 secret as authenticator
/// apps print it: spaces (Google Authenticator groups secrets in
/// blocks of four), tabs and line breaks from copied text.
const int _space = 0x20;
const int _tab = 0x09;
const int _lineFeed = 0x0A;
const int _carriageReturn = 0x0D;
const int _padding = 0x3D; // '='

/// Decodes a base32 secret (RFC 4648) into raw key bytes.
///
/// Accepts lowercase and uppercase letters, ignores spaces, tabs and
/// line breaks (authenticator apps and hand-typed secrets use them as
/// separators), and accepts optional `=` padding at the end.
///
/// Throws a [FormatException] for anything else — a character outside
/// the alphabet, padding anywhere but the end, or a length that no
/// base32 string can have. A secret that cannot be decoded must never
/// turn into a plausible-looking code: silently dropping bytes would
/// produce valid codes for the wrong key, so this decoder fails
/// instead of guessing.
Uint8List base32Decode(String input) {
  final buffer = StringBuffer();
  for (var index = 0; index < input.length; index++) {
    final unit = input.codeUnitAt(index);
    if (unit == _space ||
        unit == _tab ||
        unit == _lineFeed ||
        unit == _carriageReturn) {
      continue;
    }
    buffer.writeCharCode(unit >= 0x61 && unit <= 0x7A ? unit - 0x20 : unit);
  }

  var normalized = buffer.toString();
  if (normalized.isEmpty) {
    throw const FormatException('The base32 secret is empty.');
  }

  final paddingStart = normalized.indexOf('=');
  if (paddingStart >= 0) {
    for (var index = paddingStart; index < normalized.length; index++) {
      if (normalized.codeUnitAt(index) != _padding) {
        throw const FormatException(
          'Invalid base32 secret: padding is only allowed at the end.',
        );
      }
    }
    if (normalized.length % 8 != 0) {
      throw const FormatException(
        'Invalid base32 secret: padded secrets must be a multiple of 8 '
        'characters long.',
      );
    }
    normalized = normalized.substring(0, paddingStart);
  }

  if (normalized.isEmpty) {
    throw const FormatException('The base32 secret is empty.');
  }

  // Five bits per character: only these remainders can end a base32
  // string, because every other one leaves a partial byte.
  const validRemainders = {0, 2, 4, 5, 7};
  if (!validRemainders.contains(normalized.length % 8)) {
    throw FormatException(
      'Invalid base32 secret: ${normalized.length} characters is not a '
      'valid base32 length.',
    );
  }

  final bytes = <int>[];
  var accumulator = 0;
  var bits = 0;
  for (var index = 0; index < normalized.length; index++) {
    final char = normalized[index];
    final value = _alphabet.indexOf(char);
    if (value < 0) {
      throw FormatException(
        'Invalid base32 secret: "$char" is not in the base32 alphabet.',
      );
    }
    accumulator = (accumulator << 5) | value;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      bytes.add((accumulator >> bits) & 0xFF);
    }
  }

  return Uint8List.fromList(bytes);
}
