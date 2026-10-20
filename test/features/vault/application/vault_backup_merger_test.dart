import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/features/vault/application/vault_backup_merger.dart';

import '../../backup/backup_test_support.dart';

void main() {
  const merger = VaultBackupMerger();

  final existing = testItem(
    id: 'existing-1',
    title: 'GitHub',
    website: 'github.com',
    secret: 'Old!Secret1',
  );

  test('plans add, keep-both and skip', () {
    final plan = merger.plan(
      backupItems: [
        // Identical except for whitespace/case: exact duplicate.
        testItem(
          id: 'backup-1',
          title: ' github ',
          website: 'GitHub.com',
          secret: 'Old!Secret1',
        ),
        // Same identity, different secret: conflict, keep both.
        testItem(
          id: 'backup-2',
          title: 'GitHub',
          website: 'github.com',
          secret: 'New!Secret2',
        ),
        testItem(id: 'backup-3', title: 'Bank', secret: 'B4nk!Secret'),
        // Repeated inside the backup itself.
        testItem(id: 'backup-4', title: 'Bank', secret: 'B4nk!Secret'),
      ],
      existingItems: [existing],
    );

    expect(plan.entries.map((entry) => entry.action), [
      VaultBackupMergeAction.skipDuplicate,
      VaultBackupMergeAction.keepBoth,
      VaultBackupMergeAction.add,
      VaultBackupMergeAction.skipDuplicate,
    ]);
    expect(plan.newCount, 1);
    expect(plan.conflictCount, 1);
    expect(plan.duplicateCount, 2);
    expect(plan.importCount, 2);
  });

  test('different notes are a conflict, not a duplicate', () {
    final plan = merger.plan(
      backupItems: [
        testItem(
          id: 'backup-1',
          title: 'GitHub',
          website: 'github.com',
          secret: 'Old!Secret1',
          notes: 'changed',
        ),
      ],
      existingItems: [existing],
    );
    expect(plan.entries.single.action, VaultBackupMergeAction.keepBoth);
  });

  test(
    'apply saves through the repository with fresh ids and suffix',
    () async {
      final repository = InMemoryVaultRepository([existing]);
      final result = await merger.apply(
        backupItems: [
          testItem(
            id: 'existing-1', // Same id as the existing entry.
            title: 'GitHub',
            website: 'github.com',
            secret: 'New!Secret2',
          ),
          testItem(id: 'backup-3', title: 'Bank', secret: 'B4nk!Secret'),
          testItem(
            id: 'backup-1',
            title: 'GitHub',
            website: 'github.com',
            secret: 'Old!Secret1',
          ),
        ],
        repository: repository,
        conflictSuffix: ' (restored)',
      );

      expect(result.imported, 2);
      expect(result.renamed, 1);
      expect(result.skippedDuplicates, 1);
      expect(repository.saved.length, 2);
      // The existing entry is untouched even though the backup reused
      // its id.
      final original = repository.items.firstWhere((i) => i.id == 'existing-1');
      expect(original.secret, 'Old!Secret1');
      expect(original.title, 'GitHub');
      for (final saved in repository.saved) {
        expect(saved.id, isNot(anyOf('existing-1', 'backup-3', 'backup-1')));
      }
      expect(repository.saved.map((item) => item.title), [
        'GitHub (restored)',
        'Bank',
      ]);
      expect(repository.items.length, 3);
    },
  );

  test('apply re-plans against the current vault', () async {
    final backup = [testItem(id: 'b', title: 'Bank', secret: 'B4nk!Secret')];
    final repository = InMemoryVaultRepository();
    await merger.apply(
      backupItems: backup,
      repository: repository,
      conflictSuffix: ' (restored)',
    );
    // A second restore of the same backup adds nothing.
    final second = await merger.apply(
      backupItems: backup,
      repository: repository,
      conflictSuffix: ' (restored)',
    );
    expect(second.imported, 0);
    expect(second.skippedDuplicates, 1);
    expect(repository.items.length, 1);
  });
}
