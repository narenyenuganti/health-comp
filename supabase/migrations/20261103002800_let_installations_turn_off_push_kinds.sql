-- Notification choices: an installation can turn off server-sent push kinds
-- (Account → Notifications: Reactions, Nudges). The lease marks their work
-- 'suppressed', like a mute, so a switch also holds back work already
-- queued. Builds without the switch register through the older overloads,
-- which store '{}', so they keep getting every kind.

alter table public.device_installations
  add column muted_push_kinds text[] not null default '{}'
  constraint device_installations_muted_push_kinds_check
  check (muted_push_kinds <@ array['nudge', 'reaction']::text[]);

-- 2700's five-argument registration plus muted_push_kinds.
create function public.register_current_device_installation(
  installation_id uuid,
  apns_token text,
  environment text,
  supports_challenges boolean,
  supports_reactions boolean,
  muted_push_kinds text[]
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
  caller_profile_id uuid;
  token_owner_profile_id uuid;
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
     or input_muted_push_kinds is null
     or not coalesce(
       input_muted_push_kinds <@ array['nudge', 'reaction']::text[], false
     ) then
    raise exception 'invalid_installation_request' using errcode = '22023';
  end if;

  select installation_row.profile_id
  into token_owner_profile_id
  from public.device_installations installation_row
  where installation_row.apns_token = input_apns_token
  for update;

  if found and token_owner_profile_id <> caller_profile_id then
    raise exception 'installation_unavailable' using errcode = 'P0001';
  end if;

  begin
    insert into public.device_installations as installation_target (
      profile_id, installation_id, apns_token, environment, state,
      supports_challenges, supports_reactions, muted_push_kinds
    ) values (
      caller_profile_id, input_installation_id, input_apns_token,
      input_environment, 'active', input_supports_challenges,
      input_supports_reactions, input_muted_push_kinds
    )
    on conflict on constraint device_installations_profile_installation_unique
    do update
    set apns_token = excluded.apns_token,
        environment = excluded.environment,
        state = 'active',
        supports_challenges = excluded.supports_challenges,
        supports_reactions = excluded.supports_reactions,
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

-- The previous build's call: same signature, same response, nothing
-- switched off. The three- and four-argument calls already delegate here.
create or replace function public.register_current_device_installation(
  installation_id uuid,
  apns_token text,
  environment text,
  supports_challenges boolean,
  supports_reactions boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  return public.register_current_device_installation(
    installation_id, apns_token, environment, supports_challenges,
    supports_reactions, '{}'::text[]
  );
end;
$$;

revoke all on function public.register_current_device_installation(
  uuid, text, text, boolean, boolean, text[]
) from public, anon, authenticated, service_role;
grant execute on function public.register_current_device_installation(
  uuid, text, text, boolean, boolean, text[]
) to authenticated;

-- 2500's lease (the newest), widening only the mute branch: work of a kind
-- the recipient's installation switched off resolves 'suppressed', like a
-- mute. 'discarded' stays for "this build can't show it".
create or replace function public.lease_competition_notification_work(
  batch_size integer default 25,
  lease_seconds integer default 180
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_batch_size alias for batch_size;
  input_lease_seconds alias for lease_seconds;
  as_of timestamptz := pg_catalog.statement_timestamp();
  result jsonb;
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  if input_batch_size is null or input_batch_size not between 1 and 100 then
    raise exception 'invalid_batch_size' using errcode = '22023';
  end if;
  if input_lease_seconds is null or input_lease_seconds not between 15 and 300 then
    raise exception 'invalid_lease_seconds' using errcode = '22023';
  end if;

  with locked_candidates as materialized (
    select work_row.id,
           work_row.available_at,
           work_row.created_at,
           installation_row.apns_token,
           installation_row.environment,
           case
             when work_row.attempt_count >= 10
               or installation_row.installation_id is null
               or installation_row.state <> 'active'
               or profile_row.id is null
               or profile_row.state <> 'active'
               or (work_row.kind in ('challenge_received', 'challenge_declined',
                     'match_cancelled')
                   and (source_profile_row.state is distinct from 'active'
                     or not installation_row.supports_challenges))
               or (work_row.kind = 'challenge_received'
                   and (competition_row.lifecycle is distinct from 'pending'
                     or competition_row.invitation_expires_at <= as_of))
               or (work_row.kind = 'nudge'
                   and (source_profile_row.state is distinct from 'active'
                     or coalesce(competition_row.lifecycle, '') not in
                       ('scheduled', 'active', 'ends_today', 'tallying')))
               then 'discarded'
             when exists (
               select 1
               from private.competition_notification_mutes mute_row
               where mute_row.profile_id = work_row.recipient_profile_id
                 and mute_row.opponent_profile_id
                   = work_row.source_profile_id
             )
               or work_row.kind = any(installation_row.muted_push_kinds)
               then 'suppressed'
             else 'lease'
           end as disposition
    from private.competition_notification_work work_row
    left join public.device_installations installation_row
      on installation_row.profile_id = work_row.recipient_profile_id
     and installation_row.installation_id = work_row.installation_id
    left join public.profiles profile_row
      on profile_row.id = work_row.recipient_profile_id
    left join public.profiles source_profile_row
      on source_profile_row.id = work_row.source_profile_id
    left join public.competitions competition_row
      on competition_row.id = work_row.competition_id
    where (
        work_row.state = 'pending'
        or (
          work_row.state = 'leased'
          and work_row.lease_expires_at <= as_of
        )
      )
    order by work_row.available_at, work_row.created_at, work_row.id
    for update of work_row skip locked
    limit input_batch_size * 4
  ), housekept as (
    update private.competition_notification_work work_row
    set state = candidate.disposition,
        lease_token = null,
        lease_expires_at = null,
        leased_apns_token_sha256 = null,
        updated_at = as_of,
        completed_at = as_of
    from locked_candidates candidate
    where work_row.id = candidate.id
      and candidate.disposition in ('discarded', 'suppressed')
    returning work_row.id
  ), candidates as materialized (
    select candidate.id,
           candidate.apns_token,
           candidate.environment,
           candidate.created_at
    from locked_candidates candidate
    where candidate.disposition = 'lease'
      and candidate.available_at <= as_of
    order by candidate.available_at, candidate.created_at, candidate.id
    limit input_batch_size
  ), leased as (
    update private.competition_notification_work work_row
    set state = 'leased',
        attempt_count = work_row.attempt_count + 1,
        lease_token = extensions.gen_random_uuid(),
        lease_expires_at = as_of
          + pg_catalog.make_interval(secs => input_lease_seconds),
        leased_apns_token_sha256 = extensions.digest(
          candidate.apns_token, 'sha256'
        ),
        updated_at = as_of,
        completed_at = null
    from candidates candidate
    where work_row.id = candidate.id
    returning work_row.id,
              work_row.lease_token,
              work_row.semantic_id,
              work_row.competition_id,
              work_row.kind,
              candidate.created_at,
              candidate.apns_token,
              candidate.environment
  )
  select pg_catalog.jsonb_build_object(
    'items', coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'workId', leased.id,
          'leaseToken', leased.lease_token,
          'semanticId', leased.semantic_id,
          'competitionId', leased.competition_id,
          'kind', leased.kind,
          'apnsToken', leased.apns_token,
          'environment', leased.environment
        ) order by leased.created_at, leased.id
      ),
      '[]'::jsonb
    )
  )
  into result
  from leased;

  return result;
end;
$$;
