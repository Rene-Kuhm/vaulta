# AGENTS.md — `lib/core/sync`

The optional sync layer: device registration and revocation, the bidirectional
sync service, the conflict resolution, the vault-key sync and the Supabase
implementations. It is the second device of the same vault, not a requirement
for one: with no backend configured, none of this exists.

The map of this module: `mise run repo-map --module lib/core/sync`.

## Invariants

- Sync is opt-in and absent by default. `buildDeviceSyncLifecycle()` returns
  `null` when the `SUPABASE_URL` or `SUPABASE_ANON_KEY` dart-defines are
  missing, so the lifecycle-dependent widgets receive a null resolver and the
  optional-sync UI is simply not there. The published builds define neither.
- The wrapped DEK travels under RLS, guarded by `rpc_vault_get_key` and
  `rpc_vault_put_key`. A second device reconstructs the same DEK from the
  same master password; the key itself is never uploaded in the clear.
- Every write carries a version and is applied with a compare-and-set. The
  push is idempotent: a replay returns `idempotentReplay` and an
  `idempotencyMismatch` is refused, never applied twice (ADR-0002).
- A delete is a tombstone, not a removal: the tombstone has to travel to the
  other devices, so a deletion is never silently undone by a later pull.
- A conflict is resolved, not overwritten: the resolver compares the local
  and the remote version and produces an explicit decision
  (`SyncConflictResolver`, `SyncConflictResolveResult`).
- A remote snapshot is applied through the `RemoteSnapshotApplier` port, so
  the sync layer never writes the vault directly and the storage owns the
  write.
- A revoked device is refused: `DeviceSessionRevocationService` turns the
  revocation into an explicit outcome (device revoked, all sessions revoked,
  unauthenticated) instead of a silent disconnect (ADR-0003).
- Diagnostics are off unless `syncDiagnosticsLoggingEnabled` says otherwise.
  A sync event never carries a secret.

## How it is tested

- `test/core/sync/bidirectional_sync_service_test.dart` — the pull and push
  loop and the mutation sink.
- `test/core/sync/sync_conflict_resolver_test.dart` — the conflict decision.
- `test/core/sync/sync_item_payload_codec_test.dart` — the wire payload of
  an item.
- `test/core/sync/remote_vault_blob_change_test.dart` — the remote change
  envelope.
- `test/core/sync/device_registration_service_test.dart` and
  `test/core/sync/device_session_revocation_service_test.dart` — the device
  lifecycle and the revocation.
- `test/core/sync/vault_key_sync_service_test.dart` — the vault key sync.
- `test/core/sync/local_remote_vault_store_test.dart` and
  `test/core/sync/vault_change_signal_test.dart` — the local store and the
  change signal.
- `test/core/sync/supabase_client_resolver_test.dart` — the client
  resolution and the "no backend" case.

## Do not touch

- The wire format and the sync semantics: versioning, the compare-and-set,
  the idempotency key and the tombstones are the contract in ADR-0002 and in
  `docs/adr/0002-sync-versioning-cas-idempotency-tombstones.md`.
- The RPC names and the RLS policies in `supabase/migrations/`. The Dart side
  and the migrations have to land together; the migration CI applies them
  against a real Postgres.
- The `SUPABASE_URL` and `SUPABASE_ANON_KEY` dart-defines and their absence
  in the published builds. Sync must never run unless the user turned it on.
- The vault-key RPCs: they are the only path that moves a wrapped key
  between devices, and they are guarded by RLS.
- The `SyncDiagnosticsHook` and the diagnostics flag: turning the logging on
  by default would write sync events that describe the vault.

## Boundaries

- Depends on: `lib/core/security` — the DEK, the crypto service and the
  repository ports (`VaultRepository`, `RemoteSnapshotApplier`).
- Depends on: `lib/features/vault/domain` — the item types.
- Never imports: `lib/features/*/presentation` and `lib/app`. The sync
  feature renders what this layer decides; it does not contain the rules.
- Never imports: `lib/core/storage`. The sync layer talks to the vault
  through the ports, and the storage implements them.
