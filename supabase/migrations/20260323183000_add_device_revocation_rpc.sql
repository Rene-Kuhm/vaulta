-- Batch B7: device/session revocation + device access checks.

-- This migration redefines rpc_vault_register_device and rpc_vault_device_heartbeat
-- with a wider result: the access check merged into them adds access_allowed,
-- revoked_at and revoke_all_after. Postgres rejects a CREATE OR REPLACE that
-- changes a function's return type (42P13: cannot change return type), so the old
-- definitions must be dropped first. Dropping by name through pg_proc keeps this
-- correct whatever the previous argument list was, and is a no-op on a fresh
-- database where they do not exist yet.
do $$
declare
  target record;
begin
  for target in
    select p.oid::regprocedure as signature
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('rpc_vault_register_device', 'rpc_vault_device_heartbeat')
  loop
    execute format('drop function %s', target.signature);
  end loop;
end $$;

alter table public.vault_devices
  add column if not exists revoked_at timestamptz;

create table if not exists public.vault_session_controls (
  user_id uuid primary key references auth.users (id) on delete cascade,
  revoke_all_after timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_vault_session_controls_set_updated_at on public.vault_session_controls;
create trigger trg_vault_session_controls_set_updated_at
before update on public.vault_session_controls
for each row
execute function public.set_updated_at();

alter table public.vault_session_controls enable row level security;
alter table public.vault_session_controls force row level security;

drop policy if exists vault_session_controls_select_owner on public.vault_session_controls;
create policy vault_session_controls_select_owner
on public.vault_session_controls
for select
using (auth.uid() = user_id);

drop policy if exists vault_session_controls_insert_owner on public.vault_session_controls;
create policy vault_session_controls_insert_owner
on public.vault_session_controls
for insert
with check (auth.uid() = user_id);

drop policy if exists vault_session_controls_update_owner on public.vault_session_controls;
create policy vault_session_controls_update_owner
on public.vault_session_controls
for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists vault_session_controls_delete_owner on public.vault_session_controls;
create policy vault_session_controls_delete_owner
on public.vault_session_controls
for delete
using (auth.uid() = user_id);

create or replace function public.rpc_vault_device_access_status(
  p_device_id text
)
returns table (
  result_code text,
  device_id text,
  access_allowed boolean,
  message text,
  revoked_at timestamptz,
  revoke_all_after timestamptz
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_device_id text;
  v_device public.vault_devices%rowtype;
  v_revoke_all_after timestamptz;
  v_reference_seen_at timestamptz;
  v_auth_issued_at timestamptz;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return query
    select
      'unauthenticated'::text,
      null::text,
      false,
      'auth.uid() is null'::text,
      null::timestamptz,
      null::timestamptz;
    return;
  end if;

  v_device_id := nullif(trim(coalesce(p_device_id, '')), '');
  if v_device_id is null then
    return query
    select
      'invalid_device'::text,
      null::text,
      false,
      'device_id is required'::text,
      null::timestamptz,
      null::timestamptz;
    return;
  end if;

  select *
  into v_device
  from public.vault_devices
  where user_id = v_user_id
    and device_id = v_device_id
  limit 1;

  select revoke_all_after
  into v_revoke_all_after
  from public.vault_session_controls
  where user_id = v_user_id;

  v_auth_issued_at := to_timestamp(
    nullif(auth.jwt() ->> 'iat', '')::double precision
  );

  if v_revoke_all_after is not null and v_auth_issued_at < v_revoke_all_after then
    return query
    select
      'revoked_all'::text,
      v_device_id,
      false,
      'auth session was issued before revoke_all_after marker'::text,
      null::timestamptz,
      v_revoke_all_after;
    return;
  end if;

  if not found then
    return query
    select
      'unknown_device'::text,
      v_device_id,
      false,
      'device has not been registered yet'::text,
      null::timestamptz,
      v_revoke_all_after;
    return;
  end if;

  v_reference_seen_at := coalesce(v_device.last_seen_at, v_device.created_at);

  if v_device.revoked_at is not null then
    return query
    select
      'revoked_device'::text,
      v_device.device_id,
      false,
      'device was revoked explicitly'::text,
      v_device.revoked_at,
      v_revoke_all_after;
    return;
  end if;

  if v_revoke_all_after is not null and v_reference_seen_at < v_revoke_all_after then
    return query
    select
      'revoked_all'::text,
      v_device.device_id,
      false,
      'session revoked by revoke_all_after marker'::text,
      v_device.revoked_at,
      v_revoke_all_after;
    return;
  end if;

  return query
  select
    'allowed'::text,
    v_device.device_id,
    true,
    'device access allowed'::text,
    v_device.revoked_at,
    v_revoke_all_after;
end;
$$;

create or replace function public.rpc_vault_register_device(
  p_device_id text,
  p_device_name text default null,
  p_platform text default null,
  p_app_version text default null,
  p_last_seen_at timestamptz default null
)
returns table (
  result_code text,
  device_id text,
  access_allowed boolean,
  message text,
  revoked_at timestamptz,
  revoke_all_after timestamptz
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_device_id text;
  v_last_seen timestamptz;
  v_existing public.vault_devices%rowtype;
  v_has_existing boolean;
  v_revoke_all_after timestamptz;
  v_auth_issued_at timestamptz;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return query
    select
      'unauthenticated'::text,
      null::text,
      false,
      'auth.uid() is null'::text,
      null::timestamptz,
      null::timestamptz;
    return;
  end if;

  v_device_id := nullif(trim(coalesce(p_device_id, '')), '');
  if v_device_id is null then
    return query
    select
      'invalid_device'::text,
      null::text,
      false,
      'device_id is required'::text,
      null::timestamptz,
      null::timestamptz;
    return;
  end if;

  select *
  into v_existing
  from public.vault_devices
  where user_id = v_user_id
    and device_id = v_device_id
  limit 1;
  v_has_existing := found;

  select revoke_all_after
  into v_revoke_all_after
  from public.vault_session_controls
  where user_id = v_user_id;

  v_auth_issued_at := to_timestamp(
    nullif(auth.jwt() ->> 'iat', '')::double precision
  );

  if v_revoke_all_after is not null and v_auth_issued_at < v_revoke_all_after then
    return query
    select
      'revoked_all'::text,
      v_device_id,
      false,
      'auth session was issued before revoke_all_after marker'::text,
      null::timestamptz,
      v_revoke_all_after;
    return;
  end if;

  if v_has_existing and v_existing.revoked_at is not null then
    return query
    select
      'revoked_device'::text,
      v_device_id,
      false,
      'device is revoked'::text,
      v_existing.revoked_at,
      v_revoke_all_after;
    return;
  end if;

  if v_has_existing and v_revoke_all_after is not null and coalesce(v_existing.last_seen_at, v_existing.created_at) < v_revoke_all_after then
    return query
    select
      'revoked_all'::text,
      v_device_id,
      false,
      'device session was globally revoked'::text,
      v_existing.revoked_at,
      v_revoke_all_after;
    return;
  end if;

  v_last_seen := coalesce(p_last_seen_at, now());

  insert into public.vault_devices (
    user_id,
    device_id,
    device_name,
    platform,
    app_version,
    last_seen_at,
    revoked_at
  )
  values (
    v_user_id,
    v_device_id,
    nullif(trim(coalesce(p_device_name, '')), ''),
    nullif(trim(coalesce(p_platform, '')), ''),
    nullif(trim(coalesce(p_app_version, '')), ''),
    v_last_seen,
    null
  )
  on conflict (user_id, device_id)
  do update
  set device_name = coalesce(excluded.device_name, public.vault_devices.device_name),
      platform = coalesce(excluded.platform, public.vault_devices.platform),
      app_version = coalesce(excluded.app_version, public.vault_devices.app_version),
      last_seen_at = greatest(
        coalesce(public.vault_devices.last_seen_at, '-infinity'::timestamptz),
        excluded.last_seen_at
      );

  return query
  select
    'registered'::text,
    v_device_id,
    true,
    'device registered or refreshed'::text,
    null::timestamptz,
    v_revoke_all_after;
end;
$$;

create or replace function public.rpc_vault_device_heartbeat(
  p_device_id text,
  p_device_name text default null,
  p_platform text default null,
  p_app_version text default null,
  p_last_seen_at timestamptz default null
)
returns table (
  result_code text,
  device_id text,
  access_allowed boolean,
  message text,
  revoked_at timestamptz,
  revoke_all_after timestamptz
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_device_id text;
  v_last_seen timestamptz;
  v_existing public.vault_devices%rowtype;
  v_has_existing boolean;
  v_revoke_all_after timestamptz;
  v_auth_issued_at timestamptz;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return query
    select
      'unauthenticated'::text,
      null::text,
      false,
      'auth.uid() is null'::text,
      null::timestamptz,
      null::timestamptz;
    return;
  end if;

  v_device_id := nullif(trim(coalesce(p_device_id, '')), '');
  if v_device_id is null then
    return query
    select
      'invalid_device'::text,
      null::text,
      false,
      'device_id is required'::text,
      null::timestamptz,
      null::timestamptz;
    return;
  end if;

  select *
  into v_existing
  from public.vault_devices
  where user_id = v_user_id
    and device_id = v_device_id
  limit 1;
  v_has_existing := found;

  select revoke_all_after
  into v_revoke_all_after
  from public.vault_session_controls
  where user_id = v_user_id;

  v_auth_issued_at := to_timestamp(
    nullif(auth.jwt() ->> 'iat', '')::double precision
  );

  if v_revoke_all_after is not null and v_auth_issued_at < v_revoke_all_after then
    return query
    select
      'revoked_all'::text,
      v_device_id,
      false,
      'auth session was issued before revoke_all_after marker'::text,
      null::timestamptz,
      v_revoke_all_after;
    return;
  end if;

  if v_has_existing and v_existing.revoked_at is not null then
    return query
    select
      'revoked_device'::text,
      v_device_id,
      false,
      'device is revoked'::text,
      v_existing.revoked_at,
      v_revoke_all_after;
    return;
  end if;

  if v_has_existing and v_revoke_all_after is not null and coalesce(v_existing.last_seen_at, v_existing.created_at) < v_revoke_all_after then
    return query
    select
      'revoked_all'::text,
      v_device_id,
      false,
      'device session was globally revoked'::text,
      v_existing.revoked_at,
      v_revoke_all_after;
    return;
  end if;

  v_last_seen := coalesce(p_last_seen_at, now());

  insert into public.vault_devices (
    user_id,
    device_id,
    device_name,
    platform,
    app_version,
    last_seen_at,
    revoked_at
  )
  values (
    v_user_id,
    v_device_id,
    nullif(trim(coalesce(p_device_name, '')), ''),
    nullif(trim(coalesce(p_platform, '')), ''),
    nullif(trim(coalesce(p_app_version, '')), ''),
    v_last_seen,
    null
  )
  on conflict (user_id, device_id)
  do update
  set device_name = coalesce(excluded.device_name, public.vault_devices.device_name),
      platform = coalesce(excluded.platform, public.vault_devices.platform),
      app_version = coalesce(excluded.app_version, public.vault_devices.app_version),
      last_seen_at = greatest(
        coalesce(public.vault_devices.last_seen_at, '-infinity'::timestamptz),
        excluded.last_seen_at
      );

  return query
  select
    'heartbeat_ok'::text,
    v_device_id,
    true,
    'device heartbeat stored'::text,
    null::timestamptz,
    v_revoke_all_after;
end;
$$;

create or replace function public.rpc_vault_revoke_device(
  p_device_id text
)
returns table (
  result_code text,
  device_id text,
  revoked boolean,
  message text,
  revoked_at timestamptz
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_device_id text;
  v_revoked_at timestamptz;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return query
    select
      'unauthenticated'::text,
      null::text,
      false,
      'auth.uid() is null'::text,
      null::timestamptz;
    return;
  end if;

  v_device_id := nullif(trim(coalesce(p_device_id, '')), '');
  if v_device_id is null then
    return query
    select
      'invalid_device'::text,
      null::text,
      false,
      'device_id is required'::text,
      null::timestamptz;
    return;
  end if;

  update public.vault_devices
  set revoked_at = coalesce(revoked_at, now())
  where user_id = v_user_id
    and device_id = v_device_id
  returning public.vault_devices.revoked_at into v_revoked_at;

  if v_revoked_at is null then
    return query
    select
      'device_not_found'::text,
      v_device_id,
      false,
      'device not found for current user'::text,
      null::timestamptz;
    return;
  end if;

  return query
  select
    'revoked'::text,
    v_device_id,
    true,
    'device revoked successfully'::text,
    v_revoked_at;
end;
$$;

create or replace function public.rpc_vault_revoke_all_other_devices(
  p_current_device_id text default null
)
returns table (
  result_code text,
  revoked_count bigint,
  revoke_all_after timestamptz,
  message text
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_current_device_id text;
  v_now timestamptz;
  v_revoked_count bigint;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return query
    select
      'unauthenticated'::text,
      0::bigint,
      null::timestamptz,
      'auth.uid() is null'::text;
    return;
  end if;

  v_current_device_id := nullif(trim(coalesce(p_current_device_id, '')), '');
  v_now := now();

  insert into public.vault_session_controls (user_id, revoke_all_after)
  values (v_user_id, v_now)
  on conflict (user_id)
  do update set revoke_all_after = excluded.revoke_all_after;

  update public.vault_devices
  set revoked_at = coalesce(revoked_at, v_now)
  where user_id = v_user_id
    and (v_current_device_id is null or device_id <> v_current_device_id);

  get diagnostics v_revoked_count = row_count;

  if v_current_device_id is not null then
    update public.vault_devices
    set last_seen_at = greatest(
      coalesce(last_seen_at, '-infinity'::timestamptz),
      v_now
    )
    where user_id = v_user_id
      and device_id = v_current_device_id;
  end if;

  return query
  select
    'revoked_others'::text,
    v_revoked_count,
    v_now,
    'all other sessions revoked'::text;
end;
$$;

create or replace function public.rpc_vault_list_devices()
returns table (
  device_id text,
  device_name text,
  platform text,
  app_version text,
   created_at timestamptz,
  last_seen_at timestamptz,
  revoked_at timestamptz,
   revoke_all_after timestamptz,
   status_code text,
   access_allowed boolean
)
language sql
security invoker
set search_path = public, pg_temp
as $$
  select
    d.device_id,
    d.device_name,
    d.platform,
    d.app_version,
    d.created_at,
    d.last_seen_at,
    d.revoked_at,
    c.revoke_all_after,
    case
      when d.revoked_at is not null then 'revoked_device'::text
      when c.revoke_all_after is not null and coalesce(d.last_seen_at, d.created_at) < c.revoke_all_after then 'revoked_all'::text
      else 'active'::text
    end as status_code,
    case
      when d.revoked_at is not null then false
      when c.revoke_all_after is not null and coalesce(d.last_seen_at, d.created_at) < c.revoke_all_after then false
      else true
    end as access_allowed
  from public.vault_devices d
  left join public.vault_session_controls c
    on c.user_id = d.user_id
  where d.user_id = auth.uid()
  order by d.last_seen_at desc nulls last, d.created_at desc;
$$;

grant execute on function public.rpc_vault_device_access_status(text) to authenticated;

grant execute on function public.rpc_vault_register_device(
  text,
  text,
  text,
  text,
  timestamptz
) to authenticated;

grant execute on function public.rpc_vault_device_heartbeat(
  text,
  text,
  text,
  text,
  timestamptz
) to authenticated;

grant execute on function public.rpc_vault_revoke_device(text) to authenticated;

grant execute on function public.rpc_vault_revoke_all_other_devices(text) to authenticated;

grant execute on function public.rpc_vault_list_devices() to authenticated;
