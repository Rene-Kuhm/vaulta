# AGENTS.md — `lib/features/settings`

The Settings tab: unlock posture (biometrics, idle timeout, lock now, change master password), sync conflicts, connected devices and their revocation, the backup section, the in-app updater, the language selector and the platform capability rows. Its edge is the user account and the device — it never holds vault data itself.

The map of this module: `mise run repo-map --module lib/features/settings`.

## Invariants

- Every optional service (`conflictResolver`, `revocationService`, `secureStorage`, `repository`) is rendered only when it is provided, so the screen stays usable in a stripped-down configuration.
- The backup section is mounted only when a repository is provided; the same screen owns the change-master-password dialog, the idle-timeout preset, the device list and the capability panel.
- Changing the master password goes through `VaultSecurityController`, so the same throttle and the same message codes apply as on unlock.
- Revoking the current device locks this session; revoking the others leaves it alone, and the wording differs when every session has been revoked.
- A verification failure of the updater gets its own localized message; any other error falls back to the error's own text.

## How it is tested

- `test/features/settings/presentation/settings_screen_test.dart` — pins the sections: the backup section appears only with a repository, the master-password change succeeds or reports an invalid current password, the lockout message appears, the idle-timeout preset is applied, a device is revoked, the current device locks the session, and the capability rows answer the wired services rather than a platform table.
- `test/features/settings/update_section_test.dart` — pins the update flow: the checking state, the up-to-date banner, the error banner, one localized message per verification failure and the dev-channel switch persisting its choice.

## Do not touch

- The updater's verification rules — signature checking and the release channel live in `lib/core/update`; a change there is a security change, not a UI change.
- The `securityMessage*` keys in `lib/l10n/app_*.arb` — this screen renders the same codes as the lock gate.
- The device-revocation semantics — they are the session policy of ADR-003, enforced in `lib/core/sync`.
- The `lib/features/backup` and `lib/features/security` panels mounted here — they are other modules' contracts, so changing their constructor is a coordinated change.

## Boundaries

- Depends on: `lib/features/backup` — the `BackupSection` and its coordinator.
- Depends on: `lib/features/security` — the capability panel and the shared throttle and message helpers.
- Depends on: `lib/core/security`, `lib/core/sync` and `lib/core/update` — the controller, the conflict and revocation services, and the update service.
- Never imports: `lib/core/storage` — the screen never reaches into the storage implementation.
