# AGENTS.md — `lib/features/health`

The vault health report: the dashboard's score broken into the entries a user can act on. It owns the weak-password list, the shared-secret list and the explanation of each number. Its edge is read-only — it reads the vault through the repository and never writes.

The map of this module: `mise run repo-map --module lib/features/health`.

## Invariants

- The weak threshold is `weakPasswordThreshold` (80), kept identical to the threshold the storage repositories use to build `VaultSummary.weakItems`. If one moves, the other must move too, or the report's counts and its weak list disagree.
- The scalar numbers come from the repository summary, so the report shows exactly the dashboard numbers; only the two lists are derived from the items.
- A shared-secret group holds only entries that store the exact same secret, and it never exposes the secret itself.
- Group order follows the order the items arrive in, so the output is deterministic.
- The screen reads the vault only through the injected `VaultRepository`; it owns no platform channel of its own.

## How it is tested

- `test/features/health/application/vault_health_report_builder_test.dart` — pins the derivation: only entries below the threshold are weak, only secrets shared by two or more entries are grouped, and an empty vault is healthy.
- `test/features/health/presentation/vault_health_report_screen_test.dart` — pins the screen: the repository counts, both lists, the healthy state, opening an entry from both lists, no overflow at phone size, and the retry action when the vault cannot be read.

## Do not touch

- `weakPasswordThreshold` — it mirrors the storage repositories on purpose; a change is a two-place edit, not a local one.
- The English strings in `presentation/vault_health_copy.dart` — they are copy, not logic; moving them into the `.arb` files is a localization change that ships with `flutter gen-l10n`.
- Building `VaultHealthReport` by hand — use `buildVaultHealthReport`, which performs the derivation.
- The read-only nature of the report — tapping an entry opens the detail screen; editing stays in the vault tab.

## Boundaries

- Depends on: `lib/features/vault/domain` — `VaultItem` and `VaultSummary`, the vocabulary of the report.
- Depends on: `lib/core/security` — `VaultRepository`, the only way the report reads the vault.
- Depends on: `lib/features/vault/presentation` — the read-only entry detail screen it opens.
- Never imports: `lib/core/storage` or `lib/core/sync` — the report never touches the storage implementation or the sync layer directly.
