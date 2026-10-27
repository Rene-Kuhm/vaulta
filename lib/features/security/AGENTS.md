# AGENTS.md — `lib/features/security`

The lock gate: the stage machine that shows loading, onboarding, locked or unlocked, the unlock screen, and the capability panel. Its edge is the controller — the gate renders the stage the security core decides and never decides one itself.

The map of this module: `mise run repo-map --module lib/features/security`.

## Invariants

- The gate renders exactly one stage from `VaultSecurityController.stage` (loading, onboarding, locked, unlocked) and never chooses a stage.
- Leaving the unlocked stage pops every route above the gate on the root navigator (`popUntil(isFirst)`), so no screen that renders a secret survives the lock — a `PopScope` cannot veto it.
- Every failure is a `VaultSecurityMessageCode`, never a literal: the controller emits codes and this module maps them to copy.
- The ARB key of a code is `securityMessage` plus the code name in UpperCamelCase, and every code needs an entry in both `app_en.arb` and `app_es.arb`.
- A capability has three states (supported, unsupported, unknown); a probe that has not answered, or that throws, is `unknown` and is never worded as "not available".
- The biometric offer is read from `VaultSecurityController.canOfferBiometricUnlockButton`; the platform branch lives in the bootstrap (`resolveBiometricStack`), never here.

## How it is tested

- `test/features/security/presentation/security_gate_test.dart` — pins the stage machine: auto-lock on background, the idle timeout, revocation of the current device, the localized failure message, the lockout countdown and the "attempt cannot be stored" error.
- `test/features/security/presentation/security_gate_route_dismissal_test.dart` — pins that locking closes the export dialog, the entry detail screen and the bottom sheets, including routes that veto a pop.
- `test/features/security/presentation/security_capabilities_panel_test.dart` — pins the three capability states, that nothing is claimed before the probe answers, and that a throwing probe reports unknown.
- `test/features/security/presentation/vault_security_message_l10n_test.dart` — pins that every message code has English and Spanish copy, that the Spanish is translated, and that the ARB key follows the enum-name convention.

## Do not touch

- The `VaultSecurityMessageCode` enum — it lives in `lib/core/security`; a new code without its two ARB entries breaks the localization test.
- The auto-lock, idle-timeout and throttle parameters — they are the session policy of ADR-003, enforced in `lib/core/security`.
- The `securityMessage*` keys in `lib/l10n/app_*.arb` — the generated getters are read by `vaultSecurityMessageText`.
- The biometric unlock path — the prompt, the `CryptoObject` and the KeyStore envelope are `lib/core/security` plus Kotlin, not this module.

## Boundaries

- Depends on: `lib/core/security` — the controller, the message codes, the biometric capability and the security plan.
- Depends on: `lib/core/sync` — `DeviceSyncLifecycle`, used only to notify the sync layer of a session start or an app resume.
- Depends on: `lib/l10n` — the generated localizations for the message copy.
- Never imports: `lib/features/vault/presentation` — the gate owns the locked subtree, not the screens under it.
