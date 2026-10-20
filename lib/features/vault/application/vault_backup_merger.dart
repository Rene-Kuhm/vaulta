import 'package:uuid/uuid.dart';

import '../../../core/security/vault_repository.dart';
import '../domain/vault_item.dart';
import 'vault_duplicate_detector.dart';

/// What restoring one backup item does to the vault.
enum VaultBackupMergeAction {
  /// No similar entry exists: the item is added as-is.
  add,

  /// A similar but not identical entry exists (per
  /// [VaultDuplicateDetector]): both are kept and the restored copy's
  /// title gets a suffix.
  keepBoth,

  /// An identical entry already exists: the item is skipped.
  skipDuplicate,
}

/// One backup item and the action a restore takes for it.
class VaultBackupMergeEntry {
  /// Builds an entry.
  const VaultBackupMergeEntry({required this.item, required this.action});

  /// The item as stored in the backup.
  final VaultItem item;

  /// What the restore does with [item].
  final VaultBackupMergeAction action;
}

/// The planned outcome of restoring a backup into the current vault.
class VaultBackupMergePlan {
  /// Builds a plan from its [entries].
  const VaultBackupMergePlan(this.entries);

  /// One entry per backup item, in backup order.
  final List<VaultBackupMergeEntry> entries;

  /// Items that will be added unchanged.
  int get newCount => _count(VaultBackupMergeAction.add);

  /// Items that will be added next to a similar existing entry.
  int get conflictCount => _count(VaultBackupMergeAction.keepBoth);

  /// Items that will be skipped as exact duplicates.
  int get duplicateCount => _count(VaultBackupMergeAction.skipDuplicate);

  /// Items that will be written (new plus kept-both).
  int get importCount => newCount + conflictCount;

  int _count(VaultBackupMergeAction action) =>
      entries.where((entry) => entry.action == action).length;
}

/// Summary of an applied restore.
class VaultBackupMergeResult {
  /// Builds a result.
  const VaultBackupMergeResult({
    required this.imported,
    required this.renamed,
    required this.skippedDuplicates,
  });

  /// Items written to the vault (including [renamed]).
  final int imported;

  /// Items written with the conflict suffix.
  final int renamed;

  /// Exact duplicates that were not written.
  final int skippedDuplicates;
}

/// Merges decrypted backup items into the vault without ever
/// overwriting or deleting an existing entry.
///
/// Rules (ADR-006): an exact duplicate (same normalized title,
/// username, website and notes, same category and identical secret) is
/// skipped; an entry that [VaultDuplicateDetector] flags but that is
/// not identical is kept alongside the existing one with a title
/// suffix; everything else is added. Every written item gets a fresh
/// id, so a restore can neither overwrite an existing entry nor
/// resurrect a sync tombstone.
class VaultBackupMerger {
  /// Builds a merger. [uuid] and [duplicates] are injectable for tests.
  const VaultBackupMerger({Uuid? uuid, VaultDuplicateDetector? duplicates})
    : _uuid = uuid ?? const Uuid(),
      _duplicates = duplicates ?? const VaultDuplicateDetector();

  final Uuid _uuid;
  final VaultDuplicateDetector _duplicates;

  /// Plans the merge of [backupItems] into [existingItems]. Items
  /// repeated inside the backup are compared against each other too.
  VaultBackupMergePlan plan({
    required List<VaultItem> backupItems,
    required List<VaultItem> existingItems,
  }) {
    final known = List<VaultItem>.of(existingItems);
    final entries = <VaultBackupMergeEntry>[];
    for (final item in backupItems) {
      final VaultBackupMergeAction action;
      if (known.any((existing) => _isExactDuplicate(item, existing))) {
        action = VaultBackupMergeAction.skipDuplicate;
      } else if (_duplicates.findDuplicate(item, known) != null) {
        action = VaultBackupMergeAction.keepBoth;
        known.add(item);
      } else {
        action = VaultBackupMergeAction.add;
        known.add(item);
      }
      entries.add(VaultBackupMergeEntry(item: item, action: action));
    }
    return VaultBackupMergePlan(List.unmodifiable(entries));
  }

  /// Re-plans against the repository's current items (the vault may
  /// have changed since the preview) and saves every non-duplicate
  /// through [VaultRepository.saveItem], so each item is re-encrypted
  /// with the vault DEK and emits the usual sync mutation.
  /// [conflictSuffix] is appended to the title of kept-both items.
  Future<VaultBackupMergeResult> apply({
    required List<VaultItem> backupItems,
    required VaultRepository repository,
    required String conflictSuffix,
  }) async {
    final plan = this.plan(
      backupItems: backupItems,
      existingItems: await repository.fetchItems(),
    );
    var imported = 0;
    var renamed = 0;
    for (final entry in plan.entries) {
      switch (entry.action) {
        case VaultBackupMergeAction.skipDuplicate:
          continue;
        case VaultBackupMergeAction.add:
          await repository.saveItem(entry.item.copyWith(id: _uuid.v4()));
        case VaultBackupMergeAction.keepBoth:
          await repository.saveItem(
            entry.item.copyWith(
              id: _uuid.v4(),
              title: '${entry.item.title}$conflictSuffix',
            ),
          );
          renamed++;
      }
      imported++;
    }
    return VaultBackupMergeResult(
      imported: imported,
      renamed: renamed,
      skippedDuplicates: plan.duplicateCount,
    );
  }

  bool _isExactDuplicate(VaultItem left, VaultItem right) {
    return left.secret == right.secret &&
        left.category == right.category &&
        _normalize(left.title) == _normalize(right.title) &&
        _normalize(left.username) == _normalize(right.username) &&
        _normalize(left.website ?? '') == _normalize(right.website ?? '') &&
        _normalize(left.notes ?? '') == _normalize(right.notes ?? '');
  }

  String _normalize(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }
}
