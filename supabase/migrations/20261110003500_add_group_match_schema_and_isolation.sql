-- Group state is readable only through group RPCs; legacy policies stay byte-for-byte unchanged.
alter table public.competitions
  add column format text not null default 'duel' check (format in ('duel','three_way','four_way','doubles')),
  add column seat_count integer not null default 2,
  add column group_creation_request_sha256 bytea check (pg_catalog.octet_length(group_creation_request_sha256) = 32),
  add constraint competition_format_seats check (
    (format = 'duel' and seat_count = 2) or (format = 'three_way' and seat_count = 3)
    or (format in ('four_way','doubles') and seat_count = 4));
alter table public.competition_participants
  add column seat_index integer,
  add column team_number integer check (team_number in (1,2)),
  add column left_at timestamptz,
  add column frozen_through_day integer check (frozen_through_day between 0 and 7),
  add column frozen_revisions bigint[],
  drop constraint competition_participants_one_role,
  add constraint participant_seat_role check (seat_index is null
    or (role = 'creator' and seat_index = 1) or (role = 'invitee' and seat_index between 2 and 4)),
  add constraint participant_leave_shape check ((left_at is null and frozen_through_day is null and frozen_revisions is null)
    or (left_at is not null and frozen_through_day is not null
      and pg_catalog.cardinality(frozen_revisions) = 7 and 0 <= all(frozen_revisions)));
create unique index competition_participants_one_role
  on public.competition_participants (competition_id, role, coalesce(seat_index, 1));
create unique index competition_participants_one_seat
  on public.competition_participants (competition_id, seat_index);
alter table public.device_installations add column supports_group_matches boolean not null default false;

create table public.competition_seats (
  id uuid primary key default extensions.gen_random_uuid(),
  competition_id uuid not null references public.competitions(id),
  seat_index integer not null check (seat_index between 1 and 4),
  team_number integer check (team_number in (1,2)),
  kind text not null check (kind in ('human','bot')),
  profile_id uuid references public.profiles(id),
  challenge_link_code text check (challenge_link_code ~ '^[A-Za-z0-9_-]{22}$'),
  bot_mode text check (bot_mode in ('pacer','chill','erratic','beast')),
  bot_seed text check (bot_seed ~ '^(0|[1-9][0-9]{0,19})$' and bot_seed::numeric <= 18446744073709551615),
  bot_baseline integer check (bot_baseline between 100 and 600),
  bot_generator_version integer check (bot_generator_version = 1),
  bot_daily_totals integer[],
  unique (competition_id, seat_index),
  unique (competition_id, profile_id),
  foreign key (competition_id, profile_id) references public.competition_participants(competition_id, profile_id),
  check ((kind = 'human' and profile_id is not null and bot_mode is null and bot_seed is null
      and bot_baseline is null and bot_generator_version is null and bot_daily_totals is null)
    or (kind = 'bot' and profile_id is null and challenge_link_code is null and bot_mode is not null
      and ((bot_seed is null and bot_baseline is null and bot_generator_version is null and bot_daily_totals is null)
        or (bot_seed is not null and bot_baseline is not null and bot_generator_version is not null
          and pg_catalog.cardinality(bot_daily_totals) = 7
          and 0 <= all(bot_daily_totals) and 600 >= all(bot_daily_totals)))))
);
create table public.competition_group_results (
  competition_id uuid primary key references public.competitions(id),
  format text not null check (format in ('three_way','four_way','doubles')),
  finalization_basis text not null check (finalization_basis in ('stable','best_available')),
  completed_at timestamptz not null,
  standings jsonb not null check (pg_catalog.jsonb_typeof(standings) = 'array'),
  frozen_payload jsonb not null check (frozen_payload->>'version' = '1'),
  immutable_hash bytea not null check (pg_catalog.octet_length(immutable_hash) = 32),
  server_seq bigint not null check (server_seq > 0),
  foreign key (competition_id, server_seq) references public.competition_change_log(competition_id, server_seq)
);
alter table public.competition_seats enable row level security;
alter table public.competition_group_results enable row level security;
revoke all on public.competition_seats, public.competition_group_results from public, anon, authenticated, service_role;
create trigger assign_competition_group_result_sequence before insert on public.competition_group_results
  for each row execute function private.assign_competition_change_sequence('group_result_confirmed','competition_id');
create trigger reject_competition_group_result_mutation before update or delete on public.competition_group_results
  for each row execute function private.reject_append_only_mutation();

-- Existing open duel invitations may have no invited_profile_id, so no new identity guard is imposed on them.

create or replace function private.is_competition_participant(
  target_competition_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select current_profile.id is not null
    and exists (
      select 1
      from public.competition_participants participant_row
      where participant_row.competition_id = target_competition_id
        and participant_row.profile_id = current_profile.id
        and participant_row.state = 'accepted'
        and exists (select 1 from public.competitions c where c.id = target_competition_id and c.format = 'duel')
    )
  from (select private.current_profile_id() as id) current_profile;
$$;

create or replace function private.enforce_competition_participant_shape()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_competition_id uuid;
  participant_count integer;
  creator_count integer;
  target_lifecycle text;
begin
  target_competition_id := case
    when tg_table_name = 'competitions' then (pg_catalog.to_jsonb(new)->>'id')::uuid
    else (pg_catalog.to_jsonb(new)->>'competition_id')::uuid
  end;

  select count(participant_row.profile_id), count(participant_row.profile_id) filter (
    where role = 'creator' and profile_id = competition_row.creator_profile_id
  ), competition_row.lifecycle
  into participant_count, creator_count, target_lifecycle
  from public.competitions competition_row
  left join public.competition_participants participant_row
    on participant_row.competition_id = competition_row.id
  where competition_row.id = target_competition_id
  group by competition_row.lifecycle;

  if target_lifecycle is null then
    raise exception 'competition participant shape target is missing' using errcode = '23514';
  end if;

  if exists (select 1 from public.competitions c where c.id = target_competition_id and c.format <> 'duel') then
    if creator_count <> 1 or participant_count not between 2 and 4
      or (select count(*) from public.competition_seats s where s.competition_id = target_competition_id)
        <> (select c.seat_count from public.competitions c where c.id = target_competition_id)
      or exists (select 1 from public.competition_participants p
        where p.competition_id = target_competition_id and not exists (
          select 1 from public.competition_seats s where s.competition_id = p.competition_id
            and s.profile_id = p.profile_id and s.seat_index = p.seat_index
            and s.team_number is not distinct from p.team_number)) then
      raise exception 'group_participant_shape_invalid' using errcode = '23514';
    end if;
    return null;
  end if;

  if participant_count < 1 or participant_count > 2 or creator_count <> 1 then
    raise exception 'competition participant shape is invalid' using errcode = '23514';
  end if;

  if target_lifecycle in ('scheduled', 'active', 'ends_today', 'tallying', 'completed', 'archived')
     and participant_count <> 2 then
    raise exception 'accepted competition requires exactly two participants' using errcode = '23514';
  end if;

  return null;
end;
$$;

create or replace function private.match_in_progress_between(
  first_profile_id uuid,
  second_profile_id uuid
)
returns uuid language sql stable security definer set search_path = ''
as $$
  select c.id from (select * from public.competitions where format = 'duel') c
  join public.competition_participants first_participant
    on first_participant.competition_id = c.id
   and first_participant.profile_id = first_profile_id
   and first_participant.state = 'accepted'
  join public.competition_participants second_participant
    on second_participant.competition_id = c.id
   and second_participant.profile_id = second_profile_id
   and second_participant.state = 'accepted'
  where c.lifecycle in ('scheduled', 'active', 'ends_today', 'tallying')
    and (pg_catalog.statement_timestamp() at time zone c.time_zone_identifier)::date
      <= c.start_day + 6
  order by c.start_day, c.id
  limit 1;
$$;

create or replace function public.list_challenges()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  caller_profile_id uuid := private.require_active_caller_profile_id();
  as_of timestamptz := pg_catalog.statement_timestamp();
  incoming jsonb;
  closed jsonb;
begin
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'competition_id', r.id,
      'sender', pg_catalog.jsonb_build_object('id', r.sender_id,
        'display_name', r.sender_display_name),
      'time_zone_identifier', r.time_zone_identifier,
      'created_at', r.created_at,
      'expires_at', r.invitation_expires_at
    ) order by r.invitation_expires_at, r.id), '[]'::jsonb)
  into incoming
  from (
    select c.id, sender.id as sender_id, sender.display_name as sender_display_name,
      c.time_zone_identifier, c.created_at, c.invitation_expires_at
    from (select * from public.competitions where format = 'duel') c
    join public.profiles sender on sender.id = c.creator_profile_id
    where c.invited_profile_id = caller_profile_id
      and c.lifecycle = 'pending'
      and c.invitation_expires_at > as_of
      and sender.state = 'active'
    order by c.invitation_expires_at, c.id
    limit 50
  ) r;

  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'competition_id', r.id,
      'kind', r.lifecycle,
      'other', pg_catalog.jsonb_build_object('id', r.other_id,
        'display_name', r.other_display_name),
      'closed_at', r.closed_at
    ) order by r.closed_at desc, r.id), '[]'::jsonb)
  into closed
  from (
    select c.id, c.lifecycle, other_profile.id as other_id,
      other_profile.display_name as other_display_name, c.closed_at
    from (select * from public.competitions where format = 'duel') c
    join public.competition_participants own_membership
      on own_membership.competition_id = c.id
     and own_membership.profile_id = caller_profile_id
    join public.profiles other_profile on other_profile.id = c.closed_by_profile_id
    where c.closed_by_profile_id <> caller_profile_id
      and c.closed_at > as_of - interval '24 hours'
      and other_profile.state in ('active', 'anonymized')
      and (
        (c.lifecycle = 'declined' and c.creator_profile_id = caller_profile_id)
        or (c.lifecycle = 'cancelled' and own_membership.state = 'accepted')
      )
    order by c.closed_at desc, c.id
    limit 50
  ) r;

  return pg_catalog.jsonb_build_object('incoming', incoming, 'closed', closed);
end;
$$;

create or replace function public.preview_competition_invite(token_digest bytea)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  input_token_digest alias for token_digest;
  caller_profile_id uuid;
  target record;
  preview_state text := 'pending';
begin
  if (select auth.role()) is distinct from 'authenticated' or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if input_token_digest is null or pg_catalog.octet_length(input_token_digest) <> 32 then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  caller_profile_id := private.current_profile_id();
  if caller_profile_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  select i.claimed_profile_id, i.consumed_at, i.expires_at, c.id, c.creator_profile_id,
    c.invited_profile_id, c.time_zone_identifier, c.lifecycle, c.invitation_expires_at,
    sender.display_name as sender_display_name, sender.state as sender_state
  into target from public.competition_invites i
  join (select * from public.competitions where format = 'duel') c on c.id = i.competition_id
  join public.profiles sender on sender.id = c.creator_profile_id
  where i.token_digest = input_token_digest;
  if found and target.consumed_at is not null
     and target.claimed_profile_id = caller_profile_id then
    preview_state := 'accepted';
  elsif not found or target.consumed_at is not null
     or target.claimed_profile_id is not null
     or target.expires_at <= pg_catalog.statement_timestamp()
     or target.lifecycle <> 'pending' then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  elsif target.creator_profile_id = caller_profile_id then
    raise exception 'cannot_claim_own_invite' using errcode = 'P0001';
  elsif target.invited_profile_id is distinct from caller_profile_id then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  elsif private.match_in_progress_between(target.creator_profile_id, caller_profile_id)
     is not null then
    raise exception 'active_match_exists' using errcode = 'P0001';
  end if;
  if target.sender_state <> 'active' then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  return pg_catalog.jsonb_build_object(
    'competition_id', target.id,
    'state', preview_state,
    'sender', pg_catalog.jsonb_build_object(
      'id', target.creator_profile_id, 'display_name', target.sender_display_name),
    'time_zone_identifier', target.time_zone_identifier,
    'expires_at', target.invitation_expires_at
  );
end;
$$;

create or replace function public.decline_competition_challenge(competition_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  caller_profile_id uuid := private.require_active_caller_profile_id();
  decision_time timestamptz := pg_catalog.statement_timestamp();
  target record;
begin
  if input_competition_id is null then
    raise exception 'invalid_competition_id' using errcode = '22023';
  end if;
  select c.id, c.creator_profile_id, c.invited_profile_id, c.lifecycle,
    c.invitation_expires_at, c.closed_by_profile_id
  into target from (select * from public.competitions where format = 'duel') c where c.id = input_competition_id for update;
  if found and target.lifecycle = 'declined'
     and target.closed_by_profile_id = caller_profile_id then
    return pg_catalog.jsonb_build_object('competition_id', target.id);
  end if;
  if not found or target.invited_profile_id is distinct from caller_profile_id
     or target.lifecycle <> 'pending' or target.invitation_expires_at <= decision_time then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  -- The invitee participant stays pending, so the creator can still render the
  -- recipient's name (can_view_profile's creator clause) in every app version.
  update public.competitions set lifecycle = 'declined',
    closed_by_profile_id = caller_profile_id, closed_at = decision_time,
    updated_at = decision_time
  where id = target.id;
  perform private.enqueue_challenge_notification(
    target.id, 'challenge_declined', target.creator_profile_id, caller_profile_id);
  return pg_catalog.jsonb_build_object('competition_id', target.id);
end;
$$;

create or replace function public.cancel_competition(competition_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  caller_profile_id uuid := private.require_active_caller_profile_id();
  decision_time timestamptz := pg_catalog.statement_timestamp();
  target record;
  other_profile_id uuid;
begin
  if input_competition_id is null then
    raise exception 'invalid_competition_id' using errcode = '22023';
  end if;
  select c.id, c.creator_profile_id, c.lifecycle, c.time_zone_identifier, c.start_day,
    c.closed_by_profile_id
  into target from (select * from public.competitions where format = 'duel') c where c.id = input_competition_id for update;
  if found and target.lifecycle = 'cancelled'
     and target.closed_by_profile_id = caller_profile_id then
    return pg_catalog.jsonb_build_object('competition_id', target.id);
  end if;
  if found and target.lifecycle = 'pending'
     and target.creator_profile_id = caller_profile_id then
    null;
  elsif found and target.lifecycle = 'scheduled'
     and (decision_time at time zone target.time_zone_identifier)::date < target.start_day
     and exists (select 1 from public.competition_participants p
       where p.competition_id = target.id and p.profile_id = caller_profile_id
         and p.state = 'accepted') then
    select p.profile_id into other_profile_id from public.competition_participants p
    where p.competition_id = target.id and p.profile_id <> caller_profile_id
      and p.state = 'accepted';
  else
    raise exception 'cancel_not_allowed' using errcode = 'P0001';
  end if;
  update public.competitions set lifecycle = 'cancelled',
    closed_by_profile_id = caller_profile_id, closed_at = decision_time,
    updated_at = decision_time
  where id = target.id;
  if other_profile_id is not null then
    perform private.enqueue_challenge_notification(
      target.id, 'match_cancelled', other_profile_id, caller_profile_id);
  end if;
  return pg_catalog.jsonb_build_object('competition_id', target.id);
end;
$$;

create or replace function public.nudge_competition_participant(competition_id uuid)
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
  from (select * from public.competitions where format = 'duel') c
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

create or replace function public.set_competition_reaction(
  competition_id uuid,
  day_ordinal integer,
  reaction text
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  input_day_ordinal alias for day_ordinal;
  input_reaction alias for reaction;
  caller_profile_id uuid := private.require_active_caller_profile_id();
  decision_time timestamptz := pg_catalog.statement_timestamp();
  target record;
  other_profile_id uuid;
  current_reaction text;
  recipient record;
begin
  if input_competition_id is null
     or (input_day_ordinal is not null and input_day_ordinal not between 1 and 7)
     or (input_reaction is not null
       and input_reaction not in ('clap', 'fire', 'huffing', 'salute')) then
    raise exception 'invalid_reaction' using errcode = '22023';
  end if;

  -- Locking the match serializes one person's taps and the hourly push check.
  select c.id, c.lifecycle, c.time_zone_identifier, c.start_day,
    c.next_server_seq
  into target
  from (select * from public.competitions where format = 'duel') c
  join public.competition_participants p
    on p.competition_id = c.id and p.profile_id = caller_profile_id
   and p.state = 'accepted'
  where c.id = input_competition_id
  for no key update of c;

  -- One answer for every refusal, so a non-participant learns nothing.
  if not found then
    raise exception 'reaction_not_allowed' using errcode = 'P0001';
  end if;
  select p.profile_id into other_profile_id
  from public.competition_participants p
  join public.profiles other_profile
    on other_profile.id = p.profile_id and other_profile.state = 'active'
  where p.competition_id = target.id and p.profile_id <> caller_profile_id
    and p.state = 'accepted';

  if other_profile_id is null
     or (input_day_ordinal is not null
       and (target.lifecycle not in ('scheduled', 'active', 'ends_today', 'tallying')
         or input_day_ordinal > (decision_time at time zone target.time_zone_identifier)::date
           - target.start_day + 1))
     or (input_day_ordinal is null
       and (target.lifecycle not in ('completed', 'archived')
         or not exists (select 1 from public.competition_results res
           where res.competition_id = target.id))) then
    raise exception 'reaction_not_allowed' using errcode = 'P0001';
  end if;

  select r.reaction into current_reaction
  from private.competition_reactions r
  where r.competition_id = target.id
    and r.author_profile_id = caller_profile_id
    and r.day_ordinal is not distinct from input_day_ordinal;

  if current_reaction is not distinct from input_reaction then
    return pg_catalog.jsonb_build_object('competition_id', target.id,
      'day_ordinal', input_day_ordinal, 'reaction', input_reaction);
  end if;

  if input_reaction is null then
    delete from private.competition_reactions r
    where r.competition_id = target.id
      and r.author_profile_id = caller_profile_id
      and r.day_ordinal is not distinct from input_day_ordinal;
  else
    insert into private.competition_reactions as r (
      competition_id, author_profile_id, day_ordinal, reaction,
      created_at, updated_at
    ) values (
      target.id, caller_profile_id, input_day_ordinal, input_reaction,
      decision_time, decision_time
    )
    on conflict on constraint competition_reactions_one_per_target
    do update set reaction = excluded.reaction, updated_at = decision_time;
  end if;

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

create or replace function public.archive_competition(competition_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  caller_profile_id uuid;
  archived_competition_id uuid;
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  if input_competition_id is null then
    raise exception 'invalid_competition_id' using errcode = '22023';
  end if;

  select profile_row.id
  into caller_profile_id
  from public.profiles profile_row
  where profile_row.auth_user_id = (select auth.uid())
    and profile_row.state = 'active';

  if caller_profile_id is null then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  update public.competitions competition_row
  set lifecycle = 'archived',
      updated_at = pg_catalog.statement_timestamp()
  where competition_row.format = 'duel' and competition_row.id = input_competition_id
    and competition_row.lifecycle = 'completed'
    and exists (
      select 1
      from public.competition_participants participant_row
      where participant_row.competition_id = competition_row.id
        and participant_row.profile_id = caller_profile_id
        and participant_row.state = 'accepted'
    )
  returning competition_row.id into archived_competition_id;

  if archived_competition_id is null then
    select competition_row.id
    into archived_competition_id
    from (select * from public.competitions where format = 'duel') competition_row
    where competition_row.format = 'duel' and competition_row.id = input_competition_id
      and competition_row.lifecycle = 'archived'
      and exists (
        select 1
        from public.competition_participants participant_row
        where participant_row.competition_id = competition_row.id
          and participant_row.profile_id = caller_profile_id
          and participant_row.state = 'accepted'
      );
  end if;

  if archived_competition_id is null then
    raise exception 'archive_not_allowed' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'competition_id', archived_competition_id
  );
end;
$$;

create or replace function private.accept_pending_invitation(
  target_competition_id uuid,
  caller_profile_id uuid
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  target_creator_profile_id uuid;
  target_invite record;
  frozen_start_day date;
  frozen_deadline timestamptz;
begin
  select c.creator_profile_id into target_creator_profile_id
  from (select * from public.competitions where format = 'duel') c where c.id = target_competition_id;
  if not found then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  perform 1 from public.profiles p
  where p.id in (target_creator_profile_id, caller_profile_id)
  order by p.id for no key update;

  select i.id, i.competition_id, i.claimed_profile_id, i.consumed_at, i.expires_at,
    c.creator_profile_id, c.invited_profile_id, c.time_zone_identifier, c.lifecycle
  into target_invite from (select * from public.competitions where format = 'duel') c
  join public.competition_invites i on i.competition_id = c.id
  where c.id = target_competition_id
  order by i.created_at desc, i.id
  limit 1
  for update of c, i;
  if found and target_invite.consumed_at is not null
     and target_invite.claimed_profile_id = caller_profile_id then
    return target_invite.competition_id;
  end if;
  if not found or target_invite.consumed_at is not null
     or target_invite.claimed_profile_id is not null
     or target_invite.expires_at <= pg_catalog.statement_timestamp()
     or target_invite.lifecycle <> 'pending' then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  if target_invite.creator_profile_id = caller_profile_id then
    raise exception 'cannot_claim_own_invite' using errcode = 'P0001';
  end if;
  if target_invite.invited_profile_id is distinct from caller_profile_id then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  if private.match_in_progress_between(target_invite.creator_profile_id, caller_profile_id)
     is not null then
    raise exception 'active_match_exists' using errcode = 'P0001';
  end if;
  frozen_start_day := (pg_catalog.statement_timestamp()
    at time zone target_invite.time_zone_identifier)::date + 1;
  frozen_deadline := ((frozen_start_day + private.best_available_local_day_offset_v1())::timestamp
    at time zone target_invite.time_zone_identifier);
  update public.competition_participants set state = 'accepted'
  where competition_id = target_invite.competition_id
    and profile_id = caller_profile_id and role = 'invitee' and state = 'pending';
  if not found then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  update public.competition_invites set claimed_profile_id = caller_profile_id,
    consumed_at = pg_catalog.statement_timestamp() where id = target_invite.id;
  update public.competitions set start_day = frozen_start_day, lifecycle = 'scheduled',
    best_available_deadline = frozen_deadline, updated_at = pg_catalog.statement_timestamp()
  where id = target_invite.competition_id;
  return target_invite.competition_id;
end;
$$;

create or replace function public.claim_competition_invite(token_digest bytea)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  input_token_digest alias for token_digest;
  caller_profile_id uuid;
  target_competition_id uuid;
begin
  if (select auth.role()) is distinct from 'authenticated' or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if input_token_digest is null or pg_catalog.octet_length(input_token_digest) <> 32 then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  caller_profile_id := private.current_profile_id();
  if caller_profile_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  select i.competition_id into target_competition_id
  from public.competition_invites i join public.competitions c on c.id = i.competition_id and c.format = 'duel' where i.token_digest = input_token_digest;
  if not found then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  return private.accept_pending_invitation(target_competition_id, caller_profile_id);
end;
$$;

create or replace function public.list_competition_reactions()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  caller_profile_id uuid := private.require_active_caller_profile_id();
  result jsonb;
begin
  -- ponytail: 2000 newest (about 125 finished matches). Page per match if anyone gets there.
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'competition_id', newest.competition_id,
      'day_ordinal', newest.day_ordinal,
      'author_profile_id', newest.author_profile_id,
      'reaction', newest.reaction,
      'updated_at', newest.updated_at
    ) order by newest.updated_at desc, newest.competition_id,
      newest.author_profile_id, newest.day_ordinal nulls first), '[]'::jsonb)
  into result
  from (
    select r.competition_id, r.day_ordinal, r.author_profile_id, r.reaction,
      r.updated_at
    from private.competition_reactions r join public.competitions c on c.id = r.competition_id and c.format = 'duel'
    join public.competition_participants p
      on p.competition_id = r.competition_id
     and p.profile_id = caller_profile_id
     and p.state = 'accepted'
    order by r.updated_at desc, r.competition_id, r.author_profile_id,
      r.day_ordinal nulls first
    limit 2000
  ) newest;
  return pg_catalog.jsonb_build_object('reactions', result);
end;
$$;

create or replace function private.enqueue_competition_notification_work()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_competition_id uuid;
  target_server_seq bigint;
  target_kind text;
  score_source_profile_id uuid;
  decision_time timestamptz := pg_catalog.statement_timestamp();
  recipient record;
  is_muted boolean;
  semantic_id text;
begin
  if exists (select 1 from public.competitions c where c.id = new.competition_id and c.format <> 'duel') then return new; end if;
  if tg_table_schema <> 'public' then
    raise exception 'invalid_notification_trigger' using errcode = '55000';
  end if;

  if tg_table_name = 'daily_score_revisions' then
    target_competition_id := new.competition_id;
    target_server_seq := new.server_seq;
    target_kind := 'score_update';
    score_source_profile_id := new.participant_profile_id;

    if not exists (
      select 1
      from public.competition_participants source_participant
      join public.profiles source_profile
        on source_profile.id = source_participant.profile_id
      where source_participant.competition_id = target_competition_id
        and source_participant.profile_id = score_source_profile_id
        and source_participant.state = 'accepted'
        and source_profile.state = 'active'
    ) then
      return new;
    end if;
  elsif tg_table_name = 'competition_results' then
    target_competition_id := new.competition_id;
    target_server_seq := new.server_seq;
    target_kind := 'result';
    score_source_profile_id := null;
  else
    raise exception 'invalid_notification_trigger' using errcode = '55000';
  end if;

  for recipient in
    select participant_row.profile_id as recipient_profile_id,
           opponent_row.profile_id as source_profile_id,
           installation_row.installation_id
    from public.competition_participants participant_row
    join public.profiles profile_row
      on profile_row.id = participant_row.profile_id
    join public.device_installations installation_row
      on installation_row.profile_id = participant_row.profile_id
     and installation_row.state = 'active'
    join lateral (
      select other_participant.profile_id
      from public.competition_participants other_participant
      join public.profiles other_profile
        on other_profile.id = other_participant.profile_id
      where other_participant.competition_id = target_competition_id
        and other_participant.profile_id <> participant_row.profile_id
        and other_participant.state = 'accepted'
        and other_profile.state = 'active'
      order by other_participant.profile_id
      limit 1
    ) opponent_row on true
    where participant_row.competition_id = target_competition_id
      and participant_row.state = 'accepted'
      and profile_row.state = 'active'
      and (
        target_kind = 'result'
        or participant_row.profile_id <> score_source_profile_id
      )
    order by participant_row.profile_id, installation_row.installation_id
  loop
    if target_kind = 'score_update'
       and recipient.source_profile_id <> score_source_profile_id then
      continue;
    end if;

    update private.competition_notification_work work_row
    set state = 'superseded',
        lease_token = null,
        lease_expires_at = null,
        leased_apns_token_sha256 = null,
        updated_at = decision_time,
        completed_at = decision_time
    where work_row.competition_id = target_competition_id
      and work_row.recipient_profile_id = recipient.recipient_profile_id
      and work_row.installation_id = recipient.installation_id
      and work_row.kind = 'score_update'
      and work_row.server_seq < target_server_seq
      and (
        work_row.state = 'pending'
        or (
          work_row.state = 'leased'
          and work_row.lease_expires_at <= decision_time
        )
      );

    is_muted := exists (
      select 1
      from private.competition_notification_mutes mute_row
      where mute_row.profile_id = recipient.recipient_profile_id
        and mute_row.opponent_profile_id = recipient.source_profile_id
    );
    semantic_id := 'healthcomp.server-notification:v1:'
      || target_competition_id::text || ':' || target_kind || ':'
      || target_server_seq::text || ':'
      || recipient.recipient_profile_id::text || ':'
      || recipient.installation_id::text;

    insert into private.competition_notification_work (
      semantic_id, competition_id, server_seq, kind,
      recipient_profile_id, source_profile_id, installation_id,
      state, available_at, created_at, updated_at, completed_at
    ) values (
      semantic_id, target_competition_id, target_server_seq, target_kind,
      recipient.recipient_profile_id, recipient.source_profile_id,
      recipient.installation_id,
      case when is_muted then 'suppressed' else 'pending' end,
      decision_time, decision_time, decision_time,
      case when is_muted then decision_time else null end
    )
    on conflict on constraint competition_notification_work_identity_unique
    do nothing;
  end loop;

  perform private.request_competition_notification_worker();

  return new;
end;
$$;

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
               or (competition_row.format <> 'duel' and not installation_row.supports_group_matches)
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

create or replace function private.enqueue_challenge_notification(
  target_competition_id uuid,
  target_kind text,
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
  if target_kind not in ('challenge_received', 'challenge_declined', 'match_cancelled') then
    raise exception 'invalid_notification_kind' using errcode = '22023';
  end if;
  -- The change that caused this notification is the competition's latest.
  select max(log_row.server_seq) into target_server_seq
  from public.competition_change_log log_row
  where log_row.competition_id = target_competition_id;
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
      || target_competition_id::text || ':' || target_kind || ':'
      || target_server_seq::text || ':'
      || target_recipient_profile_id::text || ':'
      || installation_row.installation_id::text,
    target_competition_id, target_server_seq, target_kind,
    target_recipient_profile_id, target_source_profile_id,
    installation_row.installation_id,
    case when is_muted then 'suppressed' else 'pending' end,
    decision_time, decision_time, decision_time,
    case when is_muted then decision_time else null end
  from public.device_installations installation_row
  join public.profiles profile_row on profile_row.id = installation_row.profile_id
  where installation_row.profile_id = target_recipient_profile_id
    and installation_row.state = 'active'
    and (installation_row.supports_group_matches or exists (select 1 from public.competitions c where c.id = target_competition_id and c.format = 'duel'))
    and profile_row.state = 'active'
  order by installation_row.installation_id
  on conflict on constraint competition_notification_work_identity_unique
  do nothing;

  perform private.request_competition_notification_worker();
end;
$$;

create or replace function public.register_current_device_installation(
  installation_id uuid,
  apns_token text,
  environment text,
  supports_challenges boolean,
  supports_reactions boolean,
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
  input_supports_group_matches alias for supports_group_matches;
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

  if input_supports_group_matches is null then raise exception 'invalid_installation_request' using errcode = '22023'; end if;
  begin
    insert into public.device_installations as installation_target (
      profile_id, installation_id, apns_token, environment, state,
      supports_challenges, supports_reactions, muted_push_kinds, supports_group_matches
    ) values (
      caller_profile_id, input_installation_id, input_apns_token,
      input_environment, 'active', input_supports_challenges,
      input_supports_reactions, input_muted_push_kinds, input_supports_group_matches
    )
    on conflict on constraint device_installations_profile_installation_unique
    do update
    set apns_token = excluded.apns_token,
        environment = excluded.environment,
        state = 'active',
        supports_challenges = excluded.supports_challenges,
        supports_reactions = excluded.supports_reactions,
        muted_push_kinds = excluded.muted_push_kinds,
        supports_group_matches = excluded.supports_group_matches,
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

create or replace function public.register_current_device_installation(
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
as $$ begin
  return public.register_current_device_installation(installation_id, apns_token, environment,
    supports_challenges, supports_reactions, muted_push_kinds, false);
end; $$;

revoke all on function public.register_current_device_installation(uuid,text,text,boolean,boolean,text[],boolean) from public, anon, authenticated, service_role;
grant execute on function public.register_current_device_installation(uuid,text,text,boolean,boolean,text[],boolean) to authenticated;

-- A third party's pending lineup grants no direct challenge credentials to its co-invitees.
create function private.has_direct_challenge_history(caller uuid, recipient uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.competitions c
    join public.competition_participants a on a.competition_id = c.id and a.profile_id = caller
    join public.competition_participants b on b.competition_id = c.id and b.profile_id = recipient
    where c.format = 'duel' or c.creator_profile_id = caller
      or (a.state = 'accepted' and b.state = 'accepted' and exists (
        select 1 from public.competition_change_log l where l.competition_id = c.id
          and l.change_kind = 'competition_lifecycle_changed' and l.payload_snapshot->>'lifecycle' = 'scheduled')));
$$;
revoke all on function private.has_direct_challenge_history(uuid,uuid) from public,anon,authenticated,service_role;

-- A group result can never be the parent of a legacy duel rematch.
create or replace function private.create_competition_invite_v2(
  token_digest bytea,
  creator_time_zone_identifier text,
  rematch_parent_id uuid,
  creator_auth_user_id uuid,
  creation_idempotency_key uuid,
  token_derivation_version smallint,
  recipient_profile_id uuid,
  challenge_link_code text
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  input_token_digest alias for token_digest;
  input_time_zone_identifier alias for creator_time_zone_identifier;
  input_rematch_parent_id alias for rematch_parent_id;
  input_creator_auth_user_id alias for creator_auth_user_id;
  input_idempotency_key alias for creation_idempotency_key;
  input_derivation_version alias for token_derivation_version;
  input_recipient_profile_id alias for recipient_profile_id;
  input_link_code alias for challenge_link_code;
  caller_profile_id uuid;
  source_scoring_policy text;
  f boolean;
  new_competition_id uuid;
  existing_invite record;
  created_time timestamptz := pg_catalog.statement_timestamp();
  invite_expires_at timestamptz := created_time + private.invitation_expiry_interval_v1();
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  if input_token_digest is null or pg_catalog.octet_length(input_token_digest) <> 32 then
    raise exception 'invalid_token_digest' using errcode = '22023';
  end if;
  if input_idempotency_key is null then
    raise exception 'invalid_idempotency_key' using errcode = '22023';
  end if;
  if input_derivation_version is distinct from 1::smallint then
    raise exception 'invalid_token_derivation_version' using errcode = '22023';
  end if;
  if input_time_zone_identifier is null or not exists (
    select 1 from pg_catalog.pg_timezone_names z where z.name = input_time_zone_identifier
  ) then
    raise exception 'invalid_time_zone' using errcode = '22023';
  end if;

  -- No key update: closed_by_profile_id's foreign key check (key share)
  -- from a concurrent decline or cancel must not wait on these locks.
  -- Serialize creates and accepts between both people before checking
  -- idempotence, pending pairs, overlap and reciprocal challenges.
  select p.id into caller_profile_id from public.profiles p
  where p.auth_user_id = input_creator_auth_user_id and p.state = 'active';
  if caller_profile_id is null then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;
  perform 1 from public.profiles p
  where p.id in (caller_profile_id, input_recipient_profile_id)
  order by p.id for no key update;
  if not exists (select 1 from public.profiles p
    where p.id = caller_profile_id and p.state = 'active') then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  select c.id, c.time_zone_identifier, c.rematch_parent_id,
    c.invite_token_derivation_version, c.invited_profile_id, i.token_digest
  into existing_invite from public.competitions c
  join public.competition_invites i on i.competition_id = c.id
  where c.creator_profile_id = caller_profile_id
    and c.invite_creation_idempotency_key = input_idempotency_key;
  if found then
    if existing_invite.time_zone_identifier is not distinct from input_time_zone_identifier
       and existing_invite.rematch_parent_id is not distinct from input_rematch_parent_id
       and existing_invite.invite_token_derivation_version = input_derivation_version
       and existing_invite.invited_profile_id is not distinct from input_recipient_profile_id
       and existing_invite.token_digest = input_token_digest then
      return existing_invite.id;
    end if;
    raise exception 'idempotency_conflict' using errcode = 'P0001';
  end if;

  if input_recipient_profile_id is null or input_recipient_profile_id = caller_profile_id
     or not exists (select 1 from public.profiles p
       where p.id = input_recipient_profile_id and p.state = 'active') then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  f := private.are_friends(caller_profile_id, input_recipient_profile_id);
  -- A reset link also stops its challengers from switching to the account
  -- id they saw (a rematch is between people who already played).
  if input_rematch_parent_id is null and input_link_code is null
     and not f and private.challenge_link_revoked_v1(caller_profile_id, input_recipient_profile_id) then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  -- Search discovery is not a challenge link; shipped Challenge Again has history.
  if input_rematch_parent_id is null and input_link_code is null and not f
     and exists (select 1 from public.profiles p where p.id = input_recipient_profile_id and p.username is not null)
     and not private.has_direct_challenge_history(caller_profile_id,input_recipient_profile_id) then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  if input_rematch_parent_id is null then
    source_scoring_policy := 'healthcomp.activity-score.v1';
  else
    select c.scoring_policy_identity into source_scoring_policy
    from public.competitions c
    where c.id = input_rematch_parent_id and c.format = 'duel' and c.lifecycle in ('completed', 'archived')
      and exists (select 1 from public.competition_participants p
        where p.competition_id = c.id and p.profile_id = caller_profile_id and p.state = 'accepted')
      and exists (select 1 from public.competition_participants p
        where p.competition_id = c.id and p.profile_id = input_recipient_profile_id and p.state = 'accepted');
    if source_scoring_policy is null then
      raise exception 'rematch_not_allowed' using errcode = '42501';
    end if;
  end if;

  if not f and exists (select 1 from public.profiles p
    where p.id = input_recipient_profile_id and p.challenge_policy = 'friends_only') then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;

  update public.competitions c set lifecycle = 'expired', updated_at = created_time
  where c.creator_profile_id = caller_profile_id and c.lifecycle = 'pending'
    and c.invitation_expires_at <= created_time;
  if exists (select 1 from public.competitions c
    where c.creator_profile_id = caller_profile_id
      and c.invited_profile_id = input_recipient_profile_id and c.lifecycle = 'pending') then
    raise exception 'pending_invitation_exists' using errcode = 'P0001';
  end if;
  if private.match_in_progress_between(caller_profile_id, input_recipient_profile_id)
     is not null then
    raise exception 'active_match_exists' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.competitions c
    where c.creator_profile_id = input_recipient_profile_id
      and c.invited_profile_id = caller_profile_id and c.lifecycle = 'pending'
      and c.invitation_expires_at > created_time) then
    raise exception 'incoming_challenge_exists' using errcode = 'P0001';
  end if;
  -- Someone the recipient blocked reads as unavailable. Pair conflicts
  -- above describe only what both people already see.
  if exists (select 1 from private.account_blocks b
    where b.blocker_profile_id = input_recipient_profile_id
      and b.blocked_profile_id = caller_profile_id) then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;

  insert into public.competitions (
    creator_profile_id, invited_profile_id, time_zone_identifier, scoring_policy_identity,
    lifecycle, invitation_expires_at, rematch_parent_id, invite_creation_idempotency_key,
    invite_token_derivation_version, created_at, updated_at
  ) values (
    caller_profile_id, input_recipient_profile_id, input_time_zone_identifier,
    source_scoring_policy, 'pending', invite_expires_at, input_rematch_parent_id,
    input_idempotency_key, input_derivation_version, created_time, created_time
  ) returning id into new_competition_id;
  insert into public.competition_participants (competition_id, profile_id, role, state)
  values (new_competition_id, caller_profile_id, 'creator', 'accepted'),
    (new_competition_id, input_recipient_profile_id, 'invitee', 'pending');
  insert into public.competition_invites (
    competition_id, token_digest, expires_at, created_at, challenge_link_code
  ) values (
    new_competition_id, input_token_digest, invite_expires_at, created_time, input_link_code
  );
  perform private.enqueue_challenge_notification(
    new_competition_id, 'challenge_received', input_recipient_profile_id, caller_profile_id);
  return new_competition_id;
end;
$$;
create or replace function public.create_competition_invite(
  token_digest bytea,
  creator_time_zone_identifier text,
  rematch_parent_id uuid,
  creator_auth_user_id uuid,
  creation_idempotency_key uuid,
  token_derivation_version smallint
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_token_digest alias for token_digest;
  input_time_zone_identifier alias for creator_time_zone_identifier;
  input_rematch_parent_id alias for rematch_parent_id;
  input_creator_auth_user_id alias for creator_auth_user_id;
  input_idempotency_key alias for creation_idempotency_key;
  input_derivation_version alias for token_derivation_version;
  caller_profile_id uuid;
  source_scoring_policy text;
  new_competition_id uuid;
  existing_invite record;
  invite_expires_at timestamptz :=
    pg_catalog.statement_timestamp() + private.invitation_expiry_interval_v1();
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;

  if input_token_digest is null
     or pg_catalog.octet_length(input_token_digest) <> 32 then
    raise exception 'invalid_token_digest' using errcode = '22023';
  end if;

  if input_idempotency_key is null then
    raise exception 'invalid_idempotency_key' using errcode = '22023';
  end if;

  if input_derivation_version is distinct from 1::smallint then
    raise exception 'invalid_token_derivation_version' using errcode = '22023';
  end if;

  if input_time_zone_identifier is null
     or not exists (
       select 1
       from pg_catalog.pg_timezone_names time_zone_row
       where time_zone_row.name = input_time_zone_identifier
     ) then
    raise exception 'invalid_time_zone' using errcode = '22023';
  end if;

  select profile_row.id
  into caller_profile_id
  from public.profiles profile_row
  where profile_row.auth_user_id = input_creator_auth_user_id
    and profile_row.state = 'active';

  if caller_profile_id is null then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  select competition_row.id,
         competition_row.time_zone_identifier,
         competition_row.rematch_parent_id,
         competition_row.invite_token_derivation_version,
         invite_row.token_digest
  into existing_invite
  from public.competitions competition_row
  join public.competition_invites invite_row
    on invite_row.competition_id = competition_row.id
  where competition_row.creator_profile_id = caller_profile_id
    and competition_row.invite_creation_idempotency_key = input_idempotency_key
  for update of competition_row, invite_row;

  if found then
    if existing_invite.time_zone_identifier is not distinct from input_time_zone_identifier
       and existing_invite.rematch_parent_id is not distinct from input_rematch_parent_id
       and existing_invite.invite_token_derivation_version = input_derivation_version
       and existing_invite.token_digest = input_token_digest then
      return existing_invite.id;
    end if;

    raise exception 'idempotency_conflict' using errcode = 'P0001';
  end if;

  if input_rematch_parent_id is null then
    source_scoring_policy := 'healthcomp.activity-score.v1';
  else
    select source_competition.scoring_policy_identity
    into source_scoring_policy
    from public.competitions source_competition
    where source_competition.id = input_rematch_parent_id
      and source_competition.format = 'duel'
      and source_competition.lifecycle in ('completed', 'archived')
      and exists (
        select 1
        from public.competition_participants source_membership
        where source_membership.competition_id = source_competition.id
          and source_membership.profile_id = caller_profile_id
          and source_membership.state = 'accepted'
      );

    if source_scoring_policy is null then
      raise exception 'rematch_not_allowed' using errcode = '42501';
    end if;
  end if;

  insert into public.competitions (
    creator_profile_id,
    time_zone_identifier,
    start_day,
    scoring_policy_identity,
    lifecycle,
    invitation_expires_at,
    best_available_deadline,
    rematch_parent_id,
    invite_creation_idempotency_key,
    invite_token_derivation_version
  ) values (
    caller_profile_id,
    input_time_zone_identifier,
    null,
    source_scoring_policy,
    'pending',
    invite_expires_at,
    null,
    input_rematch_parent_id,
    input_idempotency_key,
    input_derivation_version
  )
  on conflict (creator_profile_id, invite_creation_idempotency_key) do nothing
  returning id into new_competition_id;

  if new_competition_id is null then
    select competition_row.id,
           competition_row.time_zone_identifier,
           competition_row.rematch_parent_id,
           competition_row.invite_token_derivation_version,
           invite_row.token_digest
    into existing_invite
    from public.competitions competition_row
    join public.competition_invites invite_row
      on invite_row.competition_id = competition_row.id
    where competition_row.creator_profile_id = caller_profile_id
      and competition_row.invite_creation_idempotency_key = input_idempotency_key
    for update of competition_row, invite_row;

    if found
       and existing_invite.time_zone_identifier is not distinct from input_time_zone_identifier
       and existing_invite.rematch_parent_id is not distinct from input_rematch_parent_id
       and existing_invite.invite_token_derivation_version = input_derivation_version
       and existing_invite.token_digest = input_token_digest then
      return existing_invite.id;
    end if;

    raise exception 'idempotency_conflict' using errcode = 'P0001';
  end if;

  insert into public.competition_participants (
    competition_id, profile_id, role, state
  ) values (
    new_competition_id, caller_profile_id, 'creator', 'accepted'
  );

  insert into public.competition_invites (
    competition_id, token_digest, expires_at
  ) values (
    new_competition_id, input_token_digest, invite_expires_at
  );

  return new_competition_id;
end;
$$;
