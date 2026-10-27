# AGENTS.md — `lib/features/backup`

Encrypted `.vaulta` backup and restore, the clear-text migration export, and the merge that lands restored items in the vault. Its edge is the file: this module decides what leaves the device and in which format, and it is the only place where the vault is written out.

The map of this module: `mise run repo-map --module lib/features/backup`.

## Invariants

- An export needs a single-use grant: `authorizeExport` re-verifies the master password through the shared unlock throttle and returns a grant bound to the current session, valid for `grantLifetime` (5 minutes) and invalidated by a lock.
- A grant is consumed by one export only; a refused backup password throws `VaultBackupPasswordException` and leaves the grant usable.
- The backup password follows the master-password policy exactly, through `MasterPasswordService.validate` (12 characters, four character classes), so the two policies cannot drift apart (ADR-006 §1).
- A clear-text export requires `acknowledgedUnencrypted: true`; without it the coordinator throws `VaultClearTextExportNotConfirmedException`.
- The envelope is sealed by `VaultBackupService` (Argon2id plus AES-256-GCM); this module never re-implements it and never weakens its parameters.
- A restore previews first and writes through the repository save path, so every restored item is re-encrypted with the vault DEK.

## How it is tested

- `test/features/backup/application/vault_backup_coordinator_test.dart` — pins the grant (wrong password, throttle, locked vault, single use, expiry), the restore path and the clear-text rules.
- `test/features/backup/domain/vault_clear_text_export_test.dart` — pins the RFC 4180 CSV escaping and the JSON round trip of every `VaultItem` field.
- `test/features/backup/presentation/vault_backup_export_dialog_test.dart` — pins the two-step export dialog and that the saved file decrypts to the vault items.
- `test/features/backup/presentation/vault_backup_restore_screen_test.dart` — pins that a wrong and a tampered file show the same generic error, and that a newer format version is reported on pick.
- `test/features/backup/presentation/vault_clear_text_export_dialog_test.dart` — pins that nothing is exported before the acknowledgement, and that the encrypted export still writes a `.vaulta` file.

## Do not touch

- The `.vaulta` envelope and its KDF parameters — a format change with an ADR (ADR-006), not a refactor of this module.
- The generic error copy of `VaultBackupService` — a wrong password and a tampered file must not be distinguishable (ADR-006 §5).
- The `lib/l10n/app_*.arb` files without `flutter gen-l10n` — the generated localizations are never hand-edited.
- The grant lifetime and the single-use semantics — they are the control that makes an export prove a fresh re-authentication.

## Boundaries

- Depends on: `lib/core/security` — `VaultBackupService` (the envelope), `VaultSecurityController` (the throttle and the session), `MasterPasswordService` (the policy) and `VaultRepository` (the items).
- Depends on: `lib/features/vault` — `VaultBackupMerger` and `VaultItem`.
- Depends on: `lib/features/security` — `unlockThrottleMessage`, the shared throttle copy.
- Never imports: `lib/features/vault/presentation` — a restore writes through the repository, it never drives another feature's screen.
