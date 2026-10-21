import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';

void main() {
  const itemWithoutOtp = VaultItem(
    id: 'gh',
    title: 'GitHub',
    username: 'leo',
    secret: 'StrongPass!2026',
    category: VaultCategory.work,
    strengthScore: 80,
    lastUpdatedLabel: 'Updated now',
  );

  const otpUri =
      'otpauth://totp/GitHub:leo@example.com'
      '?secret=JBSWY3DPEHPK3PXP&issuer=GitHub';

  group('VaultItem without otpAuthUri', () {
    test('serializes byte-identically to the pre-TOTP payload', () {
      // Pinned literal: items that never had a TOTP secret must keep
      // producing exactly the same JSON they always produced, so the
      // encrypted payload stays compatible with older clients.
      expect(
        jsonEncode(itemWithoutOtp.toJson()),
        '{"id":"gh","title":"GitHub","username":"leo",'
        '"secret":"StrongPass!2026","category":"work",'
        '"strengthScore":80,"lastUpdatedLabel":"Updated now",'
        '"website":null,"notes":null,"updatedAt":null}',
      );
    });

    test('never emits the otpAuthUri key', () {
      final json = itemWithoutOtp.toJson();

      expect(json.containsKey('otpAuthUri'), isFalse);
    });

    test('round-trips through JSON unchanged', () {
      final decoded = VaultItem.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(itemWithoutOtp.toJson())) as Map,
        ),
      );

      expect(decoded.otpAuthUri, isNull);
      expect(jsonEncode(decoded.toJson()), jsonEncode(itemWithoutOtp.toJson()));
    });

    test('decodes a payload written before the field existed', () {
      final decoded = VaultItem.fromJson(<String, dynamic>{
        'id': 'gh',
        'title': 'GitHub',
        'username': 'leo',
        'secret': 'StrongPass!2026',
        'category': 'work',
        'strengthScore': 80,
        'lastUpdatedLabel': 'Updated now',
      });

      expect(decoded.otpAuthUri, isNull);
      expect(decoded.title, 'GitHub');
    });
  });

  group('VaultItem with otpAuthUri', () {
    const itemWithOtp = VaultItem(
      id: 'gh',
      title: 'GitHub',
      username: 'leo',
      secret: 'StrongPass!2026',
      category: VaultCategory.work,
      strengthScore: 80,
      lastUpdatedLabel: 'Updated now',
      otpAuthUri: otpUri,
    );

    test('round-trips the URI through JSON', () {
      final decoded = VaultItem.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(itemWithOtp.toJson())) as Map,
        ),
      );

      expect(decoded.otpAuthUri, otpUri);
      expect(decoded.secret, 'StrongPass!2026');
    });

    test('keeps every pre-existing key in the same order', () {
      final json = itemWithOtp.toJson();

      expect(json.keys.toList(), [
        'id',
        'title',
        'username',
        'secret',
        'category',
        'strengthScore',
        'lastUpdatedLabel',
        'website',
        'notes',
        'updatedAt',
        'otpAuthUri',
      ]);
    });

    test('copyWith preserves the URI when it is not replaced', () {
      final copy = itemWithOtp.copyWith(title: 'GitHub work');

      expect(copy.otpAuthUri, otpUri);
      expect(copy.title, 'GitHub work');
    });

    test('copyWith can attach a URI to an item that had none', () {
      final copy = itemWithoutOtp.copyWith(otpAuthUri: otpUri);

      expect(copy.otpAuthUri, otpUri);
      expect(itemWithoutOtp.otpAuthUri, isNull);
    });
  });
}
