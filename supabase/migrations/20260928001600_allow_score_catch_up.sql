-- Permit truthful offline catch-up through the existing attested score path.
-- CREATE OR REPLACE preserves the restricted EXECUTE grants from migration00800.
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
  -- Evaluation time is when the device read HealthKit, not the scored day's date.
  -- Catch-up may evaluate earlier days, but neither a pre-day nor future-day
  -- evaluation can authorize a score in the frozen competition calendar.
  if (evaluated at time zone comp.time_zone_identifier)::date < comp.start_day+(ord-1)
    or (evaluated at time zone comp.time_zone_identifier)::date >
      (pg_catalog.statement_timestamp() at time zone comp.time_zone_identifier)::date then
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
