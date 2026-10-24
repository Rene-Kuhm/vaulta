-- Batch B8: fix "column reference device_id is ambiguous" (42702) in the
-- device RPCs.
--
-- The RETURNS TABLE clauses of rpc_vault_device_access_status,
-- rpc_vault_register_device, rpc_vault_device_heartbeat and
-- rpc_vault_revoke_device declare an OUT column named `device_id`. Inside the
-- body that name is also a column of public.vault_devices, so a bare
-- `device_id` in a WHERE clause is ambiguous between the OUT parameter and the
-- table column. Postgres resolves it against neither and raises 42702, which
-- PostgREST surfaces as HTTP 400.
--
-- The first device registration therefore never reached the register RPC: the
-- session-start flow calls access_status first, got 400, treated it as
-- "cannot verify access", and bailed out before registering. Qualifying the
-- column reference fixes the ambiguity; the signatures and return types are
-- unchanged, so CREATE OR REPLACE is safe and no drop is required.

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
  v_has_device boolean;
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
  where public.vault_devices.user_id = v_user_id
    and public.vault_devices.device_id = v_device_id
  limit 1;
  v_has_device := found;

  select public.vault_session_controls.revoke_all_after
  into v_revoke_all_after
  from public.vault_session_controls
  where public.vault_session_controls.user_id = v_user_id;

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

  if not v_has_device then
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
  where public.vault_devices.user_id = v_user_id
    and public.vault_devices.device_id = v_device_id
  limit 1;
  v_has_existing := found;

  select public.vault_session_controls.revoke_all_after
  into v_revoke_all_after
  from public.vault_session_controls
  where public.vault_session_controls.user_id = v_user_id;

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
  on conflict on constraint vault_devices_user_device_unique
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
  where public.vault_devices.user_id = v_user_id
    and public.vault_devices.device_id = v_device_id
  limit 1;
  v_has_existing := found;

  select public.vault_session_controls.revoke_all_after
  into v_revoke_all_after
  from public.vault_session_controls
  where public.vault_session_controls.user_id = v_user_id;

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
  on conflict on constraint vault_devices_user_device_unique
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
  set revoked_at = coalesce(public.vault_devices.revoked_at, now())
  where public.vault_devices.user_id = v_user_id
    and public.vault_devices.device_id = v_device_id
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
