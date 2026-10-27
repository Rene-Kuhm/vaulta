# AGENTS.md — `lib/features/vault`

The vault feature: the item model, the dashboard, the entry detail and editor, and the import and merge flows. It owns the `VaultItem` vocabulary that `lib/core` and the other features speak, and every rule about what an entry may contain and how it may leave the device.

The map of this module: `mise run repo-map --module lib/features/vault`.

## Invariants

- `VaultItem.toJson` writes `otpAuthUri`, `passwordHistory` and `isFavorite` only when they carry a value, so a payload written before a field existed keeps its exact shape and the encrypted item payload version does not move (4 today).
- A payload without those keys decodes as absent: `isFavorite` is `false`, the history is empty, the URI is `null`; a non-boolean `isFavorite` is read as `false` instead of failing the decrypt.
- The password history keeps at most `vaultPasswordHistoryLimit` (10) entries, oldest first, and records nothing when the secret did not change, was empty, or is already the newest entry.
- A restore never overwrites or deletes an existing entry: the merger adds, keeps both with a title suffix, or skips an exact duplicate, and every written item gets a fresh id.
- A secret field offers no Copy, Cut, Share or PROCESS_TEXT and blocks the keyboard copy shortcuts; the only way out is `SensitiveClipboardService`.
- A duplicate is detected on normalized title, username and website, or on the same secret plus at least one matching field.

## How it is tested

- `test/features/vault/domain/vault_item_json_test.dart` — pins the JSON shape: the pre-TOTP payload is byte-identical, the optional keys appear only when set, an old payload decodes and a non-boolean favorite reads as false.
- `test/features/vault/domain/vault_password_history_test.dart` — pins the history: the rotation rule, the no-duplicate rule, the cap of ten, the order and the JSON round trip.
- `test/features/vault/application/vault_import_parser_test.dart` — pins the CSV and JSON mappings, the delimiter detection, the duplicate detection and the rejection of rows without credentials.
- `test/features/vault/application/vault_import_kdbx_test.dart` — pins the KeePass path: the KDBX 3.1 and 4.x imports, the password and key file, every loud failure and the detection by signature.
- `test/features/vault/application/vault_backup_merger_test.dart` — pins the merge plan: add, keep-both and skip, and that `apply` re-plans against the current vault.
- `test/features/vault/application/vault_favorite_persistence_test.dart` — pins that the favorite flag survives a save and load round trip and an import.
- `test/features/vault/presentation/vault_dashboard_screen_test.dart` — pins the dashboard: the search filter, the empty and no-results states, the reload after a sync change, the masked secret and the strength estimator.
- `test/features/vault/presentation/vault_dashboard_favorites_test.dart` — pins the favorites filter and that the flag survives an edit.
- `test/features/vault/presentation/vault_entry_detail_screen_test.dart` — pins the detail screen: the copy through the sensitive clipboard, the 30-second auto-clear and the non-selectable revealed secret.
- `test/features/vault/presentation/vault_entry_detail_password_history_test.dart` — pins the history section: hidden when empty, newest first, copied through the sensitive clipboard.
- `test/features/vault/presentation/vault_entry_editor_password_history_test.dart` — pins that the editor records the previous secret on a change and never shows it as an editable field.
- `test/features/vault/presentation/vault_entry_editor_secret_field_test.dart` — pins the secret field guard: no Copy, Cut or Share, and that the keyboard shortcuts do not copy a revealed secret.
- `test/features/vault/presentation/vault_entry_favorite_test.dart` — pins the favorite switch in the editor and the favorite action in the detail screen.
- `test/features/vault/presentation/vault_import_screen_test.dart` — pins that only the importable candidates are saved and that the duplicates are skipped.
- `test/features/vault/presentation/vault_import_kdbx_flow_test.dart` — pins the `.kdbx` password dialog flow and that a CSV import skips it.

## Do not touch

- The optional keys of `VaultItem.toJson` and the encrypted payload version — the item payload is a wire format; changing its shape is an ADR change, not a refactor.
- The duplicate and merge rules — they are what keeps a restore from overwriting an existing entry (ADR-006).
- The `secretFieldAllowedMenuButtons` guard and the clipboard path — both live in `lib/core/security` and are security controls, not widgets.
- The `.kdbx` credential handling in the import screen — the master password and the key file are held only for the unlock attempt and dropped afterwards.

## Boundaries

- Depends on: `lib/core/security` — `VaultRepository` for every read and write and `SensitiveClipboardService` for every copy.
- Depends on: `lib/features/health`, `lib/features/totp` and `lib/features/sync` — the report screen, the code panel and the conflict sheet it mounts.
- Depends on: `lib/core/sync` — two collaborators only: `SyncConflictResolver` (forwarded to the conflict sheet) and `VaultChangeSignal` (the change notifier). Neither is constructed here, and the sync service itself is never imported.
- Never imports: `lib/core/storage` — the vault is read and written through `VaultRepository` only.
- Never imports: `lib/features/*/application` from its own `domain` layer — the layering stays `presentation` to `application` to `domain`.
