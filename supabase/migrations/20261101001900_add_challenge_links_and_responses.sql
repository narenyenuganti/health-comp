-- Challenge links, in-app challenge responses, Cancel Match and overlap rules.
-- All DDL first; the one data fix runs at the end.

alter table public.competitions
  add column closed_by_profile_id uuid references public.profiles(id),
  add column closed_at timestamptz,
  add constraint competition_closed_shape check (
    (closed_by_profile_id is null and closed_at is null)
    or (closed_by_profile_id is not null and closed_at is not null
      and lifecycle in ('declined', 'cancelled'))
  );

alter table private.competition_notification_work
  drop constraint competition_notification_work_kind_check,
  add constraint competition_notification_work_kind_check check (
    kind in ('score_update', 'result', 'challenge_received',
      'challenge_declined', 'match_cancelled')
  );

-- A person's reusable challenge link. It grants only "may create a pending
-- challenge to me" and stays outside the API schema and public.profiles.
create table private.challenge_links (
  profile_id uuid primary key references public.profiles(id),
  code text not null unique check (code ~ '^[A-Za-z0-9_-]{22}$'),
  created_at timestamptz not null default now()
);
alter table private.challenge_links enable row level security;
alter table private.challenge_links force row level security;
revoke all on table private.challenge_links
  from public, anon, authenticated, service_role;

-- 128 random bits, base64url without padding: 22 characters, not enumerable.
create function private.new_challenge_link_code_v1()
returns text language sql volatile set search_path = ''
as $$
  select pg_catalog.translate(pg_catalog.rtrim(pg_catalog.encode(
    extensions.gen_random_bytes(16), 'base64'), '='), '+/', '-_');
$$;
revoke all on function private.new_challenge_link_code_v1()
  from public, anon, authenticated, service_role;

-- A match blocks new challenges between the pair until its week has ended
-- (sender-zone local date past Day 7). Lifecycle stays scheduled until
-- finalization, so the date decides.
create function private.match_in_progress_between(
  first_profile_id uuid,
  second_profile_id uuid
)
returns uuid language sql stable security definer set search_path = ''
as $$
  select c.id from public.competitions c
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
revoke all on function private.match_in_progress_between(uuid, uuid)
  from public, anon, authenticated, service_role;

create function private.enqueue_challenge_notification(
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
    and profile_row.state = 'active'
  order by installation_row.installation_id
  on conflict on constraint competition_notification_work_identity_unique
  do nothing;

  perform private.request_competition_notification_worker();
end;
$$;
revoke all on function private.enqueue_challenge_notification(uuid, text, uuid, uuid)
  from public, anon, authenticated, service_role;

-- Claim's acceptance (018), keyed by competition so the bound recipient can
-- accept in the app without the token. Both people's profile rows are locked
-- in id order first (no key update, so foreign key checks from a decline or
-- cancel never wait on them), the same order create uses, so overlapping
-- creates and accepts between one pair serialize without deadlocks.
create function private.accept_pending_invitation(
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
  from public.competitions c where c.id = target_competition_id;
  if not found then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  perform 1 from public.profiles p
  where p.id in (target_creator_profile_id, caller_profile_id)
  order by p.id for no key update;

  select i.id, i.competition_id, i.claimed_profile_id, i.consumed_at, i.expires_at,
    c.creator_profile_id, c.invited_profile_id, c.time_zone_identifier, c.lifecycle
  into target_invite from public.competitions c
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
revoke all on function private.accept_pending_invitation(uuid, uuid)
  from public, anon, authenticated, service_role;

-- Same signature, response and errors as 018; overlap adds active_match_exists.
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
  from public.competition_invites i where i.token_digest = input_token_digest;
  if not found then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  return private.accept_pending_invitation(target_competition_id, caller_profile_id);
end;
$$;

-- Shared caller check for the new authenticated RPCs (archive_competition's).
create function private.require_active_caller_profile_id()
returns uuid language plpgsql stable security definer set search_path = ''
as $$
declare
  caller_profile_id uuid;
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  select profile_row.id into caller_profile_id
  from public.profiles profile_row
  where profile_row.auth_user_id = (select auth.uid())
    and profile_row.state = 'active';
  if caller_profile_id is null then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;
  return caller_profile_id;
end;
$$;
revoke all on function private.require_active_caller_profile_id()
  from public, anon, authenticated, service_role;

-- The bound recipient's signed-in account is the identity check; no token.
create function public.accept_competition_challenge(competition_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  caller_profile_id uuid := private.require_active_caller_profile_id();
begin
  if input_competition_id is null then
    raise exception 'invalid_competition_id' using errcode = '22023';
  end if;
  return pg_catalog.jsonb_build_object('competition_id',
    private.accept_pending_invitation(input_competition_id, caller_profile_id));
end;
$$;

create function public.decline_competition_challenge(competition_id uuid)
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
  into target from public.competitions c where c.id = input_competition_id for update;
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

-- A cancelled match has no schedule. Every app version's descriptor check
-- requires start_day and best_available_deadline to be null once cancelled
-- and drops the whole listing otherwise, so this covers Cancel Match and the
-- account-deletion cancel alike.
create function private.clear_cancelled_schedule()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if new.lifecycle = 'cancelled' then
    new.start_day := null;
    new.best_available_deadline := null;
  end if;
  return new;
end;
$$;
revoke all on function private.clear_cancelled_schedule()
  from public, anon, authenticated, service_role;
create trigger clear_cancelled_schedule
before update of lifecycle on public.competitions
for each row when (new.lifecycle = 'cancelled')
execute function private.clear_cancelled_schedule();

-- The one cancel RPC: the creator withdraws a pending challenge (no push), or
-- either participant cancels a scheduled match before local midnight at the
-- start of Day 1 in the match's time zone (the other person is told).
create function public.cancel_competition(competition_id uuid)
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
  into target from public.competitions c where c.id = input_competition_id for update;
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

-- 018's body plus 'cancelled' in the accepted-counterpart lifecycles. Without
-- it a cancelled match embeds a null counterpart profile, which installed
-- apps' strict descriptor validator rejects for the whole listing.
create or replace function private.can_view_profile(target_profile_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select current_profile.id is not null and (
    target_profile_id = current_profile.id or exists (
      select 1 from public.competition_participants own_membership
      join public.competition_participants counterpart_membership
        on counterpart_membership.competition_id = own_membership.competition_id
      join public.competitions c on c.id = own_membership.competition_id
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

-- Recipient-only preview. Every unavailable case, including a live link opened
-- by another account, is the same invite_unavailable error that claim raises.
create function public.preview_competition_invite(token_digest bytea)
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
  join public.competitions c on c.id = i.competition_id
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

-- Incoming challenges addressed to the caller, and the last day's declines
-- and cancels that the other person did. Names only; no scores or history.
create function public.list_challenges()
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
    from public.competitions c
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
    from public.competitions c
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

create function public.get_my_challenge_link()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  caller_profile_id uuid := private.require_active_caller_profile_id();
  link_code text;
begin
  insert into private.challenge_links (profile_id, code)
  values (caller_profile_id, private.new_challenge_link_code_v1())
  on conflict (profile_id) do nothing;
  select l.code into link_code from private.challenge_links l
  where l.profile_id = caller_profile_id;
  return pg_catalog.jsonb_build_object('code', link_code);
end;
$$;

-- Exact code to one account, the same shape as resolve_invitation_recipient.
create function public.resolve_challenge_link(code text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  input_code alias for code;
  caller_profile_id uuid := private.require_active_caller_profile_id();
  target record;
begin
  if input_code is null or input_code !~ '^[A-Za-z0-9_-]{22}$' then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  select p.id, p.display_name, p.state into target
  from private.challenge_links l
  join public.profiles p on p.id = l.profile_id
  where l.code = input_code;
  if found and target.id = caller_profile_id then
    raise exception 'own_challenge_link' using errcode = 'P0001';
  end if;
  if not found or target.state <> 'active' then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  return pg_catalog.jsonb_build_object('id', target.id, 'display_name', target.display_name);
end;
$$;

-- 018's create with three deltas: both profiles are locked in id order (so
-- reciprocal creates serialize), overlap and reciprocal checks, and the
-- recipient's challenge_received push. The idempotent retry returns before
-- the inserts and never enqueues a second push.
create or replace function public.create_competition_invite(
  token_digest bytea,
  creator_time_zone_identifier text,
  rematch_parent_id uuid,
  creator_auth_user_id uuid,
  creation_idempotency_key uuid,
  token_derivation_version smallint,
  recipient_profile_id uuid
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
  caller_profile_id uuid;
  source_scoring_policy text;
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
  if input_rematch_parent_id is null then
    source_scoring_policy := 'healthcomp.activity-score.v1';
  else
    select c.scoring_policy_identity into source_scoring_policy
    from public.competitions c
    where c.id = input_rematch_parent_id and c.lifecycle in ('completed', 'archived')
      and exists (select 1 from public.competition_participants p
        where p.competition_id = c.id and p.profile_id = caller_profile_id and p.state = 'accepted')
      and exists (select 1 from public.competition_participants p
        where p.competition_id = c.id and p.profile_id = input_recipient_profile_id and p.state = 'accepted');
    if source_scoring_policy is null then
      raise exception 'rematch_not_allowed' using errcode = '42501';
    end if;
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
  insert into public.competition_invites (competition_id, token_digest, expires_at, created_at)
  values (new_competition_id, input_token_digest, invite_expires_at, created_time);
  perform private.enqueue_challenge_notification(
    new_competition_id, 'challenge_received', input_recipient_profile_id, caller_profile_id);
  return new_competition_id;
end;
$$;

-- 0700's lease plus two discard rules: a challenge push whose source profile
-- is no longer active, and challenge_received once the challenge stopped
-- being pending or expired. Leased items keep the same seven keys.
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
                   and source_profile_row.state is distinct from 'active')
               or (work_row.kind = 'challenge_received'
                   and (competition_row.lifecycle is distinct from 'pending'
                     or competition_row.invitation_expires_at <= as_of))
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

-- 0600's wakeup, now also reaching the pending invitee so an incoming
-- challenge appears live. The payload stays the cursor hint only.
create or replace function private.broadcast_competition_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  recipient record;
begin
  for recipient in
    select distinct participant_row.profile_id
    from public.competition_participants participant_row
    join public.profiles profile_row
      on profile_row.id = participant_row.profile_id
    where participant_row.competition_id = new.competition_id
      and (participant_row.state = 'accepted'
        or (participant_row.role = 'invitee' and participant_row.state = 'pending'))
      and profile_row.state = 'active'
    order by participant_row.profile_id
  loop
    perform realtime.send(
      pg_catalog.jsonb_build_object(
        'server_cursor_hint', new.server_seq::text
      ),
      'competition_changed',
      'profile:' || recipient.profile_id::text,
      true
    );
  end loop;

  return new;
end;
$$;

revoke all on function public.accept_competition_challenge(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.decline_competition_challenge(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.cancel_competition(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.preview_competition_invite(bytea)
  from public, anon, authenticated, service_role;
revoke all on function public.list_challenges()
  from public, anon, authenticated, service_role;
revoke all on function public.get_my_challenge_link()
  from public, anon, authenticated, service_role;
revoke all on function public.resolve_challenge_link(text)
  from public, anon, authenticated, service_role;
grant execute on function public.accept_competition_challenge(uuid) to authenticated;
grant execute on function public.decline_competition_challenge(uuid) to authenticated;
grant execute on function public.cancel_competition(uuid) to authenticated;
grant execute on function public.preview_competition_invite(bytea) to authenticated;
grant execute on function public.list_challenges() to authenticated;
grant execute on function public.get_my_challenge_link() to authenticated;
grant execute on function public.resolve_challenge_link(text) to authenticated;

-- Data, after all DDL: account-deletion cancels left their schedule behind,
-- which made the remaining person's listing fail to decode.
update public.competitions
set start_day = null, best_available_deadline = null
where lifecycle = 'cancelled'
  and (start_day is not null or best_available_deadline is not null);
