# AGENTS.md — `lib/features/access`

The "Access & Autofill" tab. It owns the explanation of what the native Android autofill service fills today, plus the unlock posture that gates every fill request: the locked/unlocked pill and an explicit "lock vault now" action.
Its edge is the platform — it changes no Android setting, it only tells the user what the service does and lets them re-lock the vault from this tab.

The map of this module: `mise run repo-map --module lib/features/access`.

## Invariants

- The tab changes no system setting: picking Vaulta as the autofill provider stays a user action in Android's own settings, so no setup walkthrough is rendered here.
- The unlock pill and the "lock vault now" button both read `VaultSecurityController.isUnlocked`; the button is disabled while the vault is locked.
- `securityController` and `repository` are both required constructor arguments, so the tab cannot be mounted half-wired and silently no-op.
- Every string comes from `context.l10n`; this file holds no inline copy.

## How it is tested

- `test/features/access/presentation/access_screen_test.dart` — pins the section header and the "Lock vault now" action, and asserts (in English and in Spanish) that no autofill setup walkthrough is rendered.

## Do not touch

- The autofill MethodChannel and its Kotlin counterpart — the fill protocol lives in `lib/features/autofill`; renaming a channel is a two-file change.
- `lib/l10n/app_en.arb` / `lib/l10n/app_es.arb` without running `flutter gen-l10n`: `lib/l10n/app_localizations*.dart` is generated.
- The `AccessScreen` constructor arguments — the bootstrap and `AppShell` mount the screen with exactly those.
- The `repository` argument — it is unused at the UI layer but kept for parity; removing it is a coordinated change in both mount points.
- The position of this tab in the navigation — the tab order belongs to `lib/features/home`.

## Boundaries

- Depends on: `lib/core/security` — `VaultSecurityController` for the unlock state, `VaultRepository` as the tab's read port.
- Depends on: `lib/app` — the shared design system, the theme and the `context.l10n` extension.
- Never imports: `lib/features/autofill` — this tab describes the service; the fill protocol is another module's contract.
- Never imports: `lib/core/storage` or `lib/core/sync` — the tab reads through the repository and knows nothing about the storage implementation.
