# AGENTS.md — `lib/app`

The composition root and the shared presentation: `bootstrap/` builds every
concrete service once and mounts the tree, `theme/` owns the colors, the
spacing and the Material 3 themes, `design_system/` owns the reusable
widgets, `localization/` owns the locale preference. `lib/main.dart` is the
process entry point and does nothing else.

The map of this module: `mise run repo-map --module lib/app`.

## Invariants

- One composition root. Every concrete implementation — the storage, the
  crypto service, the biometric stack, the sync lifecycle — is instantiated
  in `bootstrap/password_manager_app.dart` and nowhere else. A screen never
  constructs a repository, a crypto service or a platform channel; it
  receives them.
- A platform branch lives in exactly one place. `resolveBiometricStack()`
  returns a sealed `BiometricStack` with one case per platform family,
  because two independent `defaultTargetPlatform` branches once paired the
  KeyStore provider with the self-prompting `local_auth` gate and produced
  two prompts per unlock. The same rule applies to the storage flag and to
  the sync defines.
- The storage choice is one flag: `vaultSqliteStorageEnabled` selects the
  encrypted SQLite repository or the encrypted blob, and both implement the
  same `VaultRepository`.
- The sync lifecycle is optional: `buildDeviceSyncLifecycle()` returns
  `null` when the backend is not configured, and the widget tree receives a
  null resolver instead of a branch at every call site.
- The design system is the shared vocabulary: the reusable widgets live in
  `design_system/`, the colors and the spacing in `theme/`, and a feature
  does not define its own palette.
- The locale preference is a controller over the secure storage, and the
  generated localizations are the only source of the user-facing strings.

## How it is tested

- `test/widget_test.dart` — the application mounts and the shell renders.
- `test/features/home/presentation/app_shell_test.dart` — the shell and the
  navigation it mounts.
- `test/features/settings/presentation/settings_screen_test.dart` — the
  settings that the bootstrap wires.
- `test/features/security/presentation/security_gate_test.dart` — the gate
  that the bootstrap mounts above the shell.
- The feature tests that cover the screens the bootstrap hands the
  collaborators to.
- `scripts/publication_screenshots_test.dart` is a golden test: it compares
  the publication screenshots against the current UI. A visual change has to
  regenerate the PNGs in `docs/publication/screenshots/` in the same pull
  request.

## Do not touch

- The structure of the composition root. The bootstrap is long on purpose:
  one file that shows every concrete dependency of the app, in order.
  Splitting it hides the wiring.
- The sealed `BiometricStack` and its cases. The platform decision is
  resolved once, here; a second `defaultTargetPlatform` branch elsewhere
  brings back the two-prompt bug.
- The design system's public widgets and the theme constants: the screens
  depend on them, so a rename is a cross-feature change.
- `lib/l10n/app_localizations*.dart`. They are generated from
  `lib/l10n/app_*.arb` by `flutter gen-l10n`; edit the `.arb` files and
  regenerate.
- The `public_member_api_docs` lint and the other rules in
  `analysis_options.yaml`. Do not relax a rule to make a build pass.

## Boundaries

- Depends on: `lib/core/*` and `lib/features/*` — the bootstrap builds them,
  and the design system imports the item *types* it renders.
- Never imports: no feature imports `lib/app/bootstrap` — the composition
  root is the only place that wires the tree, and a feature never reaches it.
  A feature imports `lib/app` only for the design system, the theme and the
  localization. The one import in the other direction, from the design system
  to `lib/features/vault/domain`, is a *type*, never behavior.
- `lib/app/theme` and `lib/app/design_system` never import a service: they
  are presentation, not wiring.
