-- Nudge: one generic push asking the other person to open HealthComp when
-- the result waits on their last check, or their newest upload in a live
-- match is over 12 hours old. Once per sender per match per match day, and
-- 12 hours apart. No change-log row: the feed has no 'nudge' change kind.

alter table private.competition_notification_work
  add column nudge_day date,
  drop constraint competition_notification_work_kind_check,
  add constraint competition_notification_work_kind_check check (
    kind in ('score_update', 'result', 'challenge_received',
      'challenge_declined', 'match_cancelled', 'nudge')
  ),
  add constraint competition_notification_work_nudge_day_shape
    check ((kind = 'nudge') = (nudge_day is not null));

-- Same name, so existing ON CONFLICT ON CONSTRAINT callers are unchanged.
-- A nudge on a later day can share the match's server_seq.
alter table private.competition_notification_work
  drop constraint competition_notification_work_identity_unique;
alter table private.competition_notification_work
  add constraint competition_notification_work_identity_unique
  unique nulls not distinct (
    competition_id, server_seq, kind, recipient_profile_id,
    installation_id, nudge_day
  );

create function public.nudge_competition_participant(competition_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  caller_profile_id uuid := private.require_active_caller_profile_id();
  as_of timestamptz := pg_catalog.statement_timestamp();
  target record;
  recipient_id uuid;
  match_today date;
  last_update timestamptz;
  target_server_seq bigint;
  is_muted boolean;
begin
  if input_competition_id is null then
    raise exception 'invalid_competition_id' using errcode = '22023';
  end if;
  -- Locking the caller's own participant row (no key update, so score
  -- inserts' FK checks never wait) serializes a double tap.
  select c.id, c.lifecycle, c.time_zone_identifier, c.start_day,
    c.best_available_deadline
  into target
  from public.competitions c
  join public.competition_participants p
    on p.competition_id = c.id and p.profile_id = caller_profile_id
   and p.state = 'accepted'
  where c.id = input_competition_id
  for no key update of p;
  if not found then
    raise exception 'competition_not_found' using errcode = 'P0002';
  end if;
  -- The server keeps a match 'scheduled' until it completes, so the phase
  -- comes from the date in the match time zone.
  match_today := (as_of at time zone target.time_zone_identifier)::date;

  select p.profile_id into recipient_id
  from public.competition_participants p
  join public.profiles r on r.id = p.profile_id and r.state = 'active'
  where p.competition_id = target.id and p.profile_id <> caller_profile_id
    and p.state = 'accepted';
  select pg_catalog.max(l.server_seq) into target_server_seq
  from public.competition_change_log l where l.competition_id = target.id;

  if recipient_id is null or target_server_seq is null
     or target.lifecycle not in ('scheduled', 'active', 'ends_today', 'tallying')
     or match_today < target.start_day
     or exists (select 1 from public.competition_results res
       where res.competition_id = target.id) then
    raise exception 'nudge_not_allowed' using errcode = 'P0001';
  end if;
  if match_today > target.start_day + 6 then
    -- After Day 7: the result waits on their stable check.
    if as_of >= target.best_available_deadline or exists (
      select 1 from public.participant_finalization_attestations a
      where a.competition_id = target.id
        and a.participant_profile_id = recipient_id
        and a.basis = 'stable') then
      raise exception 'nudge_not_allowed' using errcode = 'P0001';
    end if;
  else
    -- Live: their newest upload, or Day 1's start, is over 12 hours old.
    select pg_catalog.max(s.received_at) into last_update
    from public.daily_score_revisions s
    where s.competition_id = target.id
      and s.participant_profile_id = recipient_id;
    if coalesce(last_update,
         target.start_day::timestamp at time zone target.time_zone_identifier)
       > as_of - interval '12 hours' then
      raise exception 'nudge_not_allowed' using errcode = 'P0001';
    end if;
  end if;

  -- Already nudged today, or within 12 hours: same answer, nothing queued.
  -- Every success returns as_of, never a stored time, so the answer doesn't
  -- reveal whether the recipient has a device (no device = no rows).
  -- ponytail: no-device nudges aren't rate-limited (nothing to deliver); store a marker row if a non-push channel is added.
  if exists (
    select 1 from private.competition_notification_work w
    where w.competition_id = target.id and w.kind = 'nudge'
      and w.source_profile_id = caller_profile_id
      and (w.nudge_day = match_today
        or w.created_at > as_of - interval '12 hours')) then
    return pg_catalog.jsonb_build_object('nudged_at', as_of);
  end if;

  is_muted := exists (
    select 1 from private.competition_notification_mutes m
    where m.profile_id = recipient_id
      and m.opponent_profile_id = caller_profile_id);
  insert into private.competition_notification_work (
    semantic_id, competition_id, server_seq, kind, nudge_day,
    recipient_profile_id, source_profile_id, installation_id,
    state, available_at, created_at, updated_at, completed_at
  )
  select 'healthcomp.server-notification:v1:' || target.id::text
      || ':nudge:' || match_today::text || ':'
      || recipient_id::text || ':' || i.installation_id::text,
    target.id, target_server_seq, 'nudge', match_today,
    recipient_id, caller_profile_id, i.installation_id,
    case when is_muted then 'suppressed' else 'pending' end,
    as_of, as_of, as_of,
    case when is_muted then as_of else null end
  from public.device_installations i
  where i.profile_id = recipient_id and i.state = 'active'
  order by i.installation_id
  on conflict on constraint competition_notification_work_identity_unique
  do nothing;

  perform private.request_competition_notification_worker();
  return pg_catalog.jsonb_build_object('nudged_at', as_of);
end;
$$;
revoke all on function public.nudge_competition_participant(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.nudge_competition_participant(uuid)
  to authenticated;

-- 2300's lease plus one discard rule: a nudge from a deleted account, or for
-- a match that finished after it was queued. Leased items keep the same
-- seven keys.
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
             ) then 'suppressed'
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
