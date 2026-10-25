# `supabase/ci/`

Everything in this directory exists to run the migrations of
`supabase/migrations/` against a plain PostgreSQL server, in CI, without a
Supabase project. It is **never** applied to a real project.

## Why it exists

The migrations under `supabase/migrations/` are written against a Supabase
backend. They use objects that Supabase creates for every project and that a
bare `postgres` container does not have:

| Object | Used by |
|---|---|
| role `anon`, `authenticated`, `service_role` | `grant execute on function ... to authenticated` |
| schema `auth` | `references auth.users (id)` |
| table `auth.users` | the `user_id` foreign keys |
| function `auth.uid()` | the RLS policies and every RPC |
| function `auth.jwt()` | the RPCs that read the `iat` claim |

Without them, a migration fails on an object that does not exist, which says
nothing about the migration. `shim_supabase_objects.sql` creates the smallest
possible version of those objects so the migrations can be replayed on their
own.

## The files

| File | What it is |
|---|---|
| `shim_supabase_objects.sql` | The stand-in for the objects Supabase provides. Read the header of the file: it explains why it must never reach a real project. |
| `apply_migrations.sh` | The runner. Applies the shim, then every migration in file-name order, each one with `psql -v ON_ERROR_STOP=1`, and fails on the first error. |
| `excluded_migrations.txt` | The list of migrations that legitimately cannot run outside Supabase, each with its reason. Empty today. |

## Why it is not applied to production

On a real Supabase project the `auth` schema, `auth.users` and the three roles
are owned and maintained by Supabase, and `auth.uid()` / `auth.jwt()` read the
verified JWT of the current request. Applying the shim to a real project would
replace those objects with stubs and break authentication for every user of
that project.

So the shim lives outside `supabase/migrations/`, where no deployment
pipeline looks for it, and it is applied only to the throwaway container that
the CI job creates and deletes. **Never add it to `supabase/migrations/`.**

## Running it by hand

```bash
docker run --rm --name vaulta-migrations \
  -e POSTGRES_USER=postgres -e POSTGRES_DB=postgres \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -p 5432:5432 postgres:15 &

PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=postgres \
  bash supabase/ci/apply_migrations.sh
```

The runner needs `psql` (PostgreSQL 15 or newer) and a server it can reach.
`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` and `PGDATABASE` work, and so does
a single `DATABASE_URL`.

**The database must be empty.** The migrations are not idempotent — several of
them redefine a function whose return type changed — so running them twice on
the same database fails. That is why the CI job uses a fresh container every
time, and why the local recipe above starts one.

## Migrations that cannot run outside Supabase

If a migration genuinely cannot be applied to a plain PostgreSQL, it goes into
`excluded_migrations.txt` with the reason, and nowhere else:

```text
20260323100000_initial_vault_schema.sql | needs the Supabase auth service
```

The runner then:

* skips that file, printing the file name and the reason in the log;
* **fails** when a listed file does not exist any more, because a stale entry
  would hide a migration that nobody looked at any more;
* **fails** when a listed file has no reason, because a migration is never
  skipped silently.

A migration that is neither applied nor listed is an error by construction:
everything that is not listed is applied.

The list is empty today: all eight migrations run against a clean PostgreSQL
with the shim.

## What the CI job proves, and what it does not

`.github/workflows/supabase-migrations-ci.yml` runs on every pull request and
on every push to `master`. It applies the migrations to a clean `postgres:15`
container, with no secrets and no Supabase project.

It proves that the migrations apply, in order, from an empty database, and
that a migration which does not apply fails the job. A job that fails on a
broken statement is checked on every run, so a green run means something.

It does **not** prove that a real Supabase project ends up in the same state:
there is no GoTrue, no PostgREST and no real JWT in the CI container, so the
`auth.uid()` and `auth.jwt()` stubs are exercised for their SQL, not for their
behaviour against a live auth service. It also does not say which migrations a
given deployment has — that is still the deployment's own business.

To watch the job fail on purpose, run the workflow manually with the
`inject_broken_migration` input set to `true`: it adds a deliberately broken
migration to the workspace and the run goes red.
