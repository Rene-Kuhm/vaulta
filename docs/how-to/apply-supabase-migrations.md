# Supabase migrations (B1 + B2 + B3 + B7A)

This project now includes an initial Supabase schema for zero-knowledge sync.

## Files

- `supabase/migrations/20260323100000_initial_vault_schema.sql`
- `supabase/migrations/20260323113000_add_vault_sync_rpc.sql`
- `supabase/migrations/20260323153000_add_device_registration_rpc.sql`
- `supabase/migrations/20260323183000_add_device_revocation_rpc.sql`

## What these migrations create

- Tables: `vault_devices`, `vault_blobs`, `vault_ops`
- Indexes for owner + sync query patterns
- `updated_at` trigger helper (`public.set_updated_at`)
- RLS enabled and forced on all three tables
- Owner-only RLS policies (`auth.uid() = user_id`) for select/insert/update/delete
- RPC functions for sync writes with CAS + idempotency:
  - `public.rpc_vault_upsert_blob(...)`
  - `public.rpc_vault_delete_blob(...)`
- RPC functions for device presence (Batch B3):
  - `public.rpc_vault_register_device(...)`
  - `public.rpc_vault_device_heartbeat(...)`
- Session controls and revocation RPC (Batch B7A):
  - `public.rpc_vault_device_access_status(...)`
  - `public.rpc_vault_list_devices()`
  - `public.rpc_vault_revoke_device(...)`
  - `public.rpc_vault_revoke_all_other_devices(...)`
  - `public.vault_session_controls` (`revoke_all_after` per user)

## RPC behavior (Batch B2)

- Both RPCs run inside a single SQL transaction.
- Both require authenticated context (`auth.uid()`) and registered `device_id`.
- Idempotency is keyed by `(auth.uid(), idempotency_key)` via `vault_ops`.
- If `idempotency_key` is reused with a different payload, result is `idempotency_mismatch`.
- If `expected_version` does not match current row version, result is `cas_conflict`.
- Every effective mutation writes an entry in `vault_ops` with `applied_version`.

## Device registration behavior (Batch B3)

- `vault_devices` now stores `platform` and `app_version` metadata.
- `rpc_vault_register_device` performs idempotent upsert per `(auth.uid(), device_id)`.
- `rpc_vault_device_heartbeat` updates `last_seen_at` and refreshes basic metadata.
- Both RPCs accept `p_last_seen_at`; if omitted, they use `now()`.
- Both RPCs are granted to `authenticated` and return a structured result row.

High-level flow in app wiring:

1. App startup resolves a persistent `device_id` from secure storage (creates one if absent).
2. After local session unlock, app calls `rpc_vault_register_device`.
3. On foreground resume, app sends `rpc_vault_device_heartbeat` with throttle (5 minutes).
4. Full sync pipeline (pull/push conflict loop) remains for later batch.

## Session revocation flow (Batch B7A)

1. On unlock/session start, Flutter runs `rpc_vault_device_access_status` before register/heartbeat.
2. If status is revoked (`revoked_device` or `revoked_all`), client triggers security action and blocks sync.
3. If allowed, client continues with register or heartbeat and normal sync lifecycle.
4. Device management uses `rpc_vault_list_devices` for status, `rpc_vault_revoke_device` for single device, and `rpc_vault_revoke_all_other_devices` for incident response.
5. Global revocation uses `vault_session_controls.revoke_all_after`; any device older than the marker is treated as revoked.

Example upsert call:

```sql
select *
from public.rpc_vault_upsert_blob(
  p_device_id := 'device-01',
  p_idempotency_key := '11111111-1111-1111-1111-111111111111',
  p_record_id := '22222222-2222-2222-2222-222222222222',
  p_expected_version := 3,
  p_ciphertext := 'base64-ciphertext',
  p_nonce := 'base64-nonce',
  p_gcm_tag := 'record-authentication-tag',
  p_key_version := 1,
  p_request_hash := 'sha256:...'
);
```

Example tombstone delete call:

```sql
select *
from public.rpc_vault_delete_blob(
  p_device_id := 'device-01',
  p_idempotency_key := '33333333-3333-3333-3333-333333333333',
  p_record_id := '22222222-2222-2222-2222-222222222222',
  p_expected_version := 4,
  p_request_hash := 'sha256:...'
);
```

## Apply migrations

1. Install Supabase CLI.
2. From repo root, login and link your project:

```bash
supabase login
supabase link --project-ref <your-project-ref>
```

3. Push migrations:

```bash
supabase db push
```

## Optional local validation (non-destructive)

```bash
supabase db lint
```

If Docker/local services are not configured, use static SQL review + CI checks and run `supabase db push` only in a configured environment.

## Step-by-step setup (database side)

Read step 0 first. Steps 1-6 build the database; step 0 is the reason the database
alone will not make sync work.

### 0. Prerequisite the app does not meet yet: authentication

`lib/` contains no `signInWith`, `signUp`, `signInAnonymously` or `signOut`. The
sync layer only reads `Supabase.instance.client.auth.currentUser?.id`
(`supabase_remote_vault_sync_repository.dart:22`). With no signed-in user that id is
`null`, every RLS policy evaluates `auth.uid() = user_id` as false, and sync cannot
start no matter how correct the schema is.

Before anything else in this document matters, the app needs one of:

- **Email + password sign-in**, with Supabase's "Confirm email" setting off while
  developing, so a test user works immediately; or
- **Anonymous sign-in** (`signInAnonymously`), which is the cheap way to get a real
  `auth.uid()` for a device-scoped vault. It must be enabled in
  Authentication → Providers → Anonymous, and the account is tied to the device
  unless it is later linked to an identity.

Pick one before step 1. This is a product decision, not a database one.

### 1. Create the Supabase project

- Region: the one closest to the VPS and the phone; the sync payload is small but
  the heartbeat runs while the app is in the foreground.
- Plan: the free tier is enough for development. Note the limits you will hit:
  two active projects, and a project **pauses after a week of inactivity**, which
  looks exactly like "sync broke" when you come back to it.
- Copy two values from Project Settings → API: the **Project URL** and the
  **anon public** key. The `service_role` key must never reach the app.

### 2. Apply the migrations, in this order

```bash
supabase link --project-ref <your-project-ref>
supabase db push          # applies supabase/migrations/*.sql in filename order
```

Or paste each file into the SQL editor in the same order:

1. `20260323100000_initial_vault_schema.sql` — tables `vault_devices`,
   `vault_blobs`, `vault_ops`; RLS enabled **and forced**; owner-only policies;
   `public.set_updated_at`.
2. `20260323113000_add_vault_sync_rpc.sql` — `rpc_vault_upsert_blob`,
   `rpc_vault_delete_blob` (CAS on `expected_version`, idempotency on
   `idempotency_key`).
3. `20260323153000_add_device_registration_rpc.sql` —
   `rpc_vault_register_device`, `rpc_vault_device_heartbeat`.
4. `20260323183000_add_device_revocation_rpc.sql` — `vault_session_controls`,
   `rpc_vault_device_access_status`, `rpc_vault_list_devices`,
   `rpc_vault_revoke_device`, `rpc_vault_revoke_all_other_devices`.
5. `20261021120000_add_vault_item_key_salt.sql` — the per-item key salt column.
   **This one is newer than the "What these migrations create" section above**,
   which still lists four files. Trust the directory listing, not that summary.

### 3. Verify the schema actually landed

Run in the SQL editor; each returns a row set you can eyeball:

```sql
select tablename, rowsecurity, forcerowsecurity from pg_tables
 where schemaname = 'public' and tablename like 'vault%';

select proname from pg_proc
 where pronamespace = 'public'::regnamespace and proname like 'rpc_vault%'
 order by 1;

select tablename, policyname, cmd from pg_policies
 where schemaname = 'public' order by 1, 3;
```

Expected: four tables with both `rowsecurity` and `forcerowsecurity` true, eight
`rpc_vault_*` functions, and owner-only policies on each table.

### 4. Configure authentication

- If you chose email: Authentication → Providers → Email on, and decide the
  "Confirm email" setting. A confirmed email address is required for a user to sign
  in, and the confirmation mail needs SMTP configured or it silently never arrives.
- If you chose anonymous: Authentication → Providers → Anonymous on.
- Create one test user and note the credentials. This user is the only thing that
  ties a vault blob to an account.

### 5. Hand the app its two values

The app reads exactly two compile-time values
(`device_sync_bootstrap.dart`, `String.fromEnvironment`):

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon public key>
```

For CI, the same two names as repository secrets, passed the same way. They are
public-ish by design (the anon key is safe to ship), so they are not the secret that
protects the vault: the vault is zero-knowledge and the server only ever sees
ciphertext.

Without both defines, `buildDeviceSyncLifecycle` returns `null` and the app behaves
exactly as it does today: local only, no sync, no error.

### 6. Verification checklist

In order, and stop at the first failure:

1. Sign in from the app; confirm `auth.currentUser` is not null.
2. Unlock the vault; the app calls `rpc_vault_device_access_status`, then
   `rpc_vault_register_device`. Check `select * from vault_devices;` shows one row
   with the device id from the app.
3. Save an item; `select id, user_id, record_id, version, octet_length(ciphertext)
   from vault_blobs;` shows one row. **The ciphertext column must not contain the
   secret**; grep it if you want proof.
4. Second device or second install: sign in with the same user, pull, and confirm
   the item arrives and its autofill index is rebuilt locally.
5. Force a conflict: edit the same item on both, sync, and confirm the app reports
   `cas_conflict` and asks which side to keep.
6. Revoke a device with `rpc_vault_revoke_device` and confirm the other device locks
   on its next access-status call.

### 7. What to expect to break

The SQL in this repository has **never run against a real Postgres**. The first run
is the test. The usual suspects, in order of likelihood: grants on the RPCs (they are
granted to `authenticated`, so an unauthenticated call fails with a permission error
that looks like a policy error), `forcerowsecurity` blocking the RPC owner, and the
`vault_ops` idempotency unique constraint rejecting a retry with a changed payload.

### Connection strings: the direct host is IPv6-only, use the pooler

Measured against a real project (`hugwpxvudrgpnnrukakj`):

```
db.<ref>.supabase.co          →  AAAA only (2600:1f14:...), no A record
aws-0-sa-east-1.pooler.supabase.com → A 52.67.1.88      (IPv4)
```

The connection string Supabase shows first, `postgresql://postgres:<password>@db.<ref>.supabase.co:5432/postgres`,
is the **direct** connection and it is IPv6-only. On a machine without a public
IPv6 route it fails with `Network is unreachable` before authentication is even
attempted — which reads like a credential problem and is not one. A Tailscale-only
`fd7a:` address does not count: it is a ULA, not a route to the internet.

Use the pooler instead, and take the exact host from the dashboard's Connect panel
because the region prefix varies (`aws-0-<region>`, and newer projects use
`aws-1-<region>`):

```
# session mode, better for migrations (DDL + prepared statements)
postgresql://postgres.<ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres

# transaction mode, better for a serverless client
postgresql://postgres.<ref>:<password>@aws-0-<region>.pooler.supabase.com:6543/postgres
```

Note the user name changes with the pooler: `postgres` becomes
`postgres.<project-ref>`. Forgetting that produces `password authentication failed`
with a correct password.

Apply the migrations in session mode; transaction mode can reject multi-statement
DDL and anything relying on session state.

If the project needs to accept the direct connection, that is an IPv4 add-on in the
Supabase dashboard, not something a client can work around.
