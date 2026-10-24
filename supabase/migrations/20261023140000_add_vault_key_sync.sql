-- Batch B10: vault key metadata for cross-device sync (wrapped DEK).
--
-- Every item is sealed under a per-item key derived from the vault DEK
-- (HKDF-SHA256(DEK, salt, info)), and the DEK is random per vault, wrapped
-- under the KEK derived from the master password, and stored only locally.
-- Without a way to carry the wrapped DEK between devices, a second device
-- with the same master password still derives a different DEK and cannot
-- open any synced item.
--
-- This table carries one row per user with the full serialized
-- MasterPasswordRecord (`record_json`): the wrapped DEK envelope, the KDF
-- parameters (salt + Argon2 settings), the verifier, the key id and the
-- record version. None of it reveals the master password or the DEK — the
-- wrapped DEK is encrypted under a KEK that only the master password can
-- re-derive. The verifier is a one-way hash. The salt and key id are not
-- secret.
--
-- `key_id` changes on rekey, so the put RPC upserts and the newest write
-- wins. A stale device pushing an old key after a rekey would regress the
-- key, so the caller must only push a key it just derived (it never pushes
-- a key read back from the backend).

create table if not exists public.vault_keys (
  user_id uuid primary key references auth.users (id) on delete cascade,
  key_id text not null,
  record_json text not null,
  updated_at timestamptz not null default now()
);

comment on column public.vault_keys.record_json is
  'Full serialized MasterPasswordRecord.encode(): wrapped DEK + KDF params + verifier + key id + version. Not secret on its own; only the master password can unwrap the DEK.';

alter table public.vault_keys enable row level security;
alter table public.vault_keys force row level security;

drop policy if exists vault_keys_select_owner on public.vault_keys;
create policy vault_keys_select_owner
on public.vault_keys
for select
using (auth.uid() = user_id);

drop policy if exists vault_keys_insert_owner on public.vault_keys;
create policy vault_keys_insert_owner
on public.vault_keys
for insert
with check (auth.uid() = user_id);

drop policy if exists vault_keys_update_owner on public.vault_keys;
create policy vault_keys_update_owner
on public.vault_keys
for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists vault_keys_delete_owner on public.vault_keys;
create policy vault_keys_delete_owner
on public.vault_keys
for delete
using (auth.uid() = user_id);

create or replace function public.rpc_vault_get_key()
returns table (
  key_id text,
  record_json text,
  updated_at timestamptz
)
language sql
security invoker
set search_path = public, pg_temp
as $$
  select k.key_id, k.record_json, k.updated_at
  from public.vault_keys k
  where k.user_id = auth.uid();
$$;

create or replace function public.rpc_vault_put_key(
  p_key_id text,
  p_record_json text
)
returns table (
  result_code text,
  key_id text
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_key_id text;
  v_record_json text;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return query select 'unauthenticated'::text, null::text;
    return;
  end if;

  v_key_id := nullif(trim(coalesce(p_key_id, '')), '');
  if v_key_id is null then
    return query select 'invalid_key'::text, null::text;
    return;
  end if;

  v_record_json := nullif(trim(coalesce(p_record_json, '')), '');
  if v_record_json is null then
    return query select 'invalid_record'::text, null::text;
    return;
  end if;

  insert into public.vault_keys (user_id, key_id, record_json)
  values (v_user_id, v_key_id, v_record_json)
  on conflict (user_id)
  do update
  set key_id = excluded.key_id,
      record_json = excluded.record_json,
      updated_at = now();

  return query select 'stored'::text, v_key_id;
end;
$$;

grant execute on function public.rpc_vault_get_key() to authenticated;

grant execute on function public.rpc_vault_put_key(text, text) to authenticated;
