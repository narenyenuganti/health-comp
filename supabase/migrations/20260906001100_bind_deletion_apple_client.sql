-- Deploy with the client-bound deletion worker, never the old unbound worker.
-- Existing revocable tokens require verified operator remediation, not a guessed
-- native/web client backfill. Later phases no longer require Apple revocation.
do $$
begin
  if exists (select 1 from private.account_deletions where phase = 'token_ready') then
    raise exception 'account_deletion_legacy_token_binding_required'
      using errcode = '55000';
  end if;
end;
$$;

alter table private.account_deletions
  add column apple_client_id text,
  add constraint account_deletions_client_shape_check check (
    apple_client_id is null or (
      pg_catalog.char_length(apple_client_id) between 1 and 255
      and apple_client_id !~ '[[:space:][:cntrl:]]'
    )
  ),
  add constraint account_deletions_token_binding_check check (
    phase <> 'token_ready' or apple_client_id is not null
  );

-- Preserve the existing transaction bodies, while making unbound entrypoints
-- inaccessible to API roles. The wrappers execute as their trusted owner.
alter function public.begin_account_deletion(uuid) set schema private;
revoke all on function private.begin_account_deletion(uuid)
  from public, anon, authenticated, service_role;
alter function public.store_account_deletion_apple_token(uuid, text) set schema private;
revoke all on function private.store_account_deletion_apple_token(uuid, text)
  from public, anon, authenticated, service_role;

create function public.begin_account_deletion(target_auth_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  progress jsonb;
  bound_client text;
begin
  progress := private.begin_account_deletion(target_auth_user_id);
  select d.apple_client_id into bound_client
  from private.account_deletions d
  where d.profile_id = (progress->>'profile_id')::uuid;
  return progress || pg_catalog.jsonb_build_object('apple_client_id', bound_client);
end;
$$;

create function public.store_account_deletion_apple_token(
  target_profile_id uuid,
  refresh_token text,
  apple_client_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_profile alias for target_profile_id;
  input_client alias for apple_client_id;
  deletion_row record;
  progress jsonb;
begin
  if input_client is null
     or pg_catalog.char_length(input_client) not between 1 and 255
     or input_client ~ '[[:space:][:cntrl:]]' then
    raise exception 'invalid_apple_client_binding' using errcode = '22023';
  end if;

  select d.* into deletion_row
  from private.account_deletions d
  where d.profile_id = input_profile
  for update;

  if not found then
    raise exception 'account_deletion_not_found' using errcode = 'P0002';
  end if;
  if deletion_row.apple_client_id is not null
     and deletion_row.apple_client_id <> input_client then
    raise exception 'account_deletion_client_binding_mismatch' using errcode = '55000';
  end if;
  if deletion_row.phase = 'prepared' then
    update private.account_deletions d
    set apple_client_id = input_client
    where d.profile_id = input_profile;
  elsif deletion_row.apple_client_id is null then
    raise exception 'account_deletion_client_binding_required' using errcode = '55000';
  end if;

  -- The binding, Vault write, profile transition and original side effects are
  -- one transaction. Any inner validation failure rolls the binding back too.
  progress := private.store_account_deletion_apple_token(input_profile, refresh_token);
  return progress || pg_catalog.jsonb_build_object('apple_client_id', input_client);
end;
$$;

revoke all on function public.begin_account_deletion(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.store_account_deletion_apple_token(uuid, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.begin_account_deletion(uuid) to service_role;
grant execute on function public.store_account_deletion_apple_token(uuid, text, text)
  to service_role;
