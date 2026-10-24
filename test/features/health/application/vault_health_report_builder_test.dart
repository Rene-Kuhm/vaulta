import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/features/health/application/vault_health_report_builder.dart';
import 'package:gestor_contrasenas/features/health/domain/vault_health_report.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_summary.dart';

void main() {
  group('buildVaultHealthReport', () {
    test('keeps only entries below the weak threshold', () {
      final report = buildVaultHealthReport(
        summary: _summary(),
        items: [
          _item(id: 'a', title: 'Below', strength: weakPasswordThreshold - 1),
          _item(id: 'b', title: 'At', strength: weakPasswordThreshold),
          _item(id: 'c', title: 'Above', strength: weakPasswordThreshold + 20),
        ],
      );

      expect(report.weakEntries.map((item) => item.title), ['Below']);
      expect(report.isHealthy, isFalse);
    });

    test('groups only secrets shared by two or more entries', () {
      final report = buildVaultHealthReport(
        summary: _summary(),
        items: [
          _item(id: 'a', title: 'Shared A', strength: 95, secret: 'dup'),
          _item(id: 'b', title: 'Shared B', strength: 95, secret: 'dup'),
          _item(id: 'c', title: 'Single', strength: 95, secret: 'solo'),
        ],
      );

      expect(report.sharedSecretGroups, hasLength(1));
      expect(report.sharedSecretGroups.single.items.map((item) => item.title), [
        'Shared A',
        'Shared B',
      ]);
      expect(report.sharedEntryCount, 2);
    });

    test('reports healthy when nothing is weak or shared', () {
      final report = buildVaultHealthReport(
        summary: _summary(),
        items: [
          _item(id: 'a', title: 'Strong A', strength: 95, secret: 'one'),
          _item(id: 'b', title: 'Strong B', strength: 88, secret: 'two'),
        ],
      );

      expect(report.weakEntries, isEmpty);
      expect(report.sharedSecretGroups, isEmpty);
      expect(report.isHealthy, isTrue);
    });

    test('is healthy on an empty vault', () {
      final report = buildVaultHealthReport(
        summary: _summary(),
        items: const [],
      );

      expect(report.isHealthy, isTrue);
      expect(report.sharedEntryCount, 0);
    });
  });
}

VaultSummary _summary() {
  return const VaultSummary(
    totalItems: 3,
    weakItems: 1,
    reusedItems: 2,
    securityScore: 80,
    connectedDevices: 1,
    syncEnabled: false,
  );
}

VaultItem _item({
  required String id,
  required String title,
  required int strength,
  String? secret,
}) {
  return VaultItem(
    id: id,
    title: title,
    username: '$id@vaulta.app',
    secret: secret ?? 'secret-$id',
    category: VaultCategory.personal,
    strengthScore: strength,
    lastUpdatedLabel: 'Updated now',
  );
}
