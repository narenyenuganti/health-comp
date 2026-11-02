-- Reactions: each participant can leave one of four presets on the other
-- person's day (while the match is live or tallying) and on the result.
-- Reactions are not change-log rows: every installed app's change feed
-- rejects kinds it doesn't know (competition_change_payload), and the log is
-- append-only. They live in their own private table, read and written only
-- through two security-definer RPCs, and wake both participants' apps with
-- the existing competition_changed broadcast. The push is generic ("New
-- reaction") and reaches only installations registered with
-- supports_reactions, at most once an hour per match and recipient.

create table private.competition_reactions (
  competition_id uuid not null references public.competitions(id),
  author_profile_id uuid not null references public.profiles(id),
  day_ordinal smallint check (day_ordinal between 1 and 7), -- null: the result
  reaction text not null
    check (reaction in ('clap', 'fire', 'huffing', 'salute')),
  created_at timestamptz not null default pg_catalog.statement_timestamp(),
  updated_at timestamptz not null default pg_catalog.statement_timestamp(),
  constraint competition_reactions_one_per_target
    unique nulls not distinct (competition_id, author_profile_id, day_ordinal),
  constraint competition_reactions_membership_fk
    foreign key (competition_id, author_profile_id)
    references public.competition_participants(competition_id, profile_id)
);
alter table private.competition_reactions enable row level security;
alter table private.competition_reactions force row level security;
revoke all on table private.competition_reactions
  from public, anon, authenticated, service_role;

-- A capability flag: older builds can't show reactions, so their
-- installations (registered through the 3- and 4-argument calls) stay false
-- and never get a reaction push.
alter table public.device_installations
  add column supports_reactions boolean not null default false;

alter table private.competition_notification_work
  drop constraint competition_notification_work_kind_check,
  add constraint competition_notification_work_kind_check check (
    kind in ('score_update', 'result', 'challenge_received',
      'challenge_declined', 'match_cancelled', 'nudge', 'reaction')
  );

-- 2300's four-argument registration plus supports_reactions.
create function public.register_current_device_installation(
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
declare
  input_installation_id alias for installation_id;
  input_apns_token alias for apns_token;
  input_environment alias for environment;
  input_supports_challenges alias for supports_challenges;
  input_supports_reactions alias for supports_reactions;
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
     or input_supports_reactions is null then
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
      supports_challenges, supports_reactions
    ) values (
      caller_profile_id, input_installation_id, input_apns_token,
      input_environment, 'active', input_supports_challenges,
      input_supports_reactions
    )
    on conflict on constraint device_installations_profile_installation_unique
    do update
    set apns_token = excluded.apns_token,
        environment = excluded.environment,
        state = 'active',
        supports_challenges = excluded.supports_challenges,
        supports_reactions = excluded.supports_reactions,
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

-- The current build's call: same signature, same response, no reaction
-- pushes. The three-argument call already delegates here, so 1.0.2 gets
-- false/false.
create or replace function public.register_current_device_installation(
  installation_id uuid,
  apns_token text,
  environment text,
  supports_challenges boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  return public.register_current_device_installation(
    installation_id, apns_token, environment, supports_challenges, false
  );
end;
$$;

revoke all on function public.register_current_device_installation(
  uuid, text, text, boolean, boolean
) from public, anon, authenticated, service_role;
grant execute on function public.register_current_device_installation(
  uuid, text, text, boolean, boolean
) to authenticated;

-- 1900's enqueue_challenge_notification, for one reaction push.
create function private.enqueue_reaction_notification(
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
    and profile_row.state = 'active'
  order by installation_row.installation_id
  on conflict on constraint competition_notification_work_identity_unique
  do nothing;

  perform private.request_competition_notification_worker();
end;
$$;
revoke all on function private.enqueue_reaction_notification(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;

-- day_ordinal is integer, not smallint: functions resolve through implicit
-- casts only, and int4 -> int2 is assignment-only, so a plain literal
-- wouldn't resolve against a smallint parameter. A null day is the result; a
-- null reaction removes the caller's reaction on that target.
create function public.set_competition_reaction(
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
  from public.competitions c
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

-- Every reaction in the caller's accepted matches, both people's, newest
-- first. Rows stay after the other person deletes their account.
create function public.list_competition_reactions()
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
    from private.competition_reactions r
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

revoke all on function public.set_competition_reaction(uuid, integer, text)
  from public, anon, authenticated, service_role;
grant execute on function public.set_competition_reaction(uuid, integer, text)
  to authenticated;
revoke all on function public.list_competition_reactions()
  from public, anon, authenticated, service_role;
grant execute on function public.list_competition_reactions()
  to authenticated;
