# AGENTS.md — `lib/features/home`

The unlocked shell: the three-tab `IndexedStack` (Vault, Access, Settings), the bottom navigation, and the silent in-app update check that runs once on mount.
Its edge is the tab set — this module mounts screens and forwards services, and it owns no use case of its own.

The map of this module: `mise run repo-map --module lib/features/home`.

## Invariants

- The shell mounts exactly three tabs in an `IndexedStack`, so switching tabs keeps each tab's state instead of rebuilding it.
- `repository`, `securityController` and `localeController` are required; the optional ones (`conflictResolver`, `revocationService`, `secureStorage`, `vaultChanges`) are forwarded only to the children that consume them.
- The shell constructs one service of its own, the in-app `UpdateService`, and builds it from the injected `secureStorage`; every other collaborator is received.
- The update check runs once on mount, shows a snackbar only for a build that was not prompted before, and marks the build as prompted once it does.
- `FeaturePlaceholderScreen` is the shared "coming soon" page; its copy is passed in by the caller, not read here.

## How it is tested

- `test/features/home/presentation/app_shell_test.dart` — pins the tab navigation: the Vault, Access and Settings labels are present and tapping Settings switches the visible tab.

## Do not touch

- The tab list and its order — the navigation labels come from `lib/l10n/app_*.arb` and the widget tree here.
- The `UpdateService` construction — the release channel, the signature verification and the download live in `lib/core/update`; the shell only starts the check and shows its result.
- `lib/l10n/app_*.arb` without `flutter gen-l10n` — the generated localizations are never hand-edited.
- The `IndexedStack` — replacing it with a rebuild-per-tab drops each tab's state on every switch.

## Boundaries

- Depends on: `lib/features/vault`, `lib/features/access` and `lib/features/settings` — the three tabs it mounts.
- Depends on: `lib/core/security`, `lib/core/sync` and `lib/core/update` — the repository, the controller, the conflict and revocation services and the update service it forwards.
- Depends on: `lib/app` — the design system, the theme, the locale controller and the `context.l10n` extension.
- Never imports: `lib/core/storage` or `lib/features/*/application` — the shell mounts screens, it never orchestrates their use cases.
