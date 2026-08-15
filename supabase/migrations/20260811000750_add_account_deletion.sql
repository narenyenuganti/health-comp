create table private.account_deletions (
  profile_id uuid primary key references public.profiles(id),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  apple_provider_id text,
  phase text not null check (
    phase in (
      'prepared', 'token_ready', 'apple_revoked',
      'auth_delete_pending', 'completed'
    )
  ),
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint account_deletions_identity_shape_check check (
    (
      phase in (
        'prepared', 'token_ready', 'apple_revoked',
        'auth_delete_pending'
      )
      and auth_user_id is not null
      and apple_provider_id is not null
      and pg_catalog.btrim(apple_provider_id) <> ''
      and apple_provider_id !~ '[[:cntrl:]]'
      and pg_catalog.char_length(apple_provider_id) <= 255
      and completed_at is null
    )
    or (
      phase = 'completed'
      and auth_user_id is null
      and apple_provider_id is null
      and completed_at is not null
    )
  ),
  constraint account_deletions_timestamp_order_check check (
    updated_at >= started_at
    and (completed_at is null or completed_at >= started_at)
  )
);

alter table private.account_deletions enable row level security;
alter table private.account_deletions force row level security;

revoke all on table private.account_deletions
  from public, anon, authenticated, service_role;

create index account_deletions_auth_user_id_idx
  on private.account_deletions(auth_user_id)
  where auth_user_id is not null;

create or replace function private.account_deletion_secret_name(
  target_profile_id uuid
)
returns text
language sql
immutable
strict
set search_path = ''
as $$
  select 'healthcomp_account_deletion_token:' || target_profile_id::text;
$$;

revoke all on function private.account_deletion_secret_name(uuid)
  from public, anon, authenticated, service_role;

create or replace function private.complete_account_deletion_on_auth_removal()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.phase = 'completed' and new is distinct from old then
    raise exception 'completed_account_deletion_is_terminal'
      using errcode = '55000';
  end if;

  if old.auth_user_id is not null and new.auth_user_id is null then
    if old.phase <> 'auth_delete_pending' then
      raise exception 'account_deletion_auth_removed_before_anonymization'
        using errcode = '55000';
    end if;

    new.phase := 'completed';
    new.apple_provider_id := null;
    new.updated_at := pg_catalog.statement_timestamp();
    new.completed_at := new.updated_at;
  end if;

  return new;
end;
$$;

revoke all on function private.complete_account_deletion_on_auth_removal()
  from public, anon, authenticated, service_role;

create trigger complete_account_deletion_on_auth_removal
before update on private.account_deletions
for each row execute function private.complete_account_deletion_on_auth_removal();

create or replace function private.record_completed_account_deletion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.phase <> 'completed' and new.phase = 'completed' then
    delete from vault.secrets secret_row
    where secret_row.name = private.account_deletion_secret_name(
      new.profile_id
    );

    insert into public.support_events (
      profile_id, competition_id, kind, code, created_at
    ) values (
      new.profile_id,
      null,
      'account_deletion',
      'completed',
      new.completed_at
    );
  end if;

  return new;
end;
$$;

revoke all on function private.record_completed_account_deletion()
  from public, anon, authenticated, service_role;

create trigger record_completed_account_deletion
after update on private.account_deletions
for each row execute function private.record_completed_account_deletion();

create or replace function public.begin_account_deletion(
  target_auth_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_auth_user_id alias for target_auth_user_id;
  profile_row record;
  apple_provider_id text;
  deletion_row record;
  inserted_count integer;
  decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  if input_auth_user_id is null then
    raise exception 'invalid_account_deletion_identity'
      using errcode = '22023';
  end if;

  select deletion_record.*
  into deletion_row
  from private.account_deletions deletion_record
  where deletion_record.auth_user_id = input_auth_user_id
  for update;

  if found and deletion_row.phase = 'auth_delete_pending' then
    perform 1
    from public.profiles profile_record
    where profile_record.id = deletion_row.profile_id
      and profile_record.auth_user_id is null
      and profile_record.state = 'anonymized'
    for update;

    if not found then
      raise exception 'account_deletion_state_mismatch'
        using errcode = '55000';
    end if;

    return pg_catalog.jsonb_build_object(
      'profile_id', deletion_row.profile_id,
      'phase', deletion_row.phase,
      'apple_provider_id', deletion_row.apple_provider_id,
      'auth_user_id', deletion_row.auth_user_id
    );
  end if;

  select profile_record.id, profile_record.state
  into profile_row
  from public.profiles profile_record
  where profile_record.auth_user_id = input_auth_user_id
  for update;

  if not found or profile_row.state not in ('active', 'deleting') then
    raise exception 'account_deletion_profile_not_found'
      using errcode = 'P0002';
  end if;

  select identity_row.provider_id
  into apple_provider_id
  from auth.identities identity_row
  where identity_row.user_id = input_auth_user_id
    and identity_row.provider = 'apple'
  order by identity_row.created_at desc nulls last, identity_row.id
  limit 1;

  if apple_provider_id is null
     or pg_catalog.btrim(apple_provider_id) = ''
     or apple_provider_id ~ '[[:cntrl:]]'
     or pg_catalog.char_length(apple_provider_id) > 255 then
    raise exception 'apple_identity_required'
      using errcode = 'P0001';
  end if;

  insert into private.account_deletions (
    profile_id,
    auth_user_id,
    apple_provider_id,
    phase,
    started_at,
    updated_at
  ) values (
    profile_row.id,
    input_auth_user_id,
    apple_provider_id,
    'prepared',
    decision_time,
    decision_time
  )
  on conflict (profile_id) do nothing;

  get diagnostics inserted_count = row_count;

  select deletion_record.*
  into deletion_row
  from private.account_deletions deletion_record
  where deletion_record.profile_id = profile_row.id
  for update;

  if deletion_row.auth_user_id is distinct from input_auth_user_id
     or deletion_row.apple_provider_id is distinct from apple_provider_id
     or deletion_row.phase = 'completed' then
    raise exception 'account_deletion_identity_mismatch'
      using errcode = '55000';
  end if;

  if inserted_count = 1 then
    insert into public.support_events (
      profile_id, competition_id, kind, code, created_at
    ) values (
      profile_row.id,
      null,
      'account_deletion',
      'started',
      decision_time
    );
  end if;

  select deletion_record.*
  into deletion_row
  from private.account_deletions deletion_record
  where deletion_record.profile_id = profile_row.id;

  return pg_catalog.jsonb_build_object(
    'profile_id', deletion_row.profile_id,
    'phase', deletion_row.phase,
    'apple_provider_id', deletion_row.apple_provider_id,
    'auth_user_id', deletion_row.auth_user_id
  );
end;
$$;

create or replace function public.store_account_deletion_apple_token(
  target_profile_id uuid,
  refresh_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_profile_id alias for target_profile_id;
  input_refresh_token alias for refresh_token;
  deletion_row record;
  secret_name text;
  decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  if input_profile_id is null
     or input_refresh_token is null
     or pg_catalog.char_length(input_refresh_token) not between 16 and 4096
     or input_refresh_token ~ '[[:space:][:cntrl:]]' then
    raise exception 'invalid_apple_refresh_token'
      using errcode = '22023';
  end if;

  select deletion_record.*
  into deletion_row
  from private.account_deletions deletion_record
  where deletion_record.profile_id = input_profile_id
  for update;

  if not found then
    raise exception 'account_deletion_not_found' using errcode = 'P0002';
  end if;

  if deletion_row.phase = 'token_ready' then
    return pg_catalog.jsonb_build_object(
      'profile_id', deletion_row.profile_id,
      'phase', deletion_row.phase
    );
  end if;

  if deletion_row.phase <> 'prepared' then
    raise exception 'invalid_account_deletion_phase'
      using errcode = '55000';
  end if;

  perform 1
  from public.profiles profile_record
  where profile_record.id = input_profile_id
    and profile_record.state = 'active'
  for update;

  if not found then
    raise exception 'active_profile_required' using errcode = '55000';
  end if;

  secret_name := private.account_deletion_secret_name(input_profile_id);
  delete from vault.secrets secret_row where secret_row.name = secret_name;
  perform vault.create_secret(
    input_refresh_token,
    secret_name,
    'Temporary Sign in with Apple token for durable account deletion'
  );

  update public.profiles profile_record
  set state = 'deleting',
      updated_at = decision_time
  where profile_record.id = input_profile_id;

  perform competition_record.id
  from public.competitions competition_record
  join public.competition_participants participant_record
    on participant_record.competition_id = competition_record.id
  where participant_record.profile_id = input_profile_id
    and competition_record.lifecycle in (
      'pending', 'scheduled', 'active', 'ends_today', 'tallying'
    )
  order by competition_record.id
  for update of competition_record;

  update public.competitions competition_record
  set lifecycle = 'cancelled',
      updated_at = decision_time
  where competition_record.lifecycle in (
      'pending', 'scheduled', 'active', 'ends_today', 'tallying'
    )
    and exists (
      select 1
      from public.competition_participants participant_record
      where participant_record.competition_id = competition_record.id
        and participant_record.profile_id = input_profile_id
    );

  delete from public.competition_invites invite_record
  where invite_record.consumed_at is null
    and exists (
      select 1
      from public.competitions competition_record
      join public.competition_participants participant_record
        on participant_record.competition_id = competition_record.id
      where competition_record.id = invite_record.competition_id
        and competition_record.lifecycle = 'cancelled'
        and participant_record.profile_id = input_profile_id
    );

  update public.device_installations installation_record
  set state = 'revoked',
      updated_at = decision_time
  where installation_record.profile_id = input_profile_id
    and installation_record.state = 'active';

  update private.competition_notification_work work_record
  set state = 'superseded',
      lease_token = null,
      lease_expires_at = null,
      leased_apns_token_sha256 = null,
      updated_at = decision_time,
      completed_at = decision_time
  where work_record.state in ('pending', 'leased')
    and (
      work_record.recipient_profile_id = input_profile_id
      or work_record.source_profile_id = input_profile_id
    );

  delete from private.competition_notification_mutes mute_record
  where mute_record.profile_id = input_profile_id
     or mute_record.opponent_profile_id = input_profile_id;

  update private.account_deletions deletion_record
  set phase = 'token_ready',
      updated_at = decision_time
  where deletion_record.profile_id = input_profile_id
  returning deletion_record.* into deletion_row;

  return pg_catalog.jsonb_build_object(
    'profile_id', deletion_row.profile_id,
    'phase', deletion_row.phase
  );
end;
$$;

create or replace function public.load_account_deletion_apple_token(
  target_profile_id uuid
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_profile_id alias for target_profile_id;
  deletion_phase text;
  stored_token text;
begin
  select deletion_record.phase
  into deletion_phase
  from private.account_deletions deletion_record
  where deletion_record.profile_id = input_profile_id
  for update;

  if not found then
    raise exception 'account_deletion_not_found' using errcode = 'P0002';
  end if;

  if deletion_phase <> 'token_ready' then
    raise exception 'account_deletion_token_not_ready'
      using errcode = '55000';
  end if;

  select secret_row.decrypted_secret
  into stored_token
  from vault.decrypted_secrets secret_row
  where secret_row.name = private.account_deletion_secret_name(
    input_profile_id
  );

  if stored_token is null then
    raise exception 'account_deletion_token_unavailable'
      using errcode = '55000';
  end if;

  return stored_token;
end;
$$;

create or replace function public.mark_account_deletion_apple_revoked(
  target_profile_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_profile_id alias for target_profile_id;
  deletion_row record;
  decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  select deletion_record.*
  into deletion_row
  from private.account_deletions deletion_record
  where deletion_record.profile_id = input_profile_id
  for update;

  if not found then
    raise exception 'account_deletion_not_found' using errcode = 'P0002';
  end if;

  if deletion_row.phase in (
    'apple_revoked', 'auth_delete_pending', 'completed'
  ) then
    return pg_catalog.jsonb_build_object(
      'profile_id', deletion_row.profile_id,
      'phase', deletion_row.phase
    );
  end if;

  if deletion_row.phase <> 'token_ready' then
    raise exception 'invalid_account_deletion_phase'
      using errcode = '55000';
  end if;

  delete from vault.secrets secret_row
  where secret_row.name = private.account_deletion_secret_name(
    input_profile_id
  );

  update private.account_deletions deletion_record
  set phase = 'apple_revoked',
      updated_at = decision_time
  where deletion_record.profile_id = input_profile_id
  returning deletion_record.* into deletion_row;

  return pg_catalog.jsonb_build_object(
    'profile_id', deletion_row.profile_id,
    'phase', deletion_row.phase
  );
end;
$$;

create or replace function public.anonymize_account_deletion(
  target_profile_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_profile_id alias for target_profile_id;
  deletion_row record;
  profile_state text;
  decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  select deletion_record.*
  into deletion_row
  from private.account_deletions deletion_record
  where deletion_record.profile_id = input_profile_id
  for update;

  if not found then
    raise exception 'account_deletion_not_found' using errcode = 'P0002';
  end if;

  if deletion_row.phase in ('auth_delete_pending', 'completed') then
    return pg_catalog.jsonb_build_object(
      'profile_id', deletion_row.profile_id,
      'phase', deletion_row.phase,
      'auth_user_id', deletion_row.auth_user_id
    );
  end if;

  if deletion_row.phase <> 'apple_revoked' then
    raise exception 'invalid_account_deletion_phase'
      using errcode = '55000';
  end if;

  select profile_record.state
  into profile_state
  from public.profiles profile_record
  where profile_record.id = input_profile_id
  for update;

  if not found or profile_state <> 'deleting' then
    raise exception 'deleting_profile_required' using errcode = '55000';
  end if;

  update public.competition_participants participant_record
  set state = 'anonymized',
      updated_at = decision_time
  where participant_record.profile_id = input_profile_id
    and participant_record.state <> 'anonymized';

  update public.profiles profile_record
  set auth_user_id = null,
      display_name = 'Former competitor',
      state = 'anonymized',
      anonymized_at = decision_time,
      updated_at = decision_time
  where profile_record.id = input_profile_id;

  update private.account_deletions deletion_record
  set phase = 'auth_delete_pending',
      updated_at = decision_time
  where deletion_record.profile_id = input_profile_id
  returning deletion_record.* into deletion_row;

  return pg_catalog.jsonb_build_object(
    'profile_id', deletion_row.profile_id,
    'phase', deletion_row.phase,
    'auth_user_id', deletion_row.auth_user_id
  );
end;
$$;

create or replace function public.complete_account_deletion(
  target_profile_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_profile_id alias for target_profile_id;
  deletion_row record;
begin
  select deletion_record.*
  into deletion_row
  from private.account_deletions deletion_record
  where deletion_record.profile_id = input_profile_id
  for update;

  if not found then
    raise exception 'account_deletion_not_found' using errcode = 'P0002';
  end if;

  if deletion_row.phase <> 'completed'
     or deletion_row.auth_user_id is not null then
    raise exception 'account_auth_deletion_pending'
      using errcode = '55000';
  end if;

  return pg_catalog.jsonb_build_object(
    'profile_id', deletion_row.profile_id,
    'phase', deletion_row.phase,
    'completed_at', deletion_row.completed_at
  );
end;
$$;

revoke all on function public.begin_account_deletion(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.store_account_deletion_apple_token(uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function public.load_account_deletion_apple_token(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.mark_account_deletion_apple_revoked(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.anonymize_account_deletion(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.complete_account_deletion(uuid)
  from public, anon, authenticated, service_role;

grant execute on function public.begin_account_deletion(uuid)
  to service_role;
grant execute on function public.store_account_deletion_apple_token(uuid, text)
  to service_role;
grant execute on function public.load_account_deletion_apple_token(uuid)
  to service_role;
grant execute on function public.mark_account_deletion_apple_revoked(uuid)
  to service_role;
grant execute on function public.anonymize_account_deletion(uuid)
  to service_role;
grant execute on function public.complete_account_deletion(uuid)
  to service_role;
