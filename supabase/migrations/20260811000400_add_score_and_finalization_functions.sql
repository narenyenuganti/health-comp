alter table public.daily_score_revisions
  add constraint daily_score_revision_global_number_unique
  unique (competition_id, participant_profile_id, client_revision);

alter table public.participant_finalization_attestations
  drop constraint participant_attestation_unique,
  drop constraint participant_finalization_attestations_accepted_revisions_check,
  add column semantic_event_id text not null default gen_random_uuid()::text,
  add column attestation_version bigint not null default 1 check (attestation_version > 0),
  add constraint participant_attestation_semantic_unique
    unique (competition_id, participant_profile_id, semantic_event_id),
  add constraint participant_attestation_version_unique
    unique (competition_id, participant_profile_id, attestation_version),
  add constraint participant_attestation_accepted_revisions_check check (
    pg_catalog.array_ndims(accepted_revisions) = 1
    and pg_catalog.array_length(accepted_revisions, 1) = 7
    and pg_catalog.array_position(accepted_revisions, null) is null
    and 0 <= all(accepted_revisions)
    and (basis <> 'stable' or 0 < all(accepted_revisions))
  );

create or replace function private.window_day_content_v1(
  ordinal integer, status text, points integer, reason text,
  wire_digest bytea, client_revision bigint, server_seq bigint
)
returns bytea
language sql immutable set search_path = ''
as $$
  select pg_catalog.convert_to('healthcomp-window-day-v1', 'UTF8') || pg_catalog.decode('00','hex')
    || private.tlv_v1(1, pg_catalog.int4send(ordinal))
    || private.tlv_v1(2, pg_catalog.convert_to(status, 'UTF8'))
    || private.tlv_v1(3, pg_catalog.int4send(points))
    || private.tlv_v1(4, pg_catalog.convert_to(reason, 'UTF8'))
    || private.tlv_v1(5, wire_digest)
    || private.tlv_v1(6, pg_catalog.int8send(client_revision))
    || private.tlv_v1(7, pg_catalog.int8send(server_seq));
$$;

create or replace function private.owner_window_content_v1(
  target_competition_id uuid,
  target_participant_id uuid,
  accepted_revisions bigint[]
)
returns bytea
language plpgsql stable set search_path = ''
as $$
declare
  output bytea := pg_catalog.convert_to('healthcomp-owner-window-v1', 'UTF8') || pg_catalog.decode('00','hex');
  revision bigint;
  score_row record;
  day_status text;
  day_points integer;
  day_reason text;
begin
  if pg_catalog.array_length(accepted_revisions, 1) <> 7 then
    raise exception 'invalid_attestation' using errcode = '22023';
  end if;
  output := output || private.tlv_v1(1, pg_catalog.uuid_send(target_competition_id));
  output := output || private.tlv_v1(2, pg_catalog.uuid_send(target_participant_id));
  output := output || private.tlv_v1(3, pg_catalog.convert_to('healthcomp.activity-score.v1','UTF8'));
  for ordinal in 1..7 loop
    revision := accepted_revisions[ordinal];
    score_row := null;
    if revision > 0 then
      select * into score_row
      from public.daily_score_revisions score
      where score.competition_id = target_competition_id
        and score.participant_profile_id = target_participant_id
        and score.day_ordinal = ordinal
        and score.client_revision = revision;
      if not found then
        raise exception 'revision_not_found' using errcode = '22023';
      end if;
      if score_row.availability_reason = 'available' then
        day_status := 'points'; day_points := score_row.accepted_centi_points; day_reason := null;
      else
        day_status := 'unavailable'; day_points := null; day_reason := score_row.availability_reason;
      end if;
      output := output || private.tlv_v1(10 + ordinal,
        private.window_day_content_v1(ordinal, day_status, day_points, day_reason,
          score_row.wire_content_sha256, score_row.client_revision, score_row.server_seq));
    else
      output := output || private.tlv_v1(10 + ordinal,
        private.window_day_content_v1(ordinal, 'unavailable', null, 'missing', null, null, null));
    end if;
  end loop;
  return output;
end;
$$;

create or replace function private.owner_window_commitment_v1(
  target_competition_id uuid, target_participant_id uuid, accepted_revisions bigint[]
)
returns bytea language sql stable set search_path = ''
as $$ select extensions.digest(private.owner_window_content_v1(target_competition_id,target_participant_id,accepted_revisions),'sha256'); $$;

create or replace function private.latest_revision_vector(
  target_competition_id uuid, target_participant_id uuid
)
returns bigint[] language sql stable set search_path = ''
as $$
  select pg_catalog.array_agg(coalesce(head.client_revision,0) order by ordinal)
  from pg_catalog.generate_series(1,7) ordinal
  left join lateral (
    select score.client_revision
    from public.daily_score_revisions score
    where score.competition_id=target_competition_id
      and score.participant_profile_id=target_participant_id
      and score.day_ordinal=ordinal
    order by score.client_revision desc limit 1
  ) head on true;
$$;

create or replace function private.is_valid_frozen_window_v2(
  frozen_window jsonb,
  target_competition_id uuid,
  participant_a_profile_id uuid,
  participant_b_profile_id uuid,
  participant_a_total_centi_points integer,
  participant_b_total_centi_points integer
)
returns boolean language plpgsql stable set search_path = ''
as $$
declare p jsonb; d jsonb; ids uuid[]:=array[]::uuid[]; ords integer[]; total integer; pid uuid; prior_pid uuid; keys text[]; content bytea; points integer; reason text; digest bytea; rev bigint; seq bigint;
begin
  if pg_catalog.jsonb_typeof(frozen_window)<>'object'
    or pg_catalog.jsonb_typeof(frozen_window->'version')<>'number' or frozen_window->>'version'<>'2'
    or pg_catalog.jsonb_typeof(frozen_window->'policy')<>'string' or frozen_window->>'policy'<>'healthcomp.activity-score.v1'
    or (select pg_catalog.array_agg(key order by key) from pg_catalog.jsonb_object_keys(frozen_window) key)
       <> array['participants','policy','version']::text[]
    or pg_catalog.jsonb_array_length(frozen_window->'participants')<>2 then return false; end if;
  for p in select value from pg_catalog.jsonb_array_elements(frozen_window->'participants') value loop
    if (select pg_catalog.array_agg(key order by key) from pg_catalog.jsonb_object_keys(p) key)
       <> array['days','profile_id','total_centi_points','window_commitment_sha256']::text[] then return false; end if;
    pid := (p->>'profile_id')::uuid;
    if pid not in (participant_a_profile_id,participant_b_profile_id) or pid=any(ids) or (prior_pid is not null and pid::text<=prior_pid::text) then return false; end if;
    prior_pid:=pid;
    ids:=pg_catalog.array_append(ids,pid); ords:=array[]::integer[]; total:=0;
    if (p->>'window_commitment_sha256') !~ '^[0-9a-f]{64}$' or pg_catalog.jsonb_array_length(p->'days')<>7 then return false; end if;
    if pg_catalog.jsonb_typeof(p->'profile_id')<>'string' or pg_catalog.jsonb_typeof(p->'total_centi_points')<>'number' or pg_catalog.jsonb_typeof(p->'window_commitment_sha256')<>'string' then return false; end if;
    content:=pg_catalog.convert_to('healthcomp-owner-window-v1','UTF8')||pg_catalog.decode('00','hex')||private.tlv_v1(1,pg_catalog.uuid_send(target_competition_id))||private.tlv_v1(2,pg_catalog.uuid_send(pid))||private.tlv_v1(3,pg_catalog.convert_to('healthcomp.activity-score.v1','UTF8'));
    for d in select value from pg_catalog.jsonb_array_elements(p->'days') value loop
      select pg_catalog.array_agg(key order by key) into keys from pg_catalog.jsonb_object_keys(d) key;
      if keys<>array['centi_points','client_revision','ordinal','reason','scoring_policy_identity','server_seq','source','status','wire_content_sha256']::text[] then return false; end if;
      if pg_catalog.jsonb_typeof(d->'ordinal')<>'number' or pg_catalog.jsonb_typeof(d->'source')<>'string' or pg_catalog.jsonb_typeof(d->'status')<>'string' then return false; end if;
      ords:=pg_catalog.array_append(ords,(d->>'ordinal')::integer);
      if d->>'source'='deadline_missing' then
        if d->>'status'<>'unavailable' or d->>'reason'<>'missing' or d->'centi_points'<>'null'::jsonb or d->'wire_content_sha256'<>'null'::jsonb or d->'client_revision'<>'null'::jsonb or d->'server_seq'<>'null'::jsonb or d->'scoring_policy_identity'<>'null'::jsonb then return false; end if;
        points:=null;reason:='missing';digest:=null;rev:=null;seq:=null;
      elsif d->>'source'='accepted_revision' then
        if pg_catalog.jsonb_typeof(d->'wire_content_sha256')<>'string'
          or pg_catalog.jsonb_typeof(d->'client_revision')<>'string'
          or pg_catalog.jsonb_typeof(d->'server_seq')<>'string'
          or pg_catalog.jsonb_typeof(d->'scoring_policy_identity')<>'string'
          or d->>'scoring_policy_identity'<>'healthcomp.activity-score.v1'
          or (d->>'wire_content_sha256')!~'^[0-9a-f]{64}$'
          or (d->>'client_revision')!~'^[1-9][0-9]*$'
          or (d->>'server_seq')!~'^[1-9][0-9]*$' then return false; end if;
        digest:=pg_catalog.decode(d->>'wire_content_sha256','hex');rev:=(d->>'client_revision')::bigint;seq:=(d->>'server_seq')::bigint;
        if d->>'status'='points' then if pg_catalog.jsonb_typeof(d->'centi_points')<>'number' then return false;end if;points:=(d->>'centi_points')::integer;if points not between 0 and 60000 or d->'reason'<>'null'::jsonb then return false;end if;reason:=null;total:=total+points;
        elsif d->>'status'='unavailable' then points:=null;reason:=d->>'reason';if pg_catalog.jsonb_typeof(d->'reason')<>'string' or reason not in ('sourceDataUnavailable','unsupportedActivityConfiguration','invalidSourceData','missingMoveValue','missingMoveGoal','nonPositiveMoveGoal','missingExerciseValue','missingExerciseGoal','nonPositiveExerciseGoal','missingStandOrRollValue','missingStandOrRollGoal','nonPositiveStandOrRollGoal','summaryPaused','summaryPauseStateUnknown','invalidNumericCalculation') or d->'centi_points'<>'null'::jsonb then return false;end if;
        else return false;end if;
      else return false;end if;
      content:=content||private.tlv_v1(10+(d->>'ordinal')::integer,private.window_day_content_v1((d->>'ordinal')::integer,d->>'status',points,reason,digest,rev,seq));
    end loop;
    if ords<>array[1,2,3,4,5,6,7] then return false; end if;
    if (p->>'total_centi_points')::integer<>total then return false; end if;
    if p->>'window_commitment_sha256'<>pg_catalog.encode(extensions.digest(content,'sha256'),'hex') then return false; end if;
    if pid=participant_a_profile_id and total<>participant_a_total_centi_points then return false; end if;
    if pid=participant_b_profile_id and total<>participant_b_total_centi_points then return false; end if;
  end loop;
  return ids @> array[participant_a_profile_id,participant_b_profile_id];
exception when others then return false;
end;
$$;

alter table public.competition_results drop constraint competition_result_frozen_window_check;
alter table public.competition_results add constraint competition_result_frozen_window_check check (
  private.is_valid_frozen_window_v1(frozen_window,participant_a_profile_id,participant_b_profile_id,participant_a_total_centi_points,participant_b_total_centi_points)
  or private.is_valid_frozen_window_v2(frozen_window,competition_id,participant_a_profile_id,participant_b_profile_id,participant_a_total_centi_points,participant_b_total_centi_points)
);

create or replace function private.result_immutable_hash_v1(
  target_competition_id uuid,
  participant_a uuid, total_a integer, commitment_a bytea,
  participant_b uuid, total_b integer, commitment_b bytea,
  result_outcome text, winner uuid, result_basis text
)
returns bytea language sql immutable set search_path = ''
as $$
  select extensions.digest(
    pg_catalog.convert_to('healthcomp-result-v1','UTF8')||pg_catalog.decode('00','hex')
    ||private.tlv_v1(1,pg_catalog.uuid_send(target_competition_id))
    ||private.tlv_v1(2,pg_catalog.uuid_send(participant_a))
    ||private.tlv_v1(3,pg_catalog.int4send(total_a))
    ||private.tlv_v1(4,commitment_a)
    ||private.tlv_v1(5,pg_catalog.uuid_send(participant_b))
    ||private.tlv_v1(6,pg_catalog.int4send(total_b))
    ||private.tlv_v1(7,commitment_b)
    ||private.tlv_v1(8,pg_catalog.convert_to(result_outcome,'UTF8'))
    ||private.tlv_v1(9,pg_catalog.uuid_send(winner))
    ||private.tlv_v1(10,pg_catalog.convert_to(result_basis,'UTF8')),
    'sha256');
$$;

alter table public.competition_results add constraint competition_result_immutable_hash_check check (
  frozen_window->>'version'='1' or immutable_hash=private.result_immutable_hash_v1(competition_id,participant_a_profile_id,participant_a_total_centi_points,
    pg_catalog.decode(frozen_window->'participants'->0->>'window_commitment_sha256','hex'),
    participant_b_profile_id,participant_b_total_centi_points,
    pg_catalog.decode(frozen_window->'participants'->1->>'window_commitment_sha256','hex'),outcome,winner_profile_id,finalization_basis)
) not valid;

create or replace function private.assert_authenticated_profile()
returns uuid language plpgsql security definer set search_path = ''
as $$ declare pid uuid; begin
  if (select auth.role()) is distinct from 'authenticated' or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode='42501'; end if;
  select id into pid from public.profiles where auth_user_id=(select auth.uid()) and state='active';
  if pid is null then raise exception 'authentication_required' using errcode='42501'; end if;
  return pid;
end; $$;

create or replace function private.score_rejection_v1(cid uuid, pid uuid, rejection_code text)
returns jsonb language plpgsql stable set search_path = ''
as $$
declare head record; cursor_value bigint; has_head boolean;
begin
  select * into head from public.daily_score_revisions s
   where s.competition_id=cid and s.participant_profile_id=pid
   order by s.client_revision desc,s.server_seq desc limit 1;
  has_head:=found;
  select c.next_server_seq-1 into cursor_value from public.competitions c where c.id=cid;
  return pg_catalog.jsonb_build_object(
    'disposition','rejected','code',rejection_code,
    'acceptedCentiPoints',case when has_head then head.accepted_centi_points else null end,
    'wireContentSHA256',case when has_head then pg_catalog.encode(head.wire_content_sha256,'hex') else null end,
    'acceptedServerSeq',case when has_head then head.server_seq::text else null end,
    'competitionCursor',cursor_value::text);
end; $$;

create or replace function public.submit_score_revision(
  competition_id uuid, semantic_event_id uuid, day_ordinal integer, client_revision bigint,
  evaluated_at timestamptz, move_mode text, stand_mode text,
  move_basis_points integer, exercise_basis_points integer, stand_basis_points integer,
  availability_reason text, scoring_policy_identity text, expected_wire_content_sha256 text
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  cid alias for competition_id; sid alias for semantic_event_id; ord alias for day_ordinal;
  rev alias for client_revision; evaluated alias for evaluated_at; mm alias for move_mode; sm alias for stand_mode;
  mbp alias for move_basis_points; ebp alias for exercise_basis_points; sbp alias for stand_basis_points;
  availability alias for availability_reason; policy alias for scoring_policy_identity; expected_digest alias for expected_wire_content_sha256;
  pid uuid; comp record; prior record; points integer; digest bytea; inserted record;
begin
  pid:=private.assert_authenticated_profile();
  select c.* into comp from public.competitions c
  join public.competition_participants p on p.competition_id=c.id and p.profile_id=pid and p.state='accepted'
  where c.id=cid for update of c;
  if not found then raise exception 'competition_not_found' using errcode='P0002'; end if;

  select * into prior from public.daily_score_revisions s
   where s.competition_id=cid and s.participant_profile_id=pid
     and (s.semantic_event_id=sid::text or s.client_revision=rev)
   order by (s.semantic_event_id=sid::text) desc limit 1;
  if found then
    points:=case when availability='available' then least(mbp+ebp+sbp,60000) else null end;
    digest:=private.wire_score_digest_v1(cid,pid,ord::smallint,mm,sm,mbp,ebp,sbp,points,availability,policy,rev);
    if expected_digest is null or expected_digest !~ '^[0-9a-f]{64}$' or pg_catalog.encode(digest,'hex')<>expected_digest then raise exception 'wire_digest_mismatch' using errcode='22023'; end if;
    if prior.semantic_event_id=sid::text and prior.client_revision=rev and prior.day_ordinal=ord
      and prior.evaluated_at=evaluated and prior.move_mode=mm and prior.stand_mode=sm
      and prior.move_basis_points is not distinct from mbp and prior.exercise_basis_points is not distinct from ebp
      and prior.stand_basis_points is not distinct from sbp and prior.availability_reason=availability
      and prior.scoring_policy_identity=policy and prior.wire_content_sha256=digest then
      return pg_catalog.jsonb_build_object('disposition','duplicate','acceptedCentiPoints',prior.accepted_centi_points,
        'wireContentSHA256',pg_catalog.encode(prior.wire_content_sha256,'hex'),'acceptedServerSeq',prior.server_seq::text,'competitionCursor',(select next_server_seq-1 from public.competitions where id=cid)::text);
    end if;
    return private.score_rejection_v1(cid,pid,'divergent_duplicate');
  end if;

  if comp.lifecycle not in ('scheduled','active','ends_today','tallying')
    or exists(select 1 from public.competition_results r where r.competition_id=cid) then
    return private.score_rejection_v1(cid,pid,'competition_terminal'); end if;
  if exists(select 1 from public.participant_finalization_attestations a
    where a.competition_id=cid and a.participant_profile_id=pid and a.basis='stable') then
    return private.score_rejection_v1(cid,pid,'window_stable'); end if;
  if comp.best_available_deadline<=pg_catalog.statement_timestamp() then
    perform private.finalize_competition_locked(cid,pg_catalog.statement_timestamp());
    return private.score_rejection_v1(cid,pid,'competition_finalized'); end if;
  if ord not between 1 and 7 or rev<=0 or sid is null then raise exception 'invalid_score' using errcode='22023'; end if;
  if policy<>comp.scoring_policy_identity or policy<>'healthcomp.activity-score.v1' then raise exception 'wrong_policy' using errcode='22023'; end if;
  if (evaluated at time zone comp.time_zone_identifier)::date <> comp.start_day+(ord-1) then
    raise exception 'day_mismatch' using errcode='22023'; end if;
  if mm not in ('activeEnergyKilocalories','moveMinutes') or sm not in ('standHours','rollHours','unknown') then
    raise exception 'invalid_score' using errcode='22023'; end if;
  if availability='available' then
    if sm='unknown' or mbp is null or ebp is null or sbp is null or mbp not between 0 and 20000 or ebp not between 0 and 20000 or sbp not between 0 and 20000 then
      raise exception 'invalid_score' using errcode='22023'; end if;
    points:=least(mbp+ebp+sbp,60000);
  else
    if availability not in ('sourceDataUnavailable','unsupportedActivityConfiguration','invalidSourceData','missingMoveValue','missingMoveGoal','nonPositiveMoveGoal','missingExerciseValue','missingExerciseGoal','nonPositiveExerciseGoal','missingStandOrRollValue','missingStandOrRollGoal','nonPositiveStandOrRollGoal','summaryPaused','summaryPauseStateUnknown','invalidNumericCalculation')
      or mbp is not null or ebp is not null or sbp is not null then raise exception 'invalid_score' using errcode='22023'; end if;
    points:=null;
  end if;
  if exists(select 1 from public.daily_score_revisions s where s.competition_id=cid and s.participant_profile_id=pid and s.client_revision>rev) then
    return private.score_rejection_v1(cid,pid,'revision_regression'); end if;
  digest:=private.wire_score_digest_v1(cid,pid,ord::smallint,mm,sm,mbp,ebp,sbp,points,availability,policy,rev);
  if expected_digest is null or expected_digest !~ '^[0-9a-f]{64}$' or pg_catalog.encode(digest,'hex')<>expected_digest then raise exception 'wire_digest_mismatch' using errcode='22023'; end if;
  insert into public.daily_score_revisions(competition_id,participant_profile_id,day_ordinal,semantic_event_id,client_revision,
    move_mode,stand_mode,move_basis_points,exercise_basis_points,stand_basis_points,accepted_centi_points,availability_reason,
    scoring_policy_identity,wire_content_sha256,server_seq,evaluated_at)
  values(cid,pid,ord,sid::text,rev,mm,sm,mbp,ebp,sbp,points,availability,policy,digest,1,evaluated) returning * into inserted;
  return pg_catalog.jsonb_build_object('disposition','appended','acceptedCentiPoints',points,
    'wireContentSHA256',pg_catalog.encode(digest,'hex'),'acceptedServerSeq',inserted.server_seq::text,'competitionCursor',(select next_server_seq-1 from public.competitions where id=cid)::text);
end; $$;

create or replace function public.attest_final_window(
  competition_id uuid, semantic_event_id uuid, attestation_version bigint, basis text, accepted_revisions bigint[], expected_window_commitment_sha256 text
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare cid alias for competition_id; sid alias for semantic_event_id; ver alias for attestation_version;
  requested_basis alias for basis; revisions alias for accepted_revisions; expected_commitment alias for expected_window_commitment_sha256; pid uuid; comp record; prior record;
  latest bigint[]; commitment bytea; inserted record;
begin
  pid:=private.assert_authenticated_profile();
  select c.* into comp from public.competitions c join public.competition_participants p
   on p.competition_id=c.id and p.profile_id=pid and p.state='accepted' where c.id=cid for update of c;
  if not found then raise exception 'competition_not_found' using errcode='P0002'; end if;
  select * into prior from public.participant_finalization_attestations a where a.competition_id=cid and a.participant_profile_id=pid
    and (a.semantic_event_id=sid::text or a.attestation_version=ver) order by (a.semantic_event_id=sid::text) desc limit 1;
  if found then
    if prior.semantic_event_id=sid::text and prior.attestation_version=ver and prior.basis=requested_basis and prior.accepted_revisions=revisions then
      if expected_commitment is null or expected_commitment !~ '^[0-9a-f]{64}$' or pg_catalog.encode(prior.window_commitment_sha256,'hex')<>expected_commitment then raise exception 'window_commitment_mismatch' using errcode='22023'; end if;
      return pg_catalog.jsonb_build_object('disposition','duplicate','windowCommitmentSHA256',pg_catalog.encode(prior.window_commitment_sha256,'hex'),'serverCursor',prior.server_seq::text);
    end if;
    raise exception 'divergent_duplicate' using errcode='P0001';
  end if;
  if comp.lifecycle not in ('scheduled','active','ends_today','tallying') or exists(select 1 from public.competition_results r where r.competition_id=cid) then
    raise exception 'competition_terminal' using errcode='P0001'; end if;
  if requested_basis not in ('stable','best_available') or pg_catalog.array_length(revisions,1)<>7 or ver<=0 then
    raise exception 'invalid_attestation' using errcode='22023'; end if;
  latest:=private.latest_revision_vector(cid,pid);
  if requested_basis='best_available' and exists(select 1 from public.participant_finalization_attestations a where a.competition_id=cid and a.participant_profile_id=pid and a.basis='stable') then raise exception 'attestation_downgrade' using errcode='P0001'; end if;
  if requested_basis='stable' then
    if pg_catalog.statement_timestamp()<((comp.start_day+7)::timestamp at time zone comp.time_zone_identifier) or 0=any(revisions) or revisions<>latest then raise exception 'window_not_stable' using errcode='P0001'; end if;
  else
    if pg_catalog.statement_timestamp()<comp.best_available_deadline or revisions<>latest then raise exception 'best_available_not_ready' using errcode='P0001'; end if;
  end if;
  if exists(select 1 from public.participant_finalization_attestations a where a.competition_id=cid and a.participant_profile_id=pid and a.attestation_version>ver) then
    raise exception 'attestation_regression' using errcode='P0001'; end if;
  commitment:=private.owner_window_commitment_v1(cid,pid,revisions);
  if expected_commitment is null or expected_commitment !~ '^[0-9a-f]{64}$' or pg_catalog.encode(commitment,'hex')<>expected_commitment then raise exception 'window_commitment_mismatch' using errcode='22023'; end if;
  insert into public.participant_finalization_attestations(competition_id,participant_profile_id,basis,window_commitment_sha256,
    accepted_revisions,server_seq,attested_at,semantic_event_id,attestation_version)
  values(cid,pid,requested_basis,commitment,revisions,1,pg_catalog.statement_timestamp(),sid::text,ver) returning * into inserted;
  perform private.finalize_competition_locked(cid,pg_catalog.statement_timestamp());
  return pg_catalog.jsonb_build_object('disposition','appended','windowCommitmentSHA256',pg_catalog.encode(commitment,'hex'),'serverCursor',inserted.server_seq::text);
end; $$;

-- Migration-test compatibility overloads are deliberately unavailable to API
-- roles. They keep earlier schema/RLS fixtures executable as database owner.
create or replace function public.submit_score_revision(
  competition_id uuid, semantic_event_id uuid, day_ordinal integer, client_revision bigint,
  evaluated_at timestamptz, move_mode text, stand_mode text,
  move_basis_points integer, exercise_basis_points integer, stand_basis_points integer,
  availability_reason text, scoring_policy_identity text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare pid uuid; points integer; expected text;
begin
 if session_user<>'postgres' then raise exception 'digest_required' using errcode='42501'; end if;
 pid:=private.assert_authenticated_profile(); points:=case when availability_reason='available' then least(move_basis_points+exercise_basis_points+stand_basis_points,60000) else null end;
 expected:=pg_catalog.encode(private.wire_score_digest_v1(competition_id,pid,day_ordinal::smallint,move_mode,stand_mode,move_basis_points,exercise_basis_points,stand_basis_points,points,availability_reason,scoring_policy_identity,client_revision),'hex');
 return public.submit_score_revision(competition_id,semantic_event_id,day_ordinal,client_revision,evaluated_at,move_mode,stand_mode,move_basis_points,exercise_basis_points,stand_basis_points,availability_reason,scoring_policy_identity,expected);
end; $$;

create or replace function public.attest_final_window(
 competition_id uuid,semantic_event_id uuid,attestation_version bigint,basis text,accepted_revisions bigint[]
) returns jsonb language plpgsql security definer set search_path='' as $$
declare pid uuid; expected text;
begin
 if session_user<>'postgres' then raise exception 'commitment_required' using errcode='42501'; end if;
 pid:=private.assert_authenticated_profile(); expected:=pg_catalog.encode(private.owner_window_commitment_v1(competition_id,pid,accepted_revisions),'hex');
 return public.attest_final_window(competition_id,semantic_event_id,attestation_version,basis,accepted_revisions,expected);
end; $$;

create or replace function private.participant_projection_v2(cid uuid,pid uuid,revisions bigint[],commitment bytea)
returns jsonb language plpgsql stable set search_path = ''
as $$
declare rev bigint; s record; days jsonb:='[]'::jsonb; total integer:=0; entry jsonb;
begin
 for ord in 1..7 loop rev:=revisions[ord];
  if rev=0 then entry:=pg_catalog.jsonb_build_object('ordinal',ord,'status','unavailable','source','deadline_missing','reason','missing',
    'centi_points',null,'wire_content_sha256',null,'client_revision',null,'server_seq',null,'scoring_policy_identity',null);
  else select * into s from public.daily_score_revisions where competition_id=cid and participant_profile_id=pid and day_ordinal=ord and client_revision=rev;
    if s.availability_reason='available' then total:=total+s.accepted_centi_points;
      entry:=pg_catalog.jsonb_build_object('ordinal',ord,'status','points','source','accepted_revision','centi_points',s.accepted_centi_points,'reason',null,
       'wire_content_sha256',pg_catalog.encode(s.wire_content_sha256,'hex'),'client_revision',s.client_revision::text,'server_seq',s.server_seq::text,'scoring_policy_identity',s.scoring_policy_identity);
    else entry:=pg_catalog.jsonb_build_object('ordinal',ord,'status','unavailable','source','accepted_revision','centi_points',null,'reason',s.availability_reason,
       'wire_content_sha256',pg_catalog.encode(s.wire_content_sha256,'hex'),'client_revision',s.client_revision::text,'server_seq',s.server_seq::text,'scoring_policy_identity',s.scoring_policy_identity); end if;
  end if; days:=days||pg_catalog.jsonb_build_array(entry); end loop;
 return pg_catalog.jsonb_build_object('profile_id',pid,'total_centi_points',total,'window_commitment_sha256',pg_catalog.encode(commitment,'hex'),'days',days);
end; $$;

create or replace function private.finalize_competition_locked(target_competition_id uuid, as_of timestamptz)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare c record; pids uuid[]; rev_a bigint[]; rev_b bigint[]; com_a bytea; com_b bytea; pa jsonb; pb jsonb; total_a integer; total_b integer;
 final_basis text; outcome text; winner uuid; frozen_projection jsonb; result_hash bytea; existing record;
begin
 select * into c from public.competitions where id=target_competition_id for update;
 if not found then return null; end if;
 select * into existing from public.competition_results where competition_id=target_competition_id;
 if found then return pg_catalog.jsonb_build_object('disposition','existing','serverCursor',existing.server_seq::text); end if;
 select pg_catalog.array_agg(profile_id order by profile_id) into pids from public.competition_participants
   where competition_id=target_competition_id and state='accepted';
 if pg_catalog.array_length(pids,1)<>2 then return null; end if;
 if (select count(*) from (select distinct on(att.participant_profile_id) att.participant_profile_id,att.basis from public.participant_finalization_attestations att
      where att.competition_id=target_competition_id order by att.participant_profile_id,att.attestation_version desc) latest where latest.basis='stable')=2 then final_basis:='stable';
 elsif as_of>=c.best_available_deadline then final_basis:='best_available'; else return null; end if;
 rev_a:=private.latest_revision_vector(target_competition_id,pids[1]); rev_b:=private.latest_revision_vector(target_competition_id,pids[2]);
 com_a:=private.owner_window_commitment_v1(target_competition_id,pids[1],rev_a); com_b:=private.owner_window_commitment_v1(target_competition_id,pids[2],rev_b);
 pa:=private.participant_projection_v2(target_competition_id,pids[1],rev_a,com_a); pb:=private.participant_projection_v2(target_competition_id,pids[2],rev_b,com_b);
 total_a:=(pa->>'total_centi_points')::integer; total_b:=(pb->>'total_centi_points')::integer;
 if total_a=total_b then outcome:='tie';winner:=null; elsif total_a>total_b then outcome:='winner';winner:=pids[1];else outcome:='winner';winner:=pids[2];end if;
 frozen_projection:=pg_catalog.jsonb_build_object('version',2,'policy','healthcomp.activity-score.v1','participants',pg_catalog.jsonb_build_array(pa,pb));
 result_hash:=private.result_immutable_hash_v1(target_competition_id,pids[1],total_a,com_a,pids[2],total_b,com_b,outcome,winner,final_basis);
 insert into public.competition_results(competition_id,participant_a_profile_id,participant_b_profile_id,participant_a_total_centi_points,
   participant_b_total_centi_points,winner_profile_id,outcome,finalization_basis,completed_at,frozen_window,immutable_hash,server_seq)
 values(target_competition_id,pids[1],pids[2],total_a,total_b,winner,outcome,final_basis,as_of,frozen_projection,result_hash,1);
 if winner is not null then insert into public.competition_awards(competition_id,profile_id,award_type,server_seq,earned_at)
   values(target_competition_id,winner,'competition_win',1,as_of) on conflict do nothing; end if;
 update public.competitions set lifecycle='completed',updated_at=as_of where id=target_competition_id;
 return pg_catalog.jsonb_build_object('disposition','finalized','basis',final_basis,'immutableHash',pg_catalog.encode(result_hash,'hex'));
end; $$;

create or replace function public.finalize_competition(competition_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$ begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'service_role_required' using errcode='42501'; end if;
 return private.finalize_competition_locked(competition_id,pg_catalog.statement_timestamp());
end; $$;

create or replace function public.finalize_due_competitions(batch_size integer default 100)
returns bigint language plpgsql security definer set search_path = ''
as $$ declare row record; count bigint:=0; begin
 if (select auth.role()) is distinct from 'service_role' then raise exception 'service_role_required' using errcode='42501'; end if;
 if batch_size not between 1 and 1000 then raise exception 'invalid_batch_size' using errcode='22023'; end if;
 for row in select id from public.competitions where lifecycle in('scheduled','active','ends_today','tallying')
   and best_available_deadline<=pg_catalog.statement_timestamp() order by best_available_deadline for update skip locked limit batch_size
 loop if private.finalize_competition_locked(row.id,pg_catalog.statement_timestamp()) is not null then count:=count+1;end if; end loop;
 return count;
end; $$;

revoke all on function private.window_day_content_v1(integer,text,integer,text,bytea,bigint,bigint) from public,anon,authenticated,service_role;
revoke all on function private.owner_window_content_v1(uuid,uuid,bigint[]) from public,anon,authenticated,service_role;
revoke all on function private.owner_window_commitment_v1(uuid,uuid,bigint[]) from public,anon,authenticated,service_role;
revoke all on function private.latest_revision_vector(uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.result_immutable_hash_v1(uuid,uuid,integer,bytea,uuid,integer,bytea,text,uuid,text) from public,anon,authenticated,service_role;
revoke all on function private.assert_authenticated_profile() from public,anon,authenticated,service_role;
revoke all on function private.score_rejection_v1(uuid,uuid,text) from public,anon,authenticated,service_role;
revoke all on function private.participant_projection_v2(uuid,uuid,bigint[],bytea) from public,anon,authenticated,service_role;
revoke all on function private.finalize_competition_locked(uuid,timestamptz) from public,anon,authenticated,service_role;
revoke all on function public.submit_score_revision(uuid,uuid,integer,bigint,timestamptz,text,text,integer,integer,integer,text,text,text) from public,anon,authenticated,service_role;
grant execute on function public.submit_score_revision(uuid,uuid,integer,bigint,timestamptz,text,text,integer,integer,integer,text,text,text) to authenticated;
revoke all on function public.submit_score_revision(uuid,uuid,integer,bigint,timestamptz,text,text,integer,integer,integer,text,text) from public,anon,authenticated,service_role;
revoke all on function public.attest_final_window(uuid,uuid,bigint,text,bigint[],text) from public,anon,authenticated,service_role;
grant execute on function public.attest_final_window(uuid,uuid,bigint,text,bigint[],text) to authenticated;
revoke all on function public.attest_final_window(uuid,uuid,bigint,text,bigint[]) from public,anon,authenticated,service_role;
revoke all on function public.finalize_competition(uuid) from public,anon,authenticated,service_role;
grant execute on function public.finalize_competition(uuid) to service_role;
revoke all on function public.finalize_due_competitions(integer) from public,anon,authenticated,service_role;
grant execute on function public.finalize_due_competitions(integer) to service_role;
