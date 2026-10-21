import '../../vault/domain/vault_item.dart';
import '../../vault/domain/vault_summary.dart';
import '../domain/vault_health_report.dart';

/// Builds the [VaultHealthReport] for [summary] and [items].
///
/// Counts come from [summary] (the repositories' own aggregation, so
/// the numbers match the dashboard hero); the two lists come from
/// [items] so the report can name the entries. Group order follows
/// the order the items arrive in, so the output is deterministic.
VaultHealthReport buildVaultHealthReport({
  required VaultSummary summary,
  required List<VaultItem> items,
}) {
  final weakEntries = items
      .where((item) => item.strengthScore < weakPasswordThreshold)
      .toList(growable: false);

  final bySecret = <String, List<VaultItem>>{};
  for (final item in items) {
    bySecret.putIfAbsent(item.secret, () => <VaultItem>[]).add(item);
  }

  final sharedSecretGroups = <SharedSecretGroup>[];
  for (final entry in bySecret.entries) {
    if (entry.value.length < 2) {
      continue;
    }
    sharedSecretGroups.add(
      SharedSecretGroup(items: List<VaultItem>.unmodifiable(entry.value)),
    );
  }

  return VaultHealthReport(
    totalItems: summary.totalItems,
    weakItems: summary.weakItems,
    reusedItems: summary.reusedItems,
    securityScore: summary.securityScore,
    weakEntries: weakEntries,
    sharedSecretGroups: List<SharedSecretGroup>.unmodifiable(
      sharedSecretGroups,
    ),
  );
}
