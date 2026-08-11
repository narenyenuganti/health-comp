create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public;

create or replace function private.tlv_v1(
  field_tag integer,
  field_payload bytea
)
returns bytea
language plpgsql
immutable
set search_path = ''
as $$
begin
  if field_tag < 1 or field_tag > 255 then
    raise exception 'wire field tag must be between 1 and 255' using errcode = '22003';
  end if;

  if field_payload is null then
    return pg_catalog.set_byte(pg_catalog.decode('00', 'hex'), 0, field_tag)
      || pg_catalog.decode('ffffffff', 'hex');
  end if;

  return pg_catalog.set_byte(pg_catalog.decode('00', 'hex'), 0, field_tag)
    || pg_catalog.int4send(pg_catalog.octet_length(field_payload))
    || field_payload;
end;
$$;

comment on function private.tlv_v1(integer, bytea) is
  'Wire v1 field: tag u8, payload length u32 big-endian, payload. Null uses length 0xffffffff and no payload.';

create or replace function private.wire_score_content_v1(
  competition_id uuid,
  participant_profile_id uuid,
  day_ordinal smallint,
  move_mode text,
  stand_mode text,
  move_basis_points integer,
  exercise_basis_points integer,
  stand_basis_points integer,
  accepted_centi_points integer,
  availability_reason text,
  scoring_policy_identity text,
  client_revision bigint
)
returns bytea
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.convert_to('healthcomp-wire-score-v1', 'UTF8')
    || pg_catalog.decode('00', 'hex')
    || private.tlv_v1(1, pg_catalog.uuid_send(competition_id))
    || private.tlv_v1(2, pg_catalog.uuid_send(participant_profile_id))
    || private.tlv_v1(3, pg_catalog.int4send(day_ordinal::integer))
    || private.tlv_v1(4, pg_catalog.convert_to(move_mode, 'UTF8'))
    || private.tlv_v1(5, pg_catalog.convert_to(stand_mode, 'UTF8'))
    || private.tlv_v1(6, pg_catalog.int4send(move_basis_points))
    || private.tlv_v1(7, pg_catalog.int4send(exercise_basis_points))
    || private.tlv_v1(8, pg_catalog.int4send(stand_basis_points))
    || private.tlv_v1(9, pg_catalog.int4send(accepted_centi_points))
    || private.tlv_v1(10, pg_catalog.convert_to(availability_reason, 'UTF8'))
    || private.tlv_v1(11, pg_catalog.convert_to(scoring_policy_identity, 'UTF8'))
    || private.tlv_v1(12, pg_catalog.int8send(client_revision));
$$;

comment on function private.wire_score_content_v1(
  uuid, uuid, smallint, text, text, integer, integer, integer, integer, text, text, bigint
) is
  'Canonical Activity score wire bytes v1. UUIDs use RFC-4122 bytes; integers use signed two-complement big-endian; text is exact UTF-8.';

create or replace function private.wire_score_digest_v1(
  competition_id uuid,
  participant_profile_id uuid,
  day_ordinal smallint,
  move_mode text,
  stand_mode text,
  move_basis_points integer,
  exercise_basis_points integer,
  stand_basis_points integer,
  accepted_centi_points integer,
  availability_reason text,
  scoring_policy_identity text,
  client_revision bigint
)
returns bytea
language sql
immutable
set search_path = ''
as $$
  select extensions.digest(
    private.wire_score_content_v1(
      competition_id,
      participant_profile_id,
      day_ordinal,
      move_mode,
      stand_mode,
      move_basis_points,
      exercise_basis_points,
      stand_basis_points,
      accepted_centi_points,
      availability_reason,
      scoring_policy_identity,
      client_revision
    ),
    'sha256'
  );
$$;

create table public.profiles (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  display_name text not null,
  state text not null check (state in ('active', 'deleting', 'anonymized')),
  anonymized_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_identity_state_check check (
    (
      state in ('active', 'deleting')
      and auth_user_id is not null
      and anonymized_at is null
      and pg_catalog.btrim(display_name) <> ''
      and display_name <> 'Former competitor'
    )
    or (
      state = 'anonymized'
      and auth_user_id is null
      and display_name = 'Former competitor'
      and anonymized_at is not null
    )
  )
);

create table public.competitions (
  id uuid primary key default gen_random_uuid(),
  creator_profile_id uuid not null references public.profiles(id),
  time_zone_identifier text,
  start_day date,
  scoring_policy_identity text not null,
  lifecycle text not null check (
    lifecycle in (
      'pending', 'scheduled', 'active', 'ends_today', 'tallying',
      'completed', 'archived', 'declined', 'expired', 'cancelled'
    )
  ),
  invitation_expires_at timestamptz not null,
  best_available_deadline timestamptz,
  rematch_parent_id uuid references public.competitions(id),
  next_server_seq bigint not null default 1 check (next_server_seq > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint competitions_schedule_shape_check check (
    (
      lifecycle in ('pending', 'declined', 'expired', 'cancelled')
      and (start_day is null or time_zone_identifier is not null)
    )
    or (
      lifecycle in ('scheduled', 'active', 'ends_today', 'tallying', 'completed', 'archived')
      and start_day is not null
      and pg_catalog.btrim(time_zone_identifier) <> ''
      and best_available_deadline is not null
    )
  ),
  constraint competitions_deadline_order_check check (
    best_available_deadline is null or best_available_deadline > invitation_expires_at
  ),
  constraint competitions_rematch_identity_check check (rematch_parent_id is null or rematch_parent_id <> id)
);

create table public.competition_participants (
  competition_id uuid not null references public.competitions(id),
  profile_id uuid not null references public.profiles(id),
  role text not null check (role in ('creator', 'invitee')),
  state text not null check (state in ('pending', 'accepted', 'declined', 'anonymized')),
  joined_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (competition_id, profile_id),
  constraint competition_participants_one_role unique (competition_id, role)
    deferrable initially deferred
);

create table public.competition_invites (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references public.competitions(id),
  token_digest bytea not null unique check (pg_catalog.octet_length(token_digest) = 32),
  claimed_profile_id uuid references public.profiles(id),
  consumed_at timestamptz,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint competition_invites_claim_shape_check check (
    (claimed_profile_id is null and consumed_at is null)
    or (claimed_profile_id is not null and consumed_at is not null)
  ),
  constraint competition_invites_expiry_check check (expires_at > created_at)
);

create table public.competition_change_log (
  competition_id uuid not null references public.competitions(id),
  server_seq bigint not null check (server_seq > 0),
  change_kind text not null check (change_kind ~ '^[a-z][a-z0-9_]{0,63}$'),
  entity_id uuid not null,
  occurred_at timestamptz not null default now(),
  primary key (competition_id, server_seq)
);

create or replace function private.allocate_competition_server_seq(
  target_competition_id uuid,
  target_change_kind text,
  target_entity_id uuid,
  target_occurred_at timestamptz default now()
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  allocated_seq bigint;
begin
  if target_change_kind is null or target_change_kind !~ '^[a-z][a-z0-9_]{0,63}$' then
    raise exception 'invalid competition change kind' using errcode = '22023';
  end if;

  update public.competitions
  set next_server_seq = next_server_seq + 1,
      updated_at = greatest(updated_at, target_occurred_at)
  where id = target_competition_id
  returning next_server_seq - 1 into allocated_seq;

  if allocated_seq is null then
    raise exception 'competition does not exist' using errcode = 'P0002';
  end if;

  insert into public.competition_change_log (
    competition_id,
    server_seq,
    change_kind,
    entity_id,
    occurred_at
  ) values (
    target_competition_id,
    allocated_seq,
    target_change_kind,
    target_entity_id,
    target_occurred_at
  );

  return allocated_seq;
end;
$$;

revoke all on function private.allocate_competition_server_seq(uuid, text, uuid, timestamptz) from public;

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

revoke all on function private.enforce_competition_participant_shape() from public;

create or replace function private.reject_competition_participant_identity_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'competition participant history is append-only' using errcode = '55000';
  end if;

  if new.competition_id is distinct from old.competition_id
     or new.profile_id is distinct from old.profile_id
     or new.role is distinct from old.role then
    raise exception 'competition participant identity is immutable' using errcode = '55000';
  end if;

  return new;
end;
$$;

create trigger reject_competition_participant_identity_mutation
before update or delete on public.competition_participants
for each row execute function private.reject_competition_participant_identity_mutation();

create constraint trigger enforce_competition_participant_shape_from_participant
after insert or update on public.competition_participants
deferrable initially deferred
for each row execute function private.enforce_competition_participant_shape();

create constraint trigger enforce_competition_participant_shape_from_competition
after insert or update of lifecycle, creator_profile_id on public.competitions
deferrable initially deferred
for each row execute function private.enforce_competition_participant_shape();

create or replace function private.record_participant_state_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or old.state is distinct from new.state then
    perform private.allocate_competition_server_seq(
      new.competition_id,
      case when tg_op = 'INSERT' then 'participant_added' else 'participant_state_changed' end,
      new.profile_id,
      new.updated_at
    );
  end if;
  return new;
end;
$$;

create trigger record_participant_state_change
after insert or update of state on public.competition_participants
for each row execute function private.record_participant_state_change();

create or replace function private.record_competition_lifecycle_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.lifecycle is distinct from new.lifecycle then
    perform private.allocate_competition_server_seq(
      new.id,
      'competition_lifecycle_changed',
      new.id,
      new.updated_at
    );
  end if;
  return new;
end;
$$;

create trigger record_competition_lifecycle_change
after update of lifecycle on public.competitions
for each row execute function private.record_competition_lifecycle_change();

create or replace function private.record_profile_anonymization()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  membership record;
begin
  if old.state is distinct from new.state and new.state = 'anonymized' then
    for membership in
      select participant.competition_id
      from public.competition_participants participant
      where participant.profile_id = new.id
    loop
      perform private.allocate_competition_server_seq(
        membership.competition_id,
        'profile_anonymized',
        new.id,
        new.anonymized_at
      );
    end loop;
  end if;
  return new;
end;
$$;

create trigger record_profile_anonymization
after update of state on public.profiles
for each row execute function private.record_profile_anonymization();

create or replace function private.enforce_anonymized_profile_terminal()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.state = 'anonymized'
     and (
       new.state is distinct from old.state
       or new.auth_user_id is distinct from old.auth_user_id
       or new.display_name is distinct from old.display_name
       or new.anonymized_at is distinct from old.anonymized_at
     ) then
    raise exception 'anonymized profile state is terminal' using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger enforce_anonymized_profile_terminal
before update on public.profiles
for each row execute function private.enforce_anonymized_profile_terminal();

create table public.daily_score_revisions (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references public.competitions(id),
  participant_profile_id uuid not null references public.profiles(id),
  day_ordinal smallint not null check (day_ordinal between 1 and 7),
  semantic_event_id text not null check (pg_catalog.btrim(semantic_event_id) <> ''),
  client_revision bigint not null check (client_revision > 0),
  move_mode text not null check (move_mode in ('activeEnergyKilocalories', 'moveMinutes')),
  stand_mode text not null check (stand_mode in ('standHours', 'rollHours', 'unknown')),
  move_basis_points integer,
  exercise_basis_points integer,
  stand_basis_points integer,
  accepted_centi_points integer,
  availability_reason text not null check (
    availability_reason in (
      'available', 'missing', 'sourceDataUnavailable', 'unsupportedActivityConfiguration',
      'invalidSourceData', 'missingMoveValue', 'missingMoveGoal',
      'nonPositiveMoveGoal', 'missingExerciseValue', 'missingExerciseGoal',
      'nonPositiveExerciseGoal', 'missingStandOrRollValue', 'missingStandOrRollGoal',
      'nonPositiveStandOrRollGoal', 'summaryPaused', 'summaryPauseStateUnknown',
      'invalidNumericCalculation'
    )
  ),
  scoring_policy_identity text not null check (pg_catalog.btrim(scoring_policy_identity) <> ''),
  wire_digest_version smallint not null default 1 check (wire_digest_version = 1),
  wire_content_sha256 bytea not null check (pg_catalog.octet_length(wire_content_sha256) = 32),
  server_seq bigint not null check (server_seq > 0),
  evaluated_at timestamptz not null,
  received_at timestamptz not null default now(),
  constraint daily_score_revision_membership_fk
    foreign key (competition_id, participant_profile_id)
    references public.competition_participants(competition_id, profile_id),
  constraint daily_score_revision_change_fk
    foreign key (competition_id, server_seq)
    references public.competition_change_log(competition_id, server_seq),
  constraint daily_score_revision_semantic_unique
    unique (competition_id, participant_profile_id, semantic_event_id),
  constraint daily_score_revision_number_unique
    unique (competition_id, participant_profile_id, day_ordinal, client_revision),
  constraint daily_score_revision_server_seq_unique unique (competition_id, server_seq),
  constraint daily_score_revision_wire_digest_check check (
    wire_content_sha256 = private.wire_score_digest_v1(
      competition_id,
      participant_profile_id,
      day_ordinal,
      move_mode,
      stand_mode,
      move_basis_points,
      exercise_basis_points,
      stand_basis_points,
      accepted_centi_points,
      availability_reason,
      scoring_policy_identity,
      client_revision
    )
  ),
  constraint daily_score_revision_availability_shape_check check (
    (
      availability_reason = 'available'
      and move_basis_points between 0 and 20000
      and exercise_basis_points between 0 and 20000
      and stand_basis_points between 0 and 20000
      and accepted_centi_points between 0 and 60000
      and accepted_centi_points = least(
        move_basis_points + exercise_basis_points + stand_basis_points,
        60000
      )
    )
    or (
      availability_reason <> 'available'
      and move_basis_points is null
      and exercise_basis_points is null
      and stand_basis_points is null
      and accepted_centi_points is null
    )
  )
);

create table public.participant_finalization_attestations (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references public.competitions(id),
  participant_profile_id uuid not null references public.profiles(id),
  basis text not null check (basis in ('stable', 'best_available')),
  window_commitment_sha256 bytea not null check (pg_catalog.octet_length(window_commitment_sha256) = 32),
  accepted_revisions bigint[] not null check (
    pg_catalog.array_ndims(accepted_revisions) = 1
    and pg_catalog.array_length(accepted_revisions, 1) = 7
    and pg_catalog.array_position(accepted_revisions, null) is null
    and 0 < all(accepted_revisions)
  ),
  server_seq bigint not null check (server_seq > 0),
  attested_at timestamptz not null,
  constraint participant_attestation_membership_fk
    foreign key (competition_id, participant_profile_id)
    references public.competition_participants(competition_id, profile_id),
  constraint participant_attestation_change_fk
    foreign key (competition_id, server_seq)
    references public.competition_change_log(competition_id, server_seq),
  constraint participant_attestation_unique unique (competition_id, participant_profile_id),
  constraint participant_attestation_server_seq_unique unique (competition_id, server_seq)
);

create or replace function private.is_valid_frozen_window_v1(
  frozen_window jsonb,
  participant_a_profile_id uuid,
  participant_b_profile_id uuid,
  participant_a_total_centi_points integer,
  participant_b_total_centi_points integer
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  participant_entry jsonb;
  day_entry jsonb;
  entry_profile_id uuid;
  seen_profile_ids uuid[] := array[]::uuid[];
  seen_ordinals integer[];
  computed_total integer;
  ordinal_value integer;
  point_value integer;
  object_keys text[];
begin
  if pg_catalog.jsonb_typeof(frozen_window) <> 'object' then
    return false;
  end if;

  select pg_catalog.array_agg(key order by key)
  into object_keys
  from pg_catalog.jsonb_object_keys(frozen_window) as keys(key);

  if object_keys <> array['participants', 'version']::text[]
     or pg_catalog.jsonb_typeof(frozen_window->'version') <> 'number'
     or frozen_window->>'version' <> '1'
     or pg_catalog.jsonb_typeof(frozen_window->'participants') <> 'array'
     or pg_catalog.jsonb_array_length(frozen_window->'participants') <> 2 then
    return false;
  end if;

  for participant_entry in
    select value from pg_catalog.jsonb_array_elements(frozen_window->'participants') as entries(value)
  loop
    if pg_catalog.jsonb_typeof(participant_entry) <> 'object' then
      return false;
    end if;

    select pg_catalog.array_agg(key order by key)
    into object_keys
    from pg_catalog.jsonb_object_keys(participant_entry) as keys(key);

    if object_keys <> array['days', 'profile_id']::text[]
       or pg_catalog.jsonb_typeof(participant_entry->'profile_id') <> 'string'
       or pg_catalog.jsonb_typeof(participant_entry->'days') <> 'array'
       or pg_catalog.jsonb_array_length(participant_entry->'days') <> 7 then
      return false;
    end if;

    entry_profile_id := (participant_entry->>'profile_id')::uuid;
    if entry_profile_id not in (participant_a_profile_id, participant_b_profile_id)
       or entry_profile_id = any(seen_profile_ids) then
      return false;
    end if;

    seen_profile_ids := pg_catalog.array_append(seen_profile_ids, entry_profile_id);
    seen_ordinals := array[]::integer[];
    computed_total := 0;

    for day_entry in
      select value from pg_catalog.jsonb_array_elements(participant_entry->'days') as days(value)
    loop
      if pg_catalog.jsonb_typeof(day_entry) <> 'object'
         or pg_catalog.jsonb_typeof(day_entry->'ordinal') <> 'number'
         or (day_entry->>'ordinal') !~ '^[1-7]$' then
        return false;
      end if;
      ordinal_value := (day_entry->>'ordinal')::integer;
      if ordinal_value = any(seen_ordinals) then
        return false;
      end if;
      seen_ordinals := pg_catalog.array_append(seen_ordinals, ordinal_value);

      select pg_catalog.array_agg(key order by key)
      into object_keys
      from pg_catalog.jsonb_object_keys(day_entry) as keys(key);

      if day_entry->>'status' = 'points' then
        if object_keys <> array['centi_points', 'ordinal', 'status']::text[]
           or pg_catalog.jsonb_typeof(day_entry->'status') <> 'string'
           or pg_catalog.jsonb_typeof(day_entry->'centi_points') <> 'number'
           or (day_entry->>'centi_points') !~ '^(0|[1-9][0-9]{0,4})$' then
          return false;
        end if;
        point_value := (day_entry->>'centi_points')::integer;
        if point_value > 60000 then
          return false;
        end if;
        computed_total := computed_total + point_value;
      elsif day_entry->>'status' = 'unavailable' then
        if object_keys <> array['ordinal', 'reason', 'status']::text[]
           or pg_catalog.jsonb_typeof(day_entry->'status') <> 'string'
           or pg_catalog.jsonb_typeof(day_entry->'reason') <> 'string'
           or day_entry->>'reason' not in (
             'missing', 'sourceDataUnavailable', 'unsupportedActivityConfiguration',
             'invalidSourceData', 'missingMoveValue', 'missingMoveGoal',
             'nonPositiveMoveGoal', 'missingExerciseValue', 'missingExerciseGoal',
             'nonPositiveExerciseGoal', 'missingStandOrRollValue', 'missingStandOrRollGoal',
             'nonPositiveStandOrRollGoal', 'summaryPaused', 'summaryPauseStateUnknown',
             'invalidNumericCalculation'
           ) then
          return false;
        end if;
      else
        return false;
      end if;
    end loop;

    if seen_ordinals <> array[1, 2, 3, 4, 5, 6, 7]::integer[] then
      return false;
    end if;

    if entry_profile_id = participant_a_profile_id
       and computed_total <> participant_a_total_centi_points then
      return false;
    end if;
    if entry_profile_id = participant_b_profile_id
       and computed_total <> participant_b_total_centi_points then
      return false;
    end if;
  end loop;

  return seen_profile_ids @> array[participant_a_profile_id, participant_b_profile_id]::uuid[];
exception
  when others then
    return false;
end;
$$;

create table public.competition_results (
  competition_id uuid primary key references public.competitions(id),
  participant_a_profile_id uuid not null references public.profiles(id),
  participant_b_profile_id uuid not null references public.profiles(id),
  participant_a_total_centi_points integer not null check (participant_a_total_centi_points between 0 and 420000),
  participant_b_total_centi_points integer not null check (participant_b_total_centi_points between 0 and 420000),
  winner_profile_id uuid references public.profiles(id),
  outcome text not null check (outcome in ('winner', 'tie')),
  finalization_basis text not null check (finalization_basis in ('stable', 'best_available')),
  completed_at timestamptz not null,
  frozen_window jsonb not null,
  immutable_hash bytea not null check (pg_catalog.octet_length(immutable_hash) = 32),
  server_seq bigint not null check (server_seq > 0),
  constraint competition_result_participants_distinct check (participant_a_profile_id <> participant_b_profile_id),
  constraint competition_result_winner_shape check (
    (
      outcome = 'tie'
      and winner_profile_id is null
      and participant_a_total_centi_points = participant_b_total_centi_points
    )
    or (
      outcome = 'winner'
      and (
        (
          participant_a_total_centi_points > participant_b_total_centi_points
          and winner_profile_id = participant_a_profile_id
        )
        or (
          participant_b_total_centi_points > participant_a_total_centi_points
          and winner_profile_id = participant_b_profile_id
        )
      )
    )
  ),
  constraint competition_result_participant_a_membership_fk
    foreign key (competition_id, participant_a_profile_id)
    references public.competition_participants(competition_id, profile_id),
  constraint competition_result_participant_b_membership_fk
    foreign key (competition_id, participant_b_profile_id)
    references public.competition_participants(competition_id, profile_id),
  constraint competition_result_change_fk
    foreign key (competition_id, server_seq)
    references public.competition_change_log(competition_id, server_seq),
  constraint competition_result_server_seq_unique unique (competition_id, server_seq),
  constraint competition_result_frozen_window_check check (
    private.is_valid_frozen_window_v1(
      frozen_window,
      participant_a_profile_id,
      participant_b_profile_id,
      participant_a_total_centi_points,
      participant_b_total_centi_points
    )
  )
);

create table public.competition_awards (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references public.competitions(id),
  profile_id uuid not null references public.profiles(id),
  award_type text not null check (award_type ~ '^[a-z][a-z0-9_]{0,63}$'),
  server_seq bigint not null check (server_seq > 0),
  earned_at timestamptz not null,
  constraint competition_award_membership_fk
    foreign key (competition_id, profile_id)
    references public.competition_participants(competition_id, profile_id),
  constraint competition_award_change_fk
    foreign key (competition_id, server_seq)
    references public.competition_change_log(competition_id, server_seq),
  constraint competition_award_unique unique (competition_id, profile_id, award_type),
  constraint competition_award_server_seq_unique unique (competition_id, server_seq)
);

create table public.device_installations (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  apns_token text not null unique check (apns_token ~ '^[0-9a-f]{64,200}$'),
  environment text not null check (environment in ('sandbox', 'production')),
  state text not null check (state in ('active', 'revoked')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.support_events (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles(id) on delete set null,
  competition_id uuid references public.competitions(id) on delete set null,
  kind text not null check (kind ~ '^[a-z][a-z0-9_]{0,63}$'),
  code text not null check (code ~ '^[a-z][a-z0-9_]{0,63}$'),
  created_at timestamptz not null default now()
);

create or replace function private.assign_competition_change_sequence()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_row jsonb;
  target_competition_id uuid;
  target_entity_id uuid;
begin
  new_row := pg_catalog.to_jsonb(new);
  target_competition_id := (new_row->>'competition_id')::uuid;
  target_entity_id := coalesce((new_row->>tg_argv[1])::uuid, target_competition_id);
  new.server_seq := private.allocate_competition_server_seq(
    target_competition_id,
    tg_argv[0],
    target_entity_id,
    coalesce((new_row->>'received_at')::timestamptz, (new_row->>'attested_at')::timestamptz,
             (new_row->>'completed_at')::timestamptz, (new_row->>'earned_at')::timestamptz, now())
  );
  return new;
end;
$$;

create trigger assign_daily_score_revision_sequence
before insert on public.daily_score_revisions
for each row execute function private.assign_competition_change_sequence('score_revision_recorded', 'id');

create trigger assign_participant_attestation_sequence
before insert on public.participant_finalization_attestations
for each row execute function private.assign_competition_change_sequence('participant_attested', 'id');

create trigger assign_competition_result_sequence
before insert on public.competition_results
for each row execute function private.assign_competition_change_sequence('competition_result_confirmed', 'competition_id');

create trigger assign_competition_award_sequence
before insert on public.competition_awards
for each row execute function private.assign_competition_change_sequence('competition_award_earned', 'id');

create or replace function private.reject_append_only_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = '55000';
end;
$$;

create trigger reject_daily_score_revision_mutation
before update or delete on public.daily_score_revisions
for each row execute function private.reject_append_only_mutation();

create trigger reject_participant_attestation_mutation
before update or delete on public.participant_finalization_attestations
for each row execute function private.reject_append_only_mutation();

create trigger reject_competition_result_mutation
before update or delete on public.competition_results
for each row execute function private.reject_append_only_mutation();

create trigger reject_competition_award_mutation
before update or delete on public.competition_awards
for each row execute function private.reject_append_only_mutation();

create trigger reject_competition_change_log_mutation
before update or delete on public.competition_change_log
for each row execute function private.reject_append_only_mutation();

create index competition_participants_profile_idx
  on public.competition_participants(profile_id, competition_id);
create index competition_change_log_cursor_idx
  on public.competition_change_log(competition_id, server_seq);
create index daily_score_revisions_participant_day_idx
  on public.daily_score_revisions(competition_id, participant_profile_id, day_ordinal, client_revision);
create index competition_invites_expiry_idx
  on public.competition_invites(expires_at)
  where consumed_at is null;
create index device_installations_profile_idx
  on public.device_installations(profile_id)
  where state = 'active';

-- The foundation migration is intentionally deny-by-default. Task 3 installs
-- narrow client policies and column grants; service-side mutations continue to
-- run through trusted database functions.
alter table public.profiles enable row level security;
alter table public.competitions enable row level security;
alter table public.competition_participants enable row level security;
alter table public.competition_invites enable row level security;
alter table public.competition_change_log enable row level security;
alter table public.daily_score_revisions enable row level security;
alter table public.participant_finalization_attestations enable row level security;
alter table public.competition_results enable row level security;
alter table public.competition_awards enable row level security;
alter table public.device_installations enable row level security;
alter table public.support_events enable row level security;

revoke all on table
  public.profiles,
  public.competitions,
  public.competition_participants,
  public.competition_invites,
  public.competition_change_log,
  public.daily_score_revisions,
  public.participant_finalization_attestations,
  public.competition_results,
  public.competition_awards,
  public.device_installations,
  public.support_events
from public, anon, authenticated, service_role;

alter default privileges in schema public
  revoke all on tables from anon, authenticated, service_role;
