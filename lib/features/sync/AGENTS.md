# AGENTS.md — `lib/features/sync`

Sign-in and conflicts: the gate that puts the vault UI behind a Supabase session, the credentials form, and the bottom sheet that resolves pending conflicts. Its edge is the optional backend — the whole feature is inert in a build that was not compiled with a Supabase project.

The map of this module: `mise run repo-map --module lib/features/sync`.

## Invariants

- Sync is opt-in and absent by default: with no `SUPABASE_URL` and `SUPABASE_ANON_KEY` the gate renders its child immediately and never contacts Supabase.
- A backend that cannot be reached still renders the child: the gate degrades to pass-through, so an outage cannot lock the user out of the local vault.
- The sync lifecycle is built only once a session exists; building it earlier would see a null `auth.currentUser?.id` and sync nothing silently.
- A sign-in failure is one of two states, `invalidCredentials` or `offline`. An empty form fails locally and issues no request.
- An error the form cannot classify is reported through `onUnexpected` and shown as offline, never guessed at.
- The anon key is public by design; RLS is what protects the rows.

## How it is tested

- `test/features/sync/sync_sign_in_form_test.dart` — pins the form: the fields render, an empty form fails without a network call, a rejected pair shows the credentials message, an unreachable server says so instead of blaming the password, and the button is disabled while the attempt is in flight.
- `test/features/sync/presentation/sync_conflicts_sheet_test.dart` — pins the empty state of the conflict sheet.

## Do not touch

- The compile-time `SUPABASE_URL` / `SUPABASE_ANON_KEY` defines — they are the switch that keeps sync out of the published builds.
- `supabase/migrations/` — the RLS policies and the RPCs are the backend contract and need their own review.
- The conflict-resolution semantics — versioning, CAS and tombstones are ADR-002 and live in `lib/core/sync`.
- Turning sync on for a release — that is an owner decision, not a code tweak.

## Boundaries

- Depends on: `lib/core/sync` — the device registration lifecycle, the conflict records and the Supabase client resolver.
- Depends on: `lib/l10n` — the generated localizations for the sign-in and conflict copy.
- Never imports: `lib/core/security` — the sync layer reads the session through its own ports; the vault DEK never travels through this module.
- Never imports: `lib/features/vault/presentation` — the gate decides what to show, never what the vault contains.
