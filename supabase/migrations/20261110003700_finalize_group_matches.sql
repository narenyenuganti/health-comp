create function private.finalize_group_match_locked(target_competition_id uuid, as_of timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare cid alias for target_competition_id; decision_time alias for as_of; c record; existing record;
  seat record; revisions bigint[]; commitment bytea; window_payload jsonb; seats_payload jsonb := '[]'::jsonb;
  totals jsonb; frozen jsonb; result_hash bytea; basis_value text; total integer;
begin
  select * into c from public.competitions where id = cid and format <> 'duel' for update;
  if not found then return null; end if;
  select * into existing from public.competition_group_results where competition_id = cid;
  if found then return pg_catalog.jsonb_build_object('disposition','existing','serverCursor',existing.server_seq::text); end if;
  if c.lifecycle not in ('scheduled','active','ends_today','tallying')
    or decision_time < ((c.start_day + 7)::timestamp at time zone c.time_zone_identifier) then return null; end if;
  if not exists (select 1 from public.competition_participants p where p.competition_id = cid and p.state = 'accepted' and p.left_at is null
    and not exists (select 1 from public.participant_finalization_attestations a
      where a.competition_id = cid and a.participant_profile_id = p.profile_id and a.basis = 'stable')) then
    basis_value := 'stable';
  elsif decision_time >= c.best_available_deadline then basis_value := 'best_available';
  else return null; end if;
  for seat in select s.*,p.left_at,p.frozen_through_day,p.frozen_revisions,p.state
    from public.competition_seats s left join public.competition_participants p
      on p.competition_id = s.competition_id and p.profile_id = s.profile_id
    where s.competition_id = cid order by s.seat_index loop
    if seat.kind = 'human' then
      if seat.state <> 'accepted' and not (seat.state = 'anonymized' and seat.left_at is not null) then return null; end if;
      revisions := coalesce(seat.frozen_revisions,private.latest_revision_vector(cid,seat.profile_id));
      commitment := private.owner_window_commitment_v1(cid,seat.profile_id,revisions);
      window_payload := private.participant_projection_v2(cid,seat.profile_id,revisions,commitment);
      if seat.left_at is not null then
        window_payload := pg_catalog.jsonb_set(window_payload,'{days}',(
          select pg_catalog.jsonb_agg(case when (d->>'ordinal')::integer > seat.frozen_through_day
            then pg_catalog.jsonb_build_object('ordinal',(d->>'ordinal')::integer,'status','afterLeave','source','leave_cutoff','centi_points',0)
            else d end order by (d->>'ordinal')::integer) from pg_catalog.jsonb_array_elements(window_payload->'days') d));
      end if;
      total := (window_payload->>'total_centi_points')::integer;
      seats_payload := seats_payload || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'id',seat.id,'seat_index',seat.seat_index,'team_number',seat.team_number,'kind','human','profile_id',seat.profile_id,
        'left_at',seat.left_at,'frozen_through_day',seat.frozen_through_day,'accepted_revisions',revisions,
        'window',window_payload,'total_centi_points',total,
        'accepted_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) || pg_catalog.jsonb_build_object(
          'client_revision',r.client_revision::text,'server_seq',r.server_seq::text,'wire_content_sha256',pg_catalog.encode(r.wire_content_sha256,'hex')) order by r.day_ordinal)
          from public.daily_score_revisions r where r.competition_id = cid and r.participant_profile_id = seat.profile_id
            and r.client_revision = revisions[r.day_ordinal]),'[]'::jsonb)));
    else
      select pg_catalog.sum(v)*100 into total from pg_catalog.unnest(seat.bot_daily_totals) v;
      if total is null then raise exception 'bot_week_not_fixed' using errcode = '23514'; end if;
      seats_payload := seats_payload || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'id',seat.id,'seat_index',seat.seat_index,'team_number',seat.team_number,'kind','bot','bot_mode',seat.bot_mode,
        'bot_seed',seat.bot_seed,'bot_baseline',seat.bot_baseline,'bot_generator_version',seat.bot_generator_version,
        'bot_daily_totals',seat.bot_daily_totals,'total_centi_points',total));
    end if;
  end loop;
  with subjects as (
    select case when c.format = 'doubles' then s->>'team_number' else s->>'id' end as subject,
      pg_catalog.sum((s->>'total_centi_points')::integer)::integer as points
    from pg_catalog.jsonb_array_elements(seats_payload) s group by 1
  ), ranked as (
    select *,pg_catalog.rank() over (order by points desc) as place from subjects
  ) select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('subject',subject,'place',place,'centipoints',points)
    order by place,subject) into totals from ranked;
  frozen := pg_catalog.jsonb_build_object('version',1,'competition_id',cid,'format',c.format,'seat_count',c.seat_count,
    'time_zone_identifier',c.time_zone_identifier,'start_day',c.start_day,'best_available_deadline',c.best_available_deadline,
    'scoring_policy_identity',c.scoring_policy_identity,'completed_at',decision_time,'basis',basis_value,'seats',seats_payload,'standings',totals);
  -- Canonical v1 bytes are UTF-8 PostgreSQL jsonb::text, prefixed by this domain and a NUL.
  result_hash := extensions.digest(pg_catalog.convert_to('healthcomp-group-result-v1','UTF8') || pg_catalog.decode('00','hex')
    || pg_catalog.convert_to(frozen::text,'UTF8'),'sha256');
  insert into public.competition_group_results(competition_id,format,finalization_basis,completed_at,standings,frozen_payload,immutable_hash,server_seq)
    values(cid,c.format,basis_value,decision_time,totals,frozen,result_hash,1);
  update public.competitions set lifecycle = 'completed',updated_at = decision_time where id = cid;
  return pg_catalog.jsonb_build_object('disposition','finalized','basis',basis_value,'immutableHash',pg_catalog.encode(result_hash,'hex'));
end; $$;
revoke all on function private.finalize_group_match_locked(uuid,timestamptz) from public,anon,authenticated,service_role;

create or replace function private.finalize_competition_locked(target_competition_id uuid, as_of timestamptz)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare c record; pids uuid[]; rev_a bigint[]; rev_b bigint[]; com_a bytea; com_b bytea; pa jsonb; pb jsonb; total_a integer; total_b integer;
 final_basis text; outcome text; winner uuid; frozen_projection jsonb; result_hash bytea; existing record;
begin
 select * into c from public.competitions where id=target_competition_id for update;
 if not found then return null; end if;
 if c.format <> 'duel' then return private.finalize_group_match_locked(target_competition_id,as_of); end if;
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

  if exists (select 1 from public.competition_participants p where p.competition_id = cid and p.profile_id = pid and p.left_at is not null)
    or exists (select 1 from public.competition_group_results r where r.competition_id = cid)
    or comp.lifecycle not in ('scheduled','active','ends_today','tallying')
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
  if exists (select 1 from public.competition_participants p where p.competition_id = cid and p.profile_id = pid and p.left_at is not null)
    or exists (select 1 from public.competition_group_results r where r.competition_id = cid)
    or comp.lifecycle not in ('scheduled','active','ends_today','tallying') or exists(select 1 from public.competition_results r where r.competition_id=cid) then
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

create or replace function public.authorize_app_attest_proof(
  target_auth_user_id uuid,
  challenge_id uuid,
  installation_id uuid,
  payload_sha256 text,
  key_id text,
  proof_kind text,
  public_key_pem text,
  receipt_base64 text,
  environment text,
  validation_category integer,
  bundle_version text,
  sign_count bigint,
  competition_id uuid,
  semantic_event_id uuid,
  day_ordinal integer,
  client_revision bigint,
  evaluated_at timestamptz,
  wire_content_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_auth_user_id alias for target_auth_user_id;
  input_challenge_id alias for challenge_id;
  input_installation_id alias for installation_id;
  input_payload_sha256 alias for payload_sha256;
  input_key_id alias for key_id;
  input_proof_kind alias for proof_kind;
  input_public_key_pem alias for public_key_pem;
  input_receipt_base64 alias for receipt_base64;
  input_environment alias for environment;
  input_validation_category alias for validation_category;
  input_bundle_version alias for bundle_version;
  input_sign_count alias for sign_count;
  input_competition_id alias for competition_id;
  input_semantic_event_id alias for semantic_event_id;
  input_day_ordinal alias for day_ordinal;
  input_client_revision alias for client_revision;
  input_evaluated_at alias for evaluated_at;
  input_wire_content_sha256 alias for wire_content_sha256;
  caller_profile_id uuid;
  payload_digest bytea;
  wire_digest bytea;
  receipt_bytes bytea;
  challenge_record record;
  key_record record;
  grant_record record;
  decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  if input_auth_user_id is null
     or input_challenge_id is null
     or input_installation_id is null
     or input_payload_sha256 is null
     or input_wire_content_sha256 is null
     or input_proof_kind is null
     or input_proof_kind not in ('attestation', 'assertion')
     or not private.app_attest_key_id_is_valid(input_key_id)
     or input_environment is null
     or input_environment not in ('development', 'production')
     or (input_validation_category is null) <>
        (input_bundle_version is null)
     or (
       input_validation_category is not null
       and (
         input_validation_category not between 1 and 10
         or input_validation_category in (7, 8, 9)
         or input_bundle_version !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
       )
     )
     or input_sign_count is null
     or input_sign_count not between 0 and 4294967295
     or input_competition_id is null
     or input_semantic_event_id is null
     or input_day_ordinal is null
     or input_day_ordinal not between 1 and 7
     or input_client_revision is null
     or input_client_revision <= 0
     or input_evaluated_at is null then
    raise exception 'invalid_app_attest_authorization'
      using errcode = '22023';
  end if;
  payload_digest := private.decode_app_attest_sha256(input_payload_sha256);
  wire_digest := private.decode_app_attest_sha256(input_wire_content_sha256);

  if input_proof_kind = 'attestation' then
    if input_sign_count <> 0
       or input_public_key_pem is null
       or pg_catalog.char_length(input_public_key_pem) not between 100 and 2048
       or not pg_catalog.starts_with(
         input_public_key_pem, '-----BEGIN PUBLIC KEY-----'
       )
       or input_receipt_base64 is null
       or pg_catalog.char_length(input_receipt_base64) not between 4 and 87384
       or pg_catalog.char_length(input_receipt_base64) % 4 <> 0
       or input_receipt_base64 !~ '^[A-Za-z0-9+/]+={0,2}$' then
      raise exception 'invalid_app_attest_authorization'
        using errcode = '22023';
    end if;
    begin
      receipt_bytes := pg_catalog.decode(input_receipt_base64, 'base64');
    exception
      when others then
        raise exception 'invalid_app_attest_authorization'
          using errcode = '22023';
    end;
    if pg_catalog.octet_length(receipt_bytes) not between 1 and 65536 then
      raise exception 'invalid_app_attest_authorization'
        using errcode = '22023';
    end if;
  elsif input_public_key_pem is not null or input_receipt_base64 is not null then
    raise exception 'invalid_app_attest_authorization'
      using errcode = '22023';
  end if;

  select profile_row.id
  into caller_profile_id
  from public.profiles profile_row
  where profile_row.auth_user_id = input_auth_user_id
    and profile_row.state = 'active'
  for update;

  if not found then
    raise exception 'app_attest_context_unavailable'
      using errcode = 'P0002';
  end if;

  perform 1
  from public.device_installations installation_row
  where installation_row.profile_id = caller_profile_id
    and installation_row.installation_id = input_installation_id
    and installation_row.state = 'active'
  for update;

  if not found then
    raise exception 'app_attest_context_unavailable'
      using errcode = 'P0002';
  end if;

  select challenge_row.*
  into challenge_record
  from private.app_attest_challenges challenge_row
  where challenge_row.id = input_challenge_id
  for update;

  if not found
     or challenge_record.profile_id <> caller_profile_id
     or challenge_record.installation_id <> input_installation_id
     or challenge_record.requested_key_id <> input_key_id
     or challenge_record.payload_sha256 <> payload_digest
     or challenge_record.purpose <> 'score_revision'
     or challenge_record.proof_kind <> input_proof_kind
     or challenge_record.consumed_at is not null
     or challenge_record.expires_at <= decision_time then
    raise exception 'app_attest_context_unavailable'
      using errcode = 'P0002';
  end if;

  perform 1
  from public.competitions competition_row
  join public.competition_participants participant_row
    on participant_row.competition_id = competition_row.id
   and participant_row.profile_id = caller_profile_id
   and participant_row.state = 'accepted'
  where competition_row.id = input_competition_id;

  if not found then
    raise exception 'competition_not_found' using errcode = 'P0002';
  end if;

  if exists (select 1 from public.competition_participants p where p.competition_id = input_competition_id
      and p.profile_id = caller_profile_id and p.left_at is not null)
    or exists (select 1 from public.competition_group_results r where r.competition_id = input_competition_id) then
    raise exception 'competition_terminal' using errcode = 'P0001';
  end if;

  select key_row.*
  into key_record
  from private.app_attest_keys key_row
  where key_row.profile_id = caller_profile_id
    and key_row.installation_id = input_installation_id
  for update;

  if input_proof_kind = 'assertion' then
    if not found
       or key_record.key_id <> input_key_id
       or key_record.environment <> input_environment
       or key_record.validation_category is distinct from
          input_validation_category
       or key_record.bundle_version is distinct from input_bundle_version
       or input_sign_count <= key_record.sign_count then
      raise exception 'app_attest_assertion_rejected' using errcode = 'P0001';
    end if;

    update private.app_attest_keys key_row
    set sign_count = input_sign_count,
        updated_at = decision_time
    where key_row.key_id = input_key_id;
  else
    if found and key_record.key_id = input_key_id then
      raise exception 'app_attest_attestation_stale' using errcode = 'P0001';
    end if;

    begin
      insert into private.app_attest_keys as key_target (
        key_id,
        profile_id,
        installation_id,
        public_key_pem,
        receipt,
        environment,
        validation_category,
        bundle_version,
        sign_count,
        attested_at,
        updated_at
      ) values (
        input_key_id,
        caller_profile_id,
        input_installation_id,
        input_public_key_pem,
        receipt_bytes,
        input_environment,
        input_validation_category,
        input_bundle_version,
        0,
        decision_time,
        decision_time
      )
      on conflict on constraint app_attest_keys_installation_unique
      do update
      set key_id = excluded.key_id,
          public_key_pem = excluded.public_key_pem,
          receipt = excluded.receipt,
          environment = excluded.environment,
          validation_category = excluded.validation_category,
          bundle_version = excluded.bundle_version,
          sign_count = 0,
          attested_at = excluded.attested_at,
          updated_at = excluded.updated_at;
    exception
      when unique_violation then
        raise exception 'app_attest_key_unavailable' using errcode = 'P0001';
    end;
  end if;

  update private.app_attest_challenges challenge_row
  set consumed_at = decision_time
  where challenge_row.id = challenge_record.id
    and challenge_row.consumed_at is null
    and challenge_row.expires_at > decision_time;

  if not found then
    raise exception 'app_attest_context_unavailable'
      using errcode = 'P0002';
  end if;

  insert into private.app_attest_submission_grants (
    challenge_id,
    profile_id,
    installation_id,
    key_id,
    payload_sha256,
    competition_id,
    semantic_event_id,
    day_ordinal,
    client_revision,
    evaluated_at,
    wire_content_sha256,
    created_at,
    expires_at
  ) values (
    challenge_record.id,
    caller_profile_id,
    input_installation_id,
    input_key_id,
    payload_digest,
    input_competition_id,
    input_semantic_event_id,
    input_day_ordinal,
    input_client_revision,
    input_evaluated_at,
    wire_digest,
    decision_time,
    decision_time + interval '2 minutes'
  )
  returning * into grant_record;

  return pg_catalog.jsonb_build_object(
    'version', 1,
    'grantID', grant_record.id,
    'expiresAt', grant_record.expires_at
  );
end;
$$;

create or replace function private.store_account_deletion_apple_token(
  target_profile_id uuid,
  refresh_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_profile_id alias for target_profile_id;
  input_refresh_token alias for refresh_token;
  deletion_row record;
  secret_name text;
  group_match record;
  decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  if input_profile_id is null
     or input_refresh_token is null
     or pg_catalog.char_length(input_refresh_token) not between 16 and 4096
     or input_refresh_token ~ '[[:space:][:cntrl:]]' then
    raise exception 'invalid_apple_refresh_token'
      using errcode = '22023';
  end if;

  select deletion_record.*
  into deletion_row
  from private.account_deletions deletion_record
  where deletion_record.profile_id = input_profile_id
  for update;

  if not found then
    raise exception 'account_deletion_not_found' using errcode = 'P0002';
  end if;

  if deletion_row.phase = 'token_ready' then
    return pg_catalog.jsonb_build_object(
      'profile_id', deletion_row.profile_id,
      'phase', deletion_row.phase
    );
  end if;

  if deletion_row.phase <> 'prepared' then
    raise exception 'invalid_account_deletion_phase'
      using errcode = '55000';
  end if;

  perform 1
  from public.profiles profile_record
  where profile_record.id = input_profile_id
    and profile_record.state = 'active'
  for update;

  if not found then
    raise exception 'active_profile_required' using errcode = '55000';
  end if;

  secret_name := private.account_deletion_secret_name(input_profile_id);
  delete from vault.secrets secret_row where secret_row.name = secret_name;
  perform vault.create_secret(
    input_refresh_token,
    secret_name,
    'Temporary Sign in with Apple token for durable account deletion'
  );

  update public.profiles profile_record
  set state = 'deleting',
      updated_at = decision_time
  where profile_record.id = input_profile_id;

  perform competition_record.id
  from public.competitions competition_record
  join public.competition_participants participant_record
    on participant_record.competition_id = competition_record.id
  where participant_record.profile_id = input_profile_id
    and competition_record.lifecycle in (
      'pending', 'scheduled', 'active', 'ends_today', 'tallying'
    )
  order by competition_record.id
  for update of competition_record;

  for group_match in select c.id from public.competitions c join public.competition_participants p
    on p.competition_id = c.id and p.profile_id = input_profile_id
    where c.format <> 'duel' and c.lifecycle in ('scheduled','active','ends_today','tallying')
      and (decision_time at time zone c.time_zone_identifier)::date >= c.start_day
    order by c.id loop
    perform private.bank_group_match_seat(group_match.id,input_profile_id,decision_time);
  end loop;

  update public.competitions competition_record
  set lifecycle = 'cancelled',
      updated_at = decision_time
  where competition_record.lifecycle in (
      'pending', 'scheduled', 'active', 'ends_today', 'tallying'
    )
    and (competition_record.format = 'duel' or competition_record.lifecycle = 'pending'
      or (decision_time at time zone competition_record.time_zone_identifier)::date < competition_record.start_day
      or not exists (select 1 from public.competition_participants active_person
        where active_person.competition_id = competition_record.id and active_person.state = 'accepted' and active_person.left_at is null))
    and exists (
      select 1
      from public.competition_participants participant_record
      where participant_record.competition_id = competition_record.id
        and participant_record.profile_id = input_profile_id
    );

  delete from public.competition_invites invite_record
  where invite_record.consumed_at is null
    and exists (
      select 1
      from public.competitions competition_record
      join public.competition_participants participant_record
        on participant_record.competition_id = competition_record.id
      where competition_record.id = invite_record.competition_id
        and competition_record.lifecycle = 'cancelled'
        and participant_record.profile_id = input_profile_id
    );

  update public.device_installations installation_record
  set state = 'revoked',
      updated_at = decision_time
  where installation_record.profile_id = input_profile_id
    and installation_record.state = 'active';

  update private.competition_notification_work work_record
  set state = 'superseded',
      lease_token = null,
      lease_expires_at = null,
      leased_apns_token_sha256 = null,
      updated_at = decision_time,
      completed_at = decision_time
  where work_record.state in ('pending', 'leased')
    and (
      work_record.recipient_profile_id = input_profile_id
      or work_record.source_profile_id = input_profile_id
    );

  delete from private.competition_notification_mutes mute_record
  where mute_record.profile_id = input_profile_id
     or mute_record.opponent_profile_id = input_profile_id;

  update private.account_deletions deletion_record
  set phase = 'token_ready',
      updated_at = decision_time
  where deletion_record.profile_id = input_profile_id
  returning deletion_record.* into deletion_row;

  return pg_catalog.jsonb_build_object(
    'profile_id', deletion_row.profile_id,
    'phase', deletion_row.phase
  );
end;
$$;
