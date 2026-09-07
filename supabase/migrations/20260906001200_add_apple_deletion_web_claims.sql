create table private.apple_deletion_web_requests (
  request_id text primary key check (request_id ~ '^[0-9a-f]{64}$'),
  state_digest text not null unique check (state_digest ~ '^[0-9a-f]{64}$'),
  verifier_digest text not null check (verifier_digest ~ '^[0-9a-f]{64}$'),
  nonce text not null check (nonce ~ '^[0-9a-f]{64}$'),
  profile_id uuid not null references public.profiles(id),
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  apple_client_id text not null check (
    char_length(apple_client_id) between 1 and 255 and apple_client_id !~ '[[:space:][:cntrl:]]'),
  redirect_uri text not null check (
    char_length(redirect_uri) <= 2048 and redirect_uri ~ '^https://' and redirect_uri !~ '[[:space:][:cntrl:]]'),
  phase text not null check (phase in ('pending','code_ready','claimed','cancelled','expired')),
  created_at timestamptz not null default statement_timestamp(),
  expires_at timestamptz not null,
  check (expires_at > created_at)
);
alter table private.apple_deletion_web_requests enable row level security;
alter table private.apple_deletion_web_requests force row level security;
revoke all on private.apple_deletion_web_requests from public, anon, authenticated, service_role;
create index apple_deletion_web_expiry_idx on private.apple_deletion_web_requests(expires_at);

create function private.remove_apple_deletion_web_secret()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    delete from vault.secrets where name = 'healthcomp_web_deletion_code:' || old.request_id;
    return old;
  end if;
  if new.phase in ('claimed','cancelled','expired') then
    delete from vault.secrets where name = 'healthcomp_web_deletion_code:' || new.request_id;
  end if;
  return new;
end;
$$;
revoke all on function private.remove_apple_deletion_web_secret() from public, anon, authenticated, service_role;
create trigger remove_apple_deletion_web_secret
before update or delete on private.apple_deletion_web_requests
for each row execute function private.remove_apple_deletion_web_secret();

create function public.begin_apple_deletion_web_request(
  target_auth_user_id uuid, request_id text, state_digest text,
  verifier_digest text, nonce text, apple_client_id text, redirect_uri text
) returns void language plpgsql security definer set search_path = '' as $$
declare
  input_user alias for target_auth_user_id;
  input_request alias for request_id;
  input_state alias for state_digest;
  input_verifier alias for verifier_digest;
  input_nonce alias for nonce;
  input_client alias for apple_client_id;
  input_redirect alias for redirect_uri;
  owner_profile uuid;
begin
  select p.id into owner_profile from public.profiles p
  where p.auth_user_id = input_user and p.state = 'active'
  for update;
  if not found then
    raise exception 'active_profile_required' using errcode = '55000';
  end if;
  -- Serialize new requests by profile; replacement destroys old escrow.
  update private.apple_deletion_web_requests r set phase = 'cancelled'
  where r.profile_id = owner_profile and r.phase in ('pending','code_ready');
  insert into private.apple_deletion_web_requests(
    request_id,state_digest,verifier_digest,nonce,profile_id,auth_user_id,
    apple_client_id,redirect_uri,phase,expires_at
  ) values (input_request,input_state,input_verifier,input_nonce,owner_profile,
    input_user,input_client,input_redirect,'pending',
    pg_catalog.statement_timestamp() + interval '10 minutes');
end;
$$;
create function public.receive_apple_deletion_web_callback(
  state_digest text, authorization_code text, was_cancelled boolean
) returns text language plpgsql security definer set search_path = '' as $$
declare
  input_state alias for state_digest;
  input_code alias for authorization_code;
  r private.apple_deletion_web_requests%rowtype;
begin
  if was_cancelled is null or
     (was_cancelled and input_code is not null) or
     (not was_cancelled and (input_code is null or
       pg_catalog.char_length(input_code) not between 16 and 4096 or
       input_code ~ '[[:space:][:cntrl:]]')) then
    raise exception 'invalid_apple_deletion_callback' using errcode = '22023';
  end if;
  select w.* into r from private.apple_deletion_web_requests w
  where w.state_digest = input_state for update;
  if not found or r.phase <> 'pending' then return null; end if;
  if r.expires_at <= pg_catalog.statement_timestamp() then
    update private.apple_deletion_web_requests w set phase='expired'
    where w.request_id=r.request_id;
    return null;
  end if;
  if was_cancelled then
    update private.apple_deletion_web_requests w set phase='cancelled'
    where w.request_id=r.request_id;
  else
    perform vault.create_secret(input_code,
      'healthcomp_web_deletion_code:' || r.request_id,
      'Temporary Apple web deletion authorization code');
    update private.apple_deletion_web_requests w
    set phase='code_ready', expires_at=least(w.expires_at,
      pg_catalog.statement_timestamp()+interval '4 minutes')
    where w.request_id=r.request_id;
  end if;
  return r.request_id;
end;
$$;
create function public.claim_apple_deletion_web_request(
  target_auth_user_id uuid, request_id text, verifier_digest text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  input_user alias for target_auth_user_id;
  input_request alias for request_id;
  input_verifier alias for verifier_digest;
  r private.apple_deletion_web_requests%rowtype;
  stored_code text;
begin
  select w.* into r from private.apple_deletion_web_requests w
  where w.request_id=input_request and w.auth_user_id=input_user
    and w.verifier_digest=input_verifier for update;
  if not found or r.phase <> 'code_ready' then return null; end if;
  if r.expires_at <= pg_catalog.statement_timestamp() then
    update private.apple_deletion_web_requests w set phase='expired'
    where w.request_id=r.request_id;
    return null;
  end if;
  if not exists(select 1 from public.profiles p
    where p.id=r.profile_id and p.auth_user_id=input_user and p.state='active') then
    return null;
  end if;
  select s.decrypted_secret into stored_code from vault.decrypted_secrets s
  where s.name='healthcomp_web_deletion_code:' || r.request_id;
  if stored_code is null then
    raise exception 'apple_deletion_code_unavailable' using errcode = '55000';
  end if;
  -- Consume before releasing the row lock. A lost response requires a fresh
  -- Apple grant, never a second exchange of this single-use authorization code.
  update private.apple_deletion_web_requests w set phase='claimed'
  where w.request_id=r.request_id;
  return pg_catalog.jsonb_build_object('authorization_code',stored_code,
    'apple_client_id',r.apple_client_id,'redirect_uri',r.redirect_uri,'nonce',r.nonce);
end;
$$;
revoke all on function public.begin_apple_deletion_web_request(uuid,text,text,text,text,text,text)
  from public, anon, authenticated, service_role;
revoke all on function public.receive_apple_deletion_web_callback(text,text,boolean)
  from public, anon, authenticated, service_role;
revoke all on function public.claim_apple_deletion_web_request(uuid,text,text)
  from public, anon, authenticated, service_role;
grant execute on function public.begin_apple_deletion_web_request(uuid,text,text,text,text,text,text) to service_role;
grant execute on function public.receive_apple_deletion_web_callback(text,text,boolean) to service_role;
grant execute on function public.claim_apple_deletion_web_request(uuid,text,text) to service_role;

create function private.expire_apple_deletion_web_requests()
returns bigint language plpgsql security definer set search_path = '' as $$
declare removed bigint;
begin
  delete from private.apple_deletion_web_requests w where w.request_id in (
    select r.request_id from private.apple_deletion_web_requests r
    where r.expires_at <= pg_catalog.statement_timestamp()
    order by r.expires_at for update skip locked limit 100
  );
  get diagnostics removed = row_count;
  return removed;
end;
$$;
revoke all on function private.expire_apple_deletion_web_requests()
  from public, anon, authenticated, service_role;
select cron.schedule('healthcomp-expire-apple-web-deletion', '* * * * *',
  'select private.expire_apple_deletion_web_requests()');
