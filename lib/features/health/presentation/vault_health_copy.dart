// These strings belong in `lib/l10n/app_en.arb` (and the Spanish
// catalog), but this change is not allowed to edit the localization
// files. They live here, in one place, so moving them into the arb
// files later is a mechanical edit and so no screen contains
// scattered inline copy. Labels that already exist as keys are NOT
// duplicated here: the screen reads `vaultEntries`,
// `weakPasswords`, `reusedItems`, `securityScore`, `retry`,
// `dashboardDecryptError` and `dashboardDecryptErrorAdvice` from
// `context.l10n`.
//
// ignore_for_file: public_member_api_docs

/// Copy for the vault health report screen: the only place that
/// holds the strings this feature adds.
abstract final class VaultHealthCopy {
  // Title of the screen and of its dashboard entry point.
  static const String title = 'Vault health report';

  // Subtitle of the dashboard quick action that opens the report.
  static const String entryPointSubtitle =
      'See which passwords are weak and which ones share a secret.';

  // Header of the numbers panel.
  static const String eyebrow = 'Health';
  static const String numbersTitle = 'What the numbers mean';
  static const String numbersSubtitle =
      'The same numbers the dashboard shows, explained, so you know what to fix first.';

  // One-line explanations, one per metric. Each answers "what does
  // this number mean for me?".
  static const String totalItemsExplanation =
      'Everything Vaulta stores for you today. The report scores each entry separately.';
  static const String weakItemsExplanation =
      'Entries whose strength is below the strength threshold. They are the easiest to guess, so rotate them first.';
  static const String reusedItemsExplanation =
      'Entries that reuse a secret from another entry. One leak then unlocks several accounts.';
  static const String securityScoreExplanation =
      'Average strength of every entry, from 0 to 100. Higher is better.';

  // The two actionable lists.
  static const String weakSectionTitle = 'Weak passwords to rotate';
  static const String weakSectionSubtitle =
      'Every entry below the strength threshold needs a fresh, unique secret. Tap one to review it.';
  static const String sharedSectionTitle = 'Shared secrets';
  static const String sharedSectionSubtitle =
      'These entries store the same secret. Give each account its own so one leak stays contained.';

  // Empty states. "Healthy" covers both "nothing to fix" and "nothing
  // scored yet".
  static const String healthyTitle = 'Your vault is healthy';
  static const String healthyBody =
      'No weak passwords and no shared secrets. Nothing needs your attention right now.';
  static const String emptyVaultBody =
      'There is nothing to score yet. Create your first entry and Vaulta starts the report.';

  // Group header inside the shared-secrets list.
  static String sharedGroupLabel(int count) =>
      '$count entries share this secret';
}
