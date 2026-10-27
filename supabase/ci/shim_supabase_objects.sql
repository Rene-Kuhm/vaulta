-- Minimal stand-in for the objects a real Supabase project provides.
--
-- WHY THIS FILE EXISTS
--   The migrations in `supabase/migrations/` are written against a Supabase
--   backend, not against a bare PostgreSQL server. They reference objects that
--   Supabase creates for every project and that therefore do not exist in a
--   plain `postgres` container:
--
--     * the roles `anon`, `authenticated` and `service_role`
--       (used by `grant execute on function ... to authenticated`),
--     * the schema `auth`,
--     * the table `auth.users` (the target of the `user_id` foreign keys),
--     * the functions `auth.uid()` and `auth.jwt()`
--       (used by the RLS policies and by the RPCs).
--
--   Without them a migration fails on an object that does not exist, which
--   says nothing about the migration itself. This file creates the smallest
--   possible version of those objects so the migrations can be replayed
--   against a clean PostgreSQL in CI
--   (`.github/workflows/supabase-migrations-ci.yml`).
--
-- WHY IT IS NEVER APPLIED TO PRODUCTION
--   This is a test double, not a schema. On a real Supabase project the
--   `auth` schema and the three roles are owned and maintained by Supabase
--   itself; `auth.users` holds real account rows, and `auth.uid()` /
--   `auth.jwt()` read the verified JWT of the current request. Applying this
--   file to a real project would replace Supabase's own objects with
--   stubs, which would break authentication for every user of that project.
--
--   Therefore:
--     * it lives under `supabase/ci/`, outside of `supabase/migrations/`,
--       so no deployment pipeline ever picks it up as a migration;
--     * the CI job applies it to a throwaway container that is deleted when
--       the job ends;
--     * it must never be added to `supabase/migrations/`.
--
--   The migrations themselves are not modified by this file: it only adds
--   objects that Supabase would have provided.
--
-- The behaviour of the stubs is deliberately close to Supabase's:
--   * `auth.uid()` reads the `sub` claim of the request JWT, from either the
--     legacy `request.jwt.claim.sub` setting or the JSON `request.jwt.claims`
--     setting, and returns NULL when the request is unauthenticated;
--   * `auth.jwt()` returns the decoded claims of the request JWT, or an empty
--     JSON object when there is none.
-- Both read only session settings, so a plain `psql` session that never sets
-- them simply behaves as an unauthenticated request.

-- Roles Supabase creates in every project. They are group roles: the
-- `authenticated` role is what the PostgREST layer switches to for a signed
-- in request, and the `anon` role for an anonymous one.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    -- `service_role` is the role the server-side API key maps to. On Supabase
    -- it bypasses row level security, and the migrations rely on that only
    -- through the grants below.
    create role service_role nologin bypassrls;
  end if;
end
$$;

-- The schema Supabase exposes for its authentication service.
create schema if not exists auth;

-- The table the `user_id` foreign keys point at. Only the columns the
-- migrations reference are reproduced: the `id` primary key and the
-- timestamps that Supabase's own table also has.
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  created_at timestamptz not null default now()
);

-- The identity of the caller, read from the request JWT.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
  )::uuid;
$$;

-- The decoded claims of the request JWT.
create or replace function auth.jwt()
returns jsonb
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), ''),
    '{}'
  )::jsonb;
$$;

-- The three roles need to be able to resolve the objects above.
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant execute on function auth.jwt() to anon, authenticated, service_role;
