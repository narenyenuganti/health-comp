-- Targeted group reactions retain the exact legacy five-key duel read model.
alter table private.competition_reactions add column target_profile_id uuid,
  drop constraint competition_reactions_one_per_target,
  add constraint competition_reactions_one_per_target unique nulls not distinct (competition_id,author_profile_id,target_profile_id,day_ordinal),
  add constraint competition_reactions_target_membership_fk foreign key (competition_id,target_profile_id)
    references public.competition_participants(competition_id,profile_id),
  add constraint competition_reactions_not_self check (target_profile_id <> author_profile_id);
create function private.default_duel_reaction_target()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.target_profile_id is null then
    select p.profile_id into new.target_profile_id from public.competition_participants p
      join public.competitions c on c.id = p.competition_id and c.format = 'duel'
      where p.competition_id = new.competition_id and p.profile_id <> new.author_profile_id;
  end if;
  if new.target_profile_id is null then raise exception 'reaction_target_required' using errcode = '23514'; end if;
  return new;
end; $$;
create trigger default_duel_reaction_target before insert or update on private.competition_reactions
  for each row execute function private.default_duel_reaction_target();
revoke all on function private.default_duel_reaction_target() from public,anon,authenticated,service_role;

create function public.nudge_competition_participant(competition_id uuid, recipient_profile_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  input_recipient_profile_id alias for recipient_profile_id;
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
   and p.state = 'accepted' and p.left_at is null
  where c.id = input_competition_id and c.format = 'doubles'
  for no key update of c;
  if not found then
    raise exception 'competition_not_found' using errcode = 'P0002';
  end if;
  -- The server keeps a match 'scheduled' until it completes, so the phase
  -- comes from the date in the match time zone.
  match_today := (as_of at time zone target.time_zone_identifier)::date;

  select p.profile_id into recipient_id
  from public.competition_participants p
  join public.profiles r on r.id = p.profile_id and r.state = 'active'
  where p.competition_id = target.id and p.profile_id = input_recipient_profile_id and p.profile_id <> caller_profile_id
    and p.team_number = (select own.team_number from public.competition_participants own where own.competition_id = target.id and own.profile_id = caller_profile_id)
    and p.state = 'accepted' and p.left_at is null;
  select pg_catalog.max(l.server_seq) into target_server_seq
  from public.competition_change_log l where l.competition_id = target.id;

  if recipient_id is null or target_server_seq is null
     or target.lifecycle not in ('scheduled', 'active', 'ends_today', 'tallying')
     or match_today < target.start_day
     or exists (select 1 from public.competition_group_results res
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
  where i.profile_id = recipient_id and i.state = 'active' and i.supports_group_matches
  order by i.installation_id
  on conflict on constraint competition_notification_work_identity_unique
  do nothing;

  perform private.request_competition_notification_worker();
  return pg_catalog.jsonb_build_object('nudged_at', as_of);
end;
$$;

create or replace function private.enqueue_reaction_notification(
  target_competition_id uuid,
  target_recipient_profile_id uuid,
  target_source_profile_id uuid
)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  target_server_seq bigint;
  decision_time timestamptz := pg_catalog.statement_timestamp();
  is_muted boolean;
begin
  -- ponytail: at most one per hour per match and recipient; the work row's identity (competition, server_seq, kind, recipient, installation)
  -- also makes a reaction with no new change-log row since the last reaction push silent. Change the identity if that ever matters.
  -- Filtered at enqueue only (the lease is unchanged): a row already pending when the recipient's install stops supporting reactions still sends.
  if exists (
    select 1 from private.competition_notification_work work_row
    where work_row.competition_id = target_competition_id
      and work_row.recipient_profile_id = target_recipient_profile_id
      and work_row.kind = 'reaction'
      and work_row.created_at > decision_time - interval '1 hour'
  ) then
    return;
  end if;

  select pg_catalog.max(log_row.server_seq) into target_server_seq
  from public.competition_change_log log_row
  where log_row.competition_id = target_competition_id;
  if target_server_seq is null then
    return;
  end if;
  is_muted := exists (
    select 1 from private.competition_notification_mutes mute_row
    where mute_row.profile_id = target_recipient_profile_id
      and mute_row.opponent_profile_id = target_source_profile_id
  );

  insert into private.competition_notification_work (
    semantic_id, competition_id, server_seq, kind,
    recipient_profile_id, source_profile_id, installation_id,
    state, available_at, created_at, updated_at, completed_at
  )
  select 'healthcomp.server-notification:v1:'
      || target_competition_id::text || ':reaction:'
      || target_server_seq::text || ':'
      || target_recipient_profile_id::text || ':'
      || installation_row.installation_id::text,
    target_competition_id, target_server_seq, 'reaction',
    target_recipient_profile_id, target_source_profile_id,
    installation_row.installation_id,
    case when is_muted then 'suppressed' else 'pending' end,
    decision_time, decision_time, decision_time,
    case when is_muted then decision_time else null end
  from public.device_installations installation_row
  join public.profiles profile_row on profile_row.id = installation_row.profile_id
  where installation_row.profile_id = target_recipient_profile_id
    and installation_row.state = 'active'
    and installation_row.supports_reactions
    and (installation_row.supports_group_matches or exists (select 1 from public.competitions c where c.id = target_competition_id and c.format = 'duel'))
    and profile_row.state = 'active'
  order by installation_row.installation_id
  on conflict on constraint competition_notification_work_identity_unique
  do nothing;

  perform private.request_competition_notification_worker();
end;
$$;

create function public.set_competition_reaction(
  competition_id uuid,
  day_ordinal integer,
  reaction text,
  target_profile_id uuid
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  input_day_ordinal alias for day_ordinal;
  input_reaction alias for reaction;
  input_target_profile_id alias for target_profile_id;
  caller_profile_id uuid := private.require_active_caller_profile_id();
  decision_time timestamptz := pg_catalog.statement_timestamp();
  target record;
  other_profile_id uuid;
  current_reaction text;
  recipient record;
begin
  if input_day_ordinal is null or input_target_profile_id is null or input_competition_id is null
     or (input_day_ordinal is not null and input_day_ordinal not between 1 and 7)
     or (input_reaction is not null
       and input_reaction not in ('clap', 'fire', 'huffing', 'salute')) then
    raise exception 'invalid_reaction' using errcode = '22023';
  end if;

  -- Locking the match serializes one person's taps and the hourly push check.
  select c.id, c.lifecycle, c.time_zone_identifier, c.start_day,
    c.next_server_seq
  into target
  from public.competitions c
  join public.competition_participants p
    on p.competition_id = c.id and p.profile_id = caller_profile_id
   and p.state = 'accepted' and p.left_at is null
  where c.id = input_competition_id and c.format <> 'duel'
  for no key update of c;

  -- One answer for every refusal, so a non-participant learns nothing.
  if not found then
    raise exception 'reaction_not_allowed' using errcode = 'P0001';
  end if;
  select p.profile_id into other_profile_id
  from public.competition_participants p
  join public.profiles other_profile
    on other_profile.id = p.profile_id and other_profile.state = 'active'
  where p.competition_id = target.id and p.profile_id = input_target_profile_id and p.profile_id <> caller_profile_id
    and input_day_ordinal <= coalesce(p.frozen_through_day,7)
    and p.state = 'accepted';

  if other_profile_id is null
     or (input_day_ordinal is not null
       and (target.lifecycle not in ('scheduled', 'active', 'ends_today', 'tallying')
         or input_day_ordinal > (decision_time at time zone target.time_zone_identifier)::date
           - target.start_day + 1))
     or (input_day_ordinal is null
       and (target.lifecycle not in ('completed', 'archived')
         or not exists (select 1 from public.competition_group_results res
           where res.competition_id = target.id))) then
    raise exception 'reaction_not_allowed' using errcode = 'P0001';
  end if;

  select r.reaction into current_reaction
  from private.competition_reactions r
  where r.competition_id = target.id
    and r.author_profile_id = caller_profile_id
    and r.target_profile_id = input_target_profile_id
    and r.day_ordinal is not distinct from input_day_ordinal;

  if current_reaction is not distinct from input_reaction then
    return pg_catalog.jsonb_build_object('competition_id', target.id,
      'day_ordinal', input_day_ordinal, 'reaction', input_reaction);
  end if;

  if input_reaction is null then
    delete from private.competition_reactions r
    where r.competition_id = target.id
      and r.author_profile_id = caller_profile_id
    and r.target_profile_id = input_target_profile_id
      and r.day_ordinal is not distinct from input_day_ordinal;
  else
    insert into private.competition_reactions as r (
      competition_id, author_profile_id, day_ordinal, reaction, target_profile_id,
      created_at, updated_at
    ) values (
      target.id, caller_profile_id, input_day_ordinal, input_reaction, input_target_profile_id,
      decision_time, decision_time
    )
    on conflict on constraint competition_reactions_one_per_target
    do update set reaction = excluded.reaction, updated_at = decision_time;
  end if;

  perform private.allocate_competition_server_seq(target.id,'group_reaction_changed',caller_profile_id,decision_time);
  -- 1900's broadcast_competition_change recipients (accepted, active), with
  -- the same event and payload, so every installed app just reconciles.
  for recipient in
    select p.profile_id
    from public.competition_participants p
    join public.profiles pr on pr.id = p.profile_id
    where p.competition_id = target.id and p.state = 'accepted'
      and pr.state = 'active'
    order by p.profile_id
  loop
    perform realtime.send(
      pg_catalog.jsonb_build_object(
        'server_cursor_hint', (target.next_server_seq - 1)::text
      ),
      'competition_changed',
      'profile:' || recipient.profile_id::text,
      true
    );
  end loop;

  if input_reaction is not null then
    perform private.enqueue_reaction_notification(
      target.id, other_profile_id, caller_profile_id
    );
  end if;

  -- ponytail: no per-author rate limit (participants only); add one if abused.
  return pg_catalog.jsonb_build_object('competition_id', target.id,
    'day_ordinal', input_day_ordinal, 'reaction', input_reaction);
end;
$$;

create or replace function private.can_view_profile(target_profile_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select current_profile.id is not null and (
    target_profile_id = current_profile.id or exists (
      select 1 from public.competition_participants own_membership
      join public.competition_participants counterpart_membership
        on counterpart_membership.competition_id = own_membership.competition_id
      join public.competitions c on c.id = own_membership.competition_id and c.format = 'duel'
      where own_membership.profile_id = current_profile.id
        and own_membership.state = 'accepted'
        and counterpart_membership.profile_id = target_profile_id
        and (
          (counterpart_membership.state in ('accepted', 'anonymized')
            and c.lifecycle in ('pending', 'scheduled', 'active', 'ends_today',
              'tallying', 'completed', 'archived', 'cancelled'))
          or (own_membership.role = 'creator'
            and c.invited_profile_id = target_profile_id
            and counterpart_membership.state in ('pending', 'anonymized'))
        )
    )
  ) from (select private.current_profile_id() as id) current_profile;
$$;

create or replace function private.can_view_profile_photo(target_profile_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select viewer.id is not null
    and exists (select 1 from public.profiles p
      where p.id = target_profile_id and p.state = 'active')
    and (
      target_profile_id = viewer.id
      or (
        not exists (select 1 from private.account_blocks b
          where (b.blocker_profile_id = viewer.id and b.blocked_profile_id = target_profile_id)
             or (b.blocker_profile_id = target_profile_id and b.blocked_profile_id = viewer.id))
        and not exists (select 1 from private.profile_photo_reports r
          where r.reporter_profile_id = viewer.id and r.reported_profile_id = target_profile_id)
        and (
          exists (select 1 from public.competitions c
            join public.competition_participants own on own.competition_id = c.id and own.profile_id = viewer.id and own.state in ('pending','accepted')
            join public.competition_participants other on other.competition_id = c.id and other.profile_id = target_profile_id and other.state = 'accepted'
            where c.format <> 'duel' and c.lifecycle = 'pending' and c.invitation_expires_at > pg_catalog.statement_timestamp()
              and not private.group_lineup_blocked(c.id))
          or exists (select 1 from public.competitions c
            join public.competition_participants own
              on own.competition_id = c.id and own.profile_id = viewer.id
                and own.state = 'accepted'
            join public.competition_participants other
              on other.competition_id = c.id and other.profile_id = target_profile_id
                and other.state = 'accepted'
            where c.lifecycle in ('scheduled', 'active', 'ends_today', 'tallying',
              'completed', 'archived'))
          or exists (select 1 from public.competitions c
            where c.creator_profile_id = target_profile_id
              and c.invited_profile_id = viewer.id and c.lifecycle = 'pending'
              and c.invitation_expires_at > pg_catalog.statement_timestamp())
        )
      )
    )
  from (select private.current_profile_id() as id) viewer;
$$;

create or replace function private.challenge_link_revoked_v1(
  sender_profile_id uuid,
  recipient_profile_id uuid
)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.competitions c
      join public.competition_invites i on i.competition_id = c.id
      where c.creator_profile_id = sender_profile_id
        and (c.invited_profile_id = recipient_profile_id and i.challenge_link_code is not null
          or exists (select 1 from public.competition_seats s where s.competition_id = c.id and s.profile_id = recipient_profile_id and s.challenge_link_code is not null)))
    and not exists (select 1 from public.competitions c
      join public.competition_invites i on i.competition_id = c.id
      join private.challenge_links l on l.profile_id = recipient_profile_id
        and (l.code = i.challenge_link_code or exists (select 1 from public.competition_seats s
          where s.competition_id = c.id and s.profile_id = recipient_profile_id and s.challenge_link_code = l.code))
      where c.creator_profile_id = sender_profile_id
        and (c.invited_profile_id = recipient_profile_id or exists (select 1 from public.competition_seats s
          where s.competition_id = c.id and s.profile_id = recipient_profile_id)))
    and not exists (select 1 from public.competitions c
      where c.creator_profile_id = recipient_profile_id
        and c.invited_profile_id = sender_profile_id)
    and not exists (select 1 from public.competitions c
      join public.competition_participants a
        on a.competition_id = c.id and a.profile_id = sender_profile_id
       and a.state = 'accepted'
      join public.competition_participants b
        on b.competition_id = c.id and b.profile_id = recipient_profile_id
       and b.state = 'accepted'
      where c.lifecycle in ('scheduled', 'active', 'ends_today', 'tallying',
        'completed', 'archived', 'cancelled'));
$$;

create or replace function public.block_challenger(competition_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  caller_profile_id uuid := private.require_active_caller_profile_id();
  decision_time timestamptz;
  sender_profile_id uuid;
  declined record;
begin
  if input_competition_id is null then
    raise exception 'invalid_competition_id' using errcode = '22023';
  end if;
  select c.creator_profile_id into sender_profile_id
  from public.competitions c
  where c.id = input_competition_id and (c.invited_profile_id = caller_profile_id or (c.format <> 'duel' and exists (
      select 1 from public.competition_participants p where p.competition_id = c.id and p.profile_id = caller_profile_id)))
    and c.creator_profile_id <> caller_profile_id;
  if sender_profile_id is null then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  perform 1 from public.profiles p
  where p.id in (sender_profile_id, caller_profile_id)
  order by p.id for no key update;
  -- A deletion that committed while this waited has already purged blocks.
  if not exists (select 1 from public.profiles p
    where p.id = caller_profile_id and p.state = 'active') then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;
  -- After the locks, so a create that waited on them is seen as pending.
  decision_time := pg_catalog.clock_timestamp();
  insert into private.account_blocks (blocker_profile_id, blocked_profile_id)
  select caller_profile_id, sender_profile_id
  where exists (select 1 from public.profiles p
    where p.id = sender_profile_id and p.state = 'active')
  on conflict do nothing;
  -- Decline's effects (1900): the invitee participant stays pending.
  for declined in
    update public.competitions c set lifecycle = 'declined',
      closed_by_profile_id = caller_profile_id, closed_at = decision_time,
      updated_at = decision_time
    where ((c.creator_profile_id = sender_profile_id and c.invited_profile_id = caller_profile_id)
      or (c.format <> 'duel' and exists (select 1 from public.competition_participants p where p.competition_id = c.id and p.profile_id = caller_profile_id)
        and exists (select 1 from public.competition_participants p where p.competition_id = c.id and p.profile_id = sender_profile_id)))
      and c.lifecycle = 'pending'
      and c.invitation_expires_at > decision_time
    returning c.id
  loop
    perform private.enqueue_challenge_notification(
      declined.id, 'challenge_declined', sender_profile_id, caller_profile_id);
  end loop;
  return pg_catalog.jsonb_build_object('competition_id', input_competition_id);
end;
$$;

revoke all on function public.nudge_competition_participant(uuid,uuid),public.set_competition_reaction(uuid,integer,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.nudge_competition_participant(uuid,uuid),public.set_competition_reaction(uuid,integer,text,uuid) to authenticated;

-- Backfill duel targets after all DDL and trigger installation.
update private.competition_reactions r set target_profile_id = p.profile_id
from public.competition_participants p where p.competition_id = r.competition_id and p.profile_id <> r.author_profile_id;
