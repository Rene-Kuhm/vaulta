import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';

void main() {
  const itemWithoutHistory = VaultItem(
    id: 'gh',
    title: 'GitHub',
    username: 'leo',
    secret: 'Current!2026',
    category: VaultCategory.work,
    strengthScore: 80,
    lastUpdatedLabel: 'Updated now',
  );

  group('password history rotation', () {
    test('records the previous secret with the instant it was replaced', () {
      final replacedAt = DateTime.utc(2026, 3, 4, 10, 22);

      final history = vaultPasswordHistoryAfterRotation(
        const <PasswordHistoryEntry>[],
        previousSecret: 'OldPass!2025',
        nextSecret: 'NewPass!2026',
        replacedAt: replacedAt,
      );

      expect(history, hasLength(1));
      expect(history.single.secret, 'OldPass!2025');
      expect(history.single.replacedAt, replacedAt);
    });

    test('records nothing when the secret did not change', () {
      final existing = [
        PasswordHistoryEntry(
          secret: 'Older!2024',
          replacedAt: DateTime.utc(2024, 1, 1),
        ),
      ];

      final history = vaultPasswordHistoryAfterRotation(
        existing,
        previousSecret: 'Current!2026',
        nextSecret: 'Current!2026',
        replacedAt: DateTime.utc(2026, 3, 4),
      );

      expect(history, same(existing));
      expect(history, hasLength(1));
    });

    test('never records an empty secret', () {
      final history = vaultPasswordHistoryAfterRotation(
        const <PasswordHistoryEntry>[],
        previousSecret: '',
        nextSecret: 'NewPass!2026',
        replacedAt: DateTime.utc(2026, 3, 4),
      );

      expect(history, isEmpty);
    });

    test('never appends the same secret twice in a row', () {
      final first = vaultPasswordHistoryAfterRotation(
        const <PasswordHistoryEntry>[],
        previousSecret: 'Rotated!2025',
        nextSecret: 'Current!2026',
        replacedAt: DateTime.utc(2025, 6, 1),
      );

      final second = vaultPasswordHistoryAfterRotation(
        first,
        previousSecret: 'Rotated!2025',
        nextSecret: 'Currenter!2026',
        replacedAt: DateTime.utc(2026, 3, 4),
      );

      expect(second, hasLength(1));
      expect(second.single.secret, 'Rotated!2025');
    });

    test('keeps the newest entry last and the oldest entry first', () {
      final first = vaultPasswordHistoryAfterRotation(
        const <PasswordHistoryEntry>[],
        previousSecret: 'One!2024',
        nextSecret: 'Two!2025',
        replacedAt: DateTime.utc(2024, 5, 1),
      );
      final second = vaultPasswordHistoryAfterRotation(
        first,
        previousSecret: 'Two!2025',
        nextSecret: 'Three!2026',
        replacedAt: DateTime.utc(2025, 5, 1),
      );

      expect(second.map((entry) => entry.secret), ['One!2024', 'Two!2025']);
    });

    test('caps the history at $vaultPasswordHistoryLimit entries and drops the '
        'oldest', () {
      var history = const <PasswordHistoryEntry>[];
      const total = vaultPasswordHistoryLimit + 2;

      for (var i = 0; i < total; i++) {
        history = vaultPasswordHistoryAfterRotation(
          history,
          previousSecret: 'secret-$i',
          nextSecret: 'secret-${i + 1}',
          replacedAt: DateTime.utc(2026, 1, 1).add(Duration(days: i)),
        );
      }

      expect(history, hasLength(vaultPasswordHistoryLimit));
      expect(history.first.secret, 'secret-2');
      expect(history.last.secret, 'secret-${total - 1}');
    });

    test('newest-first accessor reverses the stored order', () {
      final history = vaultPasswordHistoryAfterRotation(
        vaultPasswordHistoryAfterRotation(
          const <PasswordHistoryEntry>[],
          previousSecret: 'One!2024',
          nextSecret: 'Two!2025',
          replacedAt: DateTime.utc(2024, 5, 1),
        ),
        previousSecret: 'Two!2025',
        nextSecret: 'Three!2026',
        replacedAt: DateTime.utc(2025, 5, 1),
      );

      expect(
        VaultItem(
          id: 'gh',
          title: 'GitHub',
          username: 'leo',
          secret: 'Three!2026',
          category: VaultCategory.work,
          strengthScore: 80,
          lastUpdatedLabel: 'Updated now',
          passwordHistory: history,
        ).passwordHistoryNewestFirst.map((entry) => entry.secret),
        ['Two!2025', 'One!2024'],
      );
    });
  });

  group('password history serialization', () {
    test('an item without history serializes exactly as before', () {
      // Pinned literal from the pre-history payload: adding the optional
      // field must not change one byte of an existing item.
      expect(
        jsonEncode(itemWithoutHistory.toJson()),
        '{"id":"gh","title":"GitHub","username":"leo",'
        '"secret":"Current!2026","category":"work",'
        '"strengthScore":80,"lastUpdatedLabel":"Updated now",'
        '"website":null,"notes":null,"updatedAt":null}',
      );
      expect(
        itemWithoutHistory.toJson().containsKey('passwordHistory'),
        isFalse,
      );
    });

    test('round-trips the history entries through JSON', () {
      final item = VaultItem(
        id: 'gh',
        title: 'GitHub',
        username: 'leo',
        secret: 'Current!2026',
        category: VaultCategory.work,
        strengthScore: 80,
        lastUpdatedLabel: 'Updated now',
        passwordHistory: [
          PasswordHistoryEntry(
            secret: 'OldPass!2025',
            replacedAt: DateTime.utc(2025, 3, 4, 10, 22),
          ),
          PasswordHistoryEntry(
            secret: 'OlderPass!2024',
            replacedAt: DateTime.utc(2024, 3, 4, 9, 15),
          ),
        ],
      );

      final decoded = VaultItem.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(item.toJson())) as Map),
      );

      expect(decoded.passwordHistory, item.passwordHistory);
      expect(jsonEncode(decoded.toJson()), jsonEncode(item.toJson()));
    });

    test('decodes a payload written before the field existed', () {
      final decoded = VaultItem.fromJson(<String, dynamic>{
        'id': 'gh',
        'title': 'GitHub',
        'username': 'leo',
        'secret': 'Current!2026',
        'category': 'work',
        'strengthScore': 80,
        'lastUpdatedLabel': 'Updated now',
      });

      expect(decoded.passwordHistory, isEmpty);
    });

    test('copyWith preserves the history when it is not replaced', () {
      final item = itemWithoutHistory.copyWith(
        passwordHistory: [
          PasswordHistoryEntry(
            secret: 'OldPass!2025',
            replacedAt: DateTime.utc(2025, 3, 4),
          ),
        ],
      );

      expect(item.copyWith(title: 'GitHub work').passwordHistory, hasLength(1));
    });
  });
}
