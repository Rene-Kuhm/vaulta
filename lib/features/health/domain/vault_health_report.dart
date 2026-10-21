import '../../vault/domain/vault_item.dart';

/// Strength score below which an entry counts as weak.
///
/// Kept identical to the threshold the storage repositories use when
/// they build `VaultSummary.weakItems`: both
/// `SqliteVaultRepository.fetchSummary` and
/// `LocalEncryptedVaultRepository.fetchSummary` count
/// `item.strengthScore < 80`. If that threshold ever moves, it must
/// move here too, otherwise the report's counts and its weak list
/// would disagree.
const int weakPasswordThreshold = 80;

/// Two or more entries that store the exact same secret.
///
/// The group deliberately does not expose the secret itself: the
/// report only needs to tell the user which entries collide so they
/// can be given distinct secrets.
class SharedSecretGroup {
  /// Builds a group from the [items] that share one secret. The
  /// caller must pass at least two entries; the builder enforces it.
  const SharedSecretGroup({required this.items});

  /// Entries that store the same secret, in repository order.
  final List<VaultItem> items;

  /// Number of entries in the group. Always two or more.
  int get entryCount => items.length;
}

/// Actionable breakdown of the vault's security posture.
///
/// The scalar counts are copied from the `VaultSummary` the
/// repository reports, so the report shows exactly the numbers the
/// dashboard hero shows. The lists are derived from the item list:
/// [weakEntries] holds the entries whose `strengthScore` is below
/// [weakPasswordThreshold], and [sharedSecretGroups] holds the
/// secrets used by two or more entries.
class VaultHealthReport {
  /// Builds a report. Use `buildVaultHealthReport` instead of
  /// constructing this directly; it performs the derivation.
  const VaultHealthReport({
    required this.totalItems,
    required this.weakItems,
    required this.reusedItems,
    required this.securityScore,
    required this.weakEntries,
    required this.sharedSecretGroups,
  });

  /// Total number of entries in the vault.
  final int totalItems;

  /// Number of entries below [weakPasswordThreshold], as reported by
  /// the repository summary.
  final int weakItems;

  /// Number of entries involved in a shared secret, as reported by
  /// the repository summary.
  final int reusedItems;

  /// Average strength across every entry, in the 0..100 range.
  final int securityScore;

  /// Entries whose `strengthScore` is below [weakPasswordThreshold].
  final List<VaultItem> weakEntries;

  /// Secrets used by two or more entries, each with its entries.
  final List<SharedSecretGroup> sharedSecretGroups;

  /// `true` when there is nothing to act on: no weak entry and no
  /// shared secret.
  bool get isHealthy => weakEntries.isEmpty && sharedSecretGroups.isEmpty;

  /// Number of entries that take part in at least one shared secret.
  int get sharedEntryCount =>
      sharedSecretGroups.fold(0, (sum, group) => sum + group.entryCount);
}
