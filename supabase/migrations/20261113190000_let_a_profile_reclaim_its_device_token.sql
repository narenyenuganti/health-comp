-- A teardown that could not reach the server (session ended while the app was
-- closed, or removal failed offline) loses the local installation id but leaves
-- the row active. When the same profile registers that device token under a new
-- installation id, retire the old row (its token is cleared by
-- clear_retired_installation_apns_token) instead of failing forever.
-- Same signature and response; another profile's token stays unavailable.
create or replace function public.register_current_device_installation(
  installation_id uuid,
  apns_token text,
  environment text,
  supports_challenges boolean,
  supports_reactions boolean,
  supports_friends boolean,
  muted_push_kinds text[],
  supports_group_matches boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_installation_id alias for installation_id;
  input_apns_token alias for apns_token;
  input_environment alias for environment;
  input_supports_challenges alias for supports_challenges;
  input_supports_reactions alias for supports_reactions;
  input_muted_push_kinds alias for muted_push_kinds;
  input_supports_friends alias for supports_friends;
  input_supports_group_matches alias for supports_group_matches;
  caller_profile_id uuid;
  token_owner_profile_id uuid;
  token_owner_installation_id uuid;
  installation_record record;
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select profile_row.id
  into caller_profile_id
  from public.profiles profile_row
  where profile_row.auth_user_id = (select auth.uid())
    and profile_row.state = 'active';

  if caller_profile_id is null then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  if input_installation_id is null
     or input_apns_token is null
     or input_apns_token !~ '^[0-9a-f]{64,200}$'
     or input_environment not in ('sandbox', 'production')
     or input_supports_challenges is null
     or input_supports_reactions is null
     or input_supports_friends is null
     or input_supports_group_matches is null
     or input_muted_push_kinds is null
     or not coalesce(
       input_muted_push_kinds <@ array['nudge', 'reaction', 'friend_request', 'friend_accepted']::text[], false
     ) then
    raise exception 'invalid_installation_request' using errcode = '22023';
  end if;

  select installation_row.profile_id, installation_row.installation_id
  into token_owner_profile_id, token_owner_installation_id
  from public.device_installations installation_row
  where installation_row.apns_token = input_apns_token
  for update;

  if found and token_owner_profile_id <> caller_profile_id then
    raise exception 'installation_unavailable' using errcode = 'P0001';
  end if;

  if found and token_owner_installation_id <> input_installation_id then
    update public.device_installations as stale_installation
    set state = 'revoked',
        updated_at = pg_catalog.statement_timestamp()
    where stale_installation.profile_id = caller_profile_id
      and stale_installation.installation_id = token_owner_installation_id;
  end if;

  begin
    insert into public.device_installations as installation_target (
      profile_id, installation_id, apns_token, environment, state,
      supports_challenges, supports_reactions, supports_friends, muted_push_kinds, supports_group_matches
    ) values (
      caller_profile_id, input_installation_id, input_apns_token,
      input_environment, 'active', input_supports_challenges,
      input_supports_reactions, input_supports_friends, input_muted_push_kinds, input_supports_group_matches
    )
    on conflict on constraint device_installations_profile_installation_unique
    do update
    set apns_token = excluded.apns_token,
        environment = excluded.environment,
        state = 'active',
        supports_challenges = excluded.supports_challenges,
        supports_reactions = excluded.supports_reactions,
        supports_friends = excluded.supports_friends,
        supports_group_matches = excluded.supports_group_matches,
        muted_push_kinds = excluded.muted_push_kinds,
        updated_at = pg_catalog.statement_timestamp()
    returning installation_target.installation_id,
              installation_target.environment,
              installation_target.state
    into installation_record;
  exception
    when unique_violation then
      raise exception 'installation_unavailable' using errcode = 'P0001';
  end;

  return pg_catalog.jsonb_build_object(
    'installation_id', installation_record.installation_id,
    'environment', installation_record.environment,
    'state', installation_record.state
  );
end;
$$;
