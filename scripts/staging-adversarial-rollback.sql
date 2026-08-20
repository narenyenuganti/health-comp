-- HealthComp staging adversarial verification.
--
-- Run only against the approved staging project, as a privileged database
-- session, after reviewing the exact file at the selected commit. Every test
-- row uses a fixed synthetic identity, every assertion fails closed, and the
-- only transaction containing test writes ends in ROLLBACK. The session then
-- becomes read-only before residue verification and the final receipt. The
-- receipt is deliberately privacy-safe: it contains no identifiers, tokens,
-- digests, or health data.

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';
set local idle_in_transaction_session_timeout = '30s';
set local search_path = pg_catalog, public;

do $preflight$
declare
  fixture_collision_count bigint;
begin
  if not pg_catalog.has_schema_privilege(current_user, 'auth', 'USAGE')
     or not pg_catalog.has_table_privilege(current_user, 'auth.users', 'INSERT')
     or not pg_catalog.has_table_privilege(current_user, 'public.profiles', 'INSERT') then
    raise exception 'healthcomp_staging_adversarial requires a privileged staging database session'
      using errcode = '42501';
  end if;

  if pg_catalog.to_regprocedure(
       'public.claim_competition_invite(bytea)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.submit_attested_score_revision(uuid,uuid,uuid,integer,bigint,timestamptz,text,text,integer,integer,integer,text,text,text,text)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.issue_app_attest_challenge(uuid,text,text)'
     ) is null then
    raise exception 'healthcomp_staging_adversarial required RPC surface is missing'
      using errcode = 'P0001';
  end if;

  select pg_catalog.sum(row_count)
  into fixture_collision_count
  from (
    select pg_catalog.count(*)::bigint as row_count
    from auth.users
    where id = any(array[
      'f1900000-0000-4000-8000-000000000001'::uuid,
      'f1900000-0000-4000-8000-000000000002'::uuid,
      'f1900000-0000-4000-8000-000000000003'::uuid,
      'f1900000-0000-4000-8000-000000000004'::uuid
    ])
       or email like 'healthcomp-staging-adversarial-%@example.invalid'
    union all
    select pg_catalog.count(*)::bigint
    from public.profiles
    where id = any(array[
      'f1910000-0000-4000-8000-000000000001'::uuid,
      'f1910000-0000-4000-8000-000000000002'::uuid,
      'f1910000-0000-4000-8000-000000000003'::uuid,
      'f1910000-0000-4000-8000-000000000004'::uuid
    ])
    union all
    select pg_catalog.count(*)::bigint
    from public.competitions
    where id = any(array[
      'f1920000-0000-4000-8000-000000000001'::uuid,
      'f1920000-0000-4000-8000-000000000002'::uuid,
      'f1920000-0000-4000-8000-000000000003'::uuid,
      'f1920000-0000-4000-8000-000000000004'::uuid
    ])
    union all
    select pg_catalog.count(*)::bigint
    from public.competition_invites
    where id = 'f1930000-0000-4000-8000-000000000001'::uuid
       or token_digest = pg_catalog.decode(pg_catalog.repeat('91', 32), 'hex')
    union all
    select pg_catalog.count(*)::bigint
    from public.device_installations
    where id = 'f1940000-0000-4000-8000-000000000001'::uuid
       or installation_id = 'f1950000-0000-4000-8000-000000000001'::uuid
       or apns_token = pg_catalog.repeat('a1', 32)
    union all
    select pg_catalog.count(*)::bigint
    from public.support_events
    where id = 'f1960000-0000-4000-8000-000000000001'::uuid
    union all
    select pg_catalog.count(*)::bigint
    from public.participant_finalization_attestations
    where id = 'f19a0000-0000-4000-8000-000000000001'::uuid
    union all
    select pg_catalog.count(*)::bigint
    from public.competition_awards
    where id = 'f19a0000-0000-4000-8000-000000000002'::uuid
    union all
    select pg_catalog.count(*)::bigint
    from private.app_attest_keys
    where key_id = pg_catalog.repeat('B', 43) || '='
    union all
    select pg_catalog.count(*)::bigint
    from private.app_attest_challenges
    where id = 'f19b0000-0000-4000-8000-000000000001'::uuid
       or challenge = pg_catalog.decode(pg_catalog.repeat('ac', 32), 'hex')
    union all
    select pg_catalog.count(*)::bigint
    from private.app_attest_submission_grants
    where id = 'f19c0000-0000-4000-8000-000000000001'::uuid
       or challenge_id = 'f19b0000-0000-4000-8000-000000000001'::uuid
  ) fixture_counts;

  if fixture_collision_count <> 0 then
    raise exception 'healthcomp_staging_adversarial synthetic fixture collision'
      using errcode = 'P0001';
  end if;
end;
$preflight$;

create temporary table healthcomp_adversarial_assertions (
  assertion_name text primary key
) on commit drop;

grant select, insert on table pg_temp.healthcomp_adversarial_assertions
  to anon, authenticated;

create temporary table healthcomp_adversarial_values (
  bound_evaluated_at timestamptz not null,
  bound_wire_digest text not null
) on commit drop;

insert into pg_temp.healthcomp_adversarial_values (
  bound_evaluated_at, bound_wire_digest
) values (
  ((current_date - 2)::timestamp + interval '12 hours') at time zone 'UTC',
  pg_catalog.encode(
    private.wire_score_digest_v1(
      'f1920000-0000-4000-8000-000000000002',
      'f1910000-0000-4000-8000-000000000001',
      1::smallint,
      'activeEnergyKilocalories', 'standHours',
      10000, 5000, 12500, 27500,
      'available', 'healthcomp.activity-score.v1', 41
    ),
    'hex'
  )
);

grant select on table pg_temp.healthcomp_adversarial_values
  to authenticated;

create function pg_temp.healthcomp_assert(
  assertion_name text,
  condition boolean
)
returns void
language plpgsql
set search_path = pg_catalog, pg_temp
as $function$
begin
  if condition is distinct from true then
    raise exception 'healthcomp_staging_adversarial assertion failed: %', assertion_name
      using errcode = 'P0001';
  end if;

  insert into pg_temp.healthcomp_adversarial_assertions (assertion_name)
  values (assertion_name);
end;
$function$;

create function pg_temp.healthcomp_assert_zero_or_denied(command text)
returns void
language plpgsql
set search_path = pg_catalog
as $function$
declare
  visible_rows bigint;
begin
  begin
    execute 'select count(*) from (' || command || ') healthcomp_visible_rows'
      into visible_rows;
  exception
    when insufficient_privilege then
      return;
  end;

  if visible_rows <> 0 then
    raise exception 'healthcomp_staging_adversarial unexpectedly returned rows'
      using errcode = 'P0001';
  end if;
end;
$function$;

create function pg_temp.healthcomp_assert_insufficient_privilege(command text)
returns void
language plpgsql
set search_path = pg_catalog
as $function$
declare
  returned_state text;
begin
  begin
    execute command;
  exception
    when others then
      get stacked diagnostics returned_state = returned_sqlstate;
  end;

  if returned_state is distinct from '42501' then
    raise exception 'healthcomp_staging_adversarial expected insufficient_privilege'
      using errcode = 'P0001';
  end if;
end;
$function$;

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values
  (
    'f1900000-0000-4000-8000-000000000001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'healthcomp-staging-adversarial-a@example.invalid', '', now(), now()
  ),
  (
    'f1900000-0000-4000-8000-000000000002',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'healthcomp-staging-adversarial-b@example.invalid', '', now(), now()
  ),
  (
    'f1900000-0000-4000-8000-000000000003',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'healthcomp-staging-adversarial-outsider@example.invalid', '', now(), now()
  ),
  (
    'f1900000-0000-4000-8000-000000000004',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'healthcomp-staging-adversarial-former@example.invalid', '', now(), now()
  );

insert into public.profiles (id, auth_user_id, display_name, state) values
  (
    'f1910000-0000-4000-8000-000000000001',
    'f1900000-0000-4000-8000-000000000001',
    'Synthetic A', 'active'
  ),
  (
    'f1910000-0000-4000-8000-000000000002',
    'f1900000-0000-4000-8000-000000000002',
    'Synthetic B', 'active'
  ),
  (
    'f1910000-0000-4000-8000-000000000003',
    'f1900000-0000-4000-8000-000000000003',
    'Synthetic Outsider', 'active'
  ),
  (
    'f1910000-0000-4000-8000-000000000004',
    'f1900000-0000-4000-8000-000000000004',
    'Synthetic Former', 'active'
  );

insert into public.competitions (
  id, creator_profile_id, time_zone_identifier, start_day,
  scoring_policy_identity, lifecycle, invitation_expires_at,
  best_available_deadline, invite_creation_idempotency_key,
  invite_token_derivation_version
) values
  (
    'f1920000-0000-4000-8000-000000000001',
    'f1910000-0000-4000-8000-000000000001',
    'America/Los_Angeles', null,
    'healthcomp.activity-score.v1', 'pending', now() + interval '2 days',
    null, 'f1980000-0000-4000-8000-000000000001', 1
  ),
  (
    'f1920000-0000-4000-8000-000000000002',
    'f1910000-0000-4000-8000-000000000001',
    'UTC', current_date - 2,
    'healthcomp.activity-score.v1', 'active', now() - interval '3 days',
    now() + interval '6 days', null, 0
  ),
  (
    'f1920000-0000-4000-8000-000000000003',
    'f1910000-0000-4000-8000-000000000001',
    'UTC', current_date - 8,
    'healthcomp.activity-score.v1', 'completed', now() - interval '9 days',
    now() - interval '1 day', null, 0
  ),
  (
    'f1920000-0000-4000-8000-000000000004',
    'f1910000-0000-4000-8000-000000000003',
    'UTC', null,
    'healthcomp.activity-score.v1', 'pending', now() + interval '2 days',
    null, null, 0
  );

insert into public.competition_participants (
  competition_id, profile_id, role, state
) values
  (
    'f1920000-0000-4000-8000-000000000001',
    'f1910000-0000-4000-8000-000000000001',
    'creator', 'accepted'
  ),
  (
    'f1920000-0000-4000-8000-000000000002',
    'f1910000-0000-4000-8000-000000000001',
    'creator', 'accepted'
  ),
  (
    'f1920000-0000-4000-8000-000000000002',
    'f1910000-0000-4000-8000-000000000002',
    'invitee', 'accepted'
  ),
  (
    'f1920000-0000-4000-8000-000000000003',
    'f1910000-0000-4000-8000-000000000001',
    'creator', 'accepted'
  ),
  (
    'f1920000-0000-4000-8000-000000000003',
    'f1910000-0000-4000-8000-000000000004',
    'invitee', 'anonymized'
  ),
  (
    'f1920000-0000-4000-8000-000000000004',
    'f1910000-0000-4000-8000-000000000003',
    'creator', 'accepted'
  );

insert into public.competition_invites (
  id, competition_id, token_digest, expires_at
) values (
  'f1930000-0000-4000-8000-000000000001',
  'f1920000-0000-4000-8000-000000000001',
  pg_catalog.decode(pg_catalog.repeat('91', 32), 'hex'),
  now() + interval '2 days'
);

create function pg_temp.healthcomp_zero_window(
  first_profile uuid,
  second_profile uuid
)
returns jsonb
language sql
stable
set search_path = pg_catalog
as $function$
  select pg_catalog.jsonb_build_object(
    'version', 1,
    'participants', pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'profile_id', first_profile,
        'days', (
          select pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'ordinal', ordinal,
              'status', 'unavailable',
              'reason', 'missing'
            ) order by ordinal
          )
          from pg_catalog.generate_series(1, 7) ordinal
        )
      ),
      pg_catalog.jsonb_build_object(
        'profile_id', second_profile,
        'days', (
          select pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'ordinal', ordinal,
              'status', 'unavailable',
              'reason', 'missing'
            ) order by ordinal
          )
          from pg_catalog.generate_series(1, 7) ordinal
        )
      )
    )
  );
$function$;

insert into public.competition_results (
  competition_id, participant_a_profile_id, participant_b_profile_id,
  participant_a_total_centi_points, participant_b_total_centi_points,
  winner_profile_id, outcome, finalization_basis, completed_at,
  frozen_window, immutable_hash, server_seq
) values (
  'f1920000-0000-4000-8000-000000000003',
  'f1910000-0000-4000-8000-000000000001',
  'f1910000-0000-4000-8000-000000000004',
  0, 0, null, 'tie', 'stable', now(),
  pg_temp.healthcomp_zero_window(
    'f1910000-0000-4000-8000-000000000001',
    'f1910000-0000-4000-8000-000000000004'
  ),
  pg_catalog.decode(pg_catalog.repeat('92', 32), 'hex'),
  1
);

insert into public.participant_finalization_attestations (
  id, competition_id, participant_profile_id, semantic_event_id,
  attestation_version, basis, window_commitment_sha256,
  accepted_revisions, server_seq, attested_at
) values (
  'f19a0000-0000-4000-8000-000000000001',
  'f1920000-0000-4000-8000-000000000003',
  'f1910000-0000-4000-8000-000000000001',
  'f19d0000-0000-4000-8000-000000000001',
  1, 'best_available',
  pg_catalog.decode(pg_catalog.repeat('94', 32), 'hex'),
  array[0, 0, 0, 0, 0, 0, 0]::bigint[], 1, now()
);

insert into public.competition_awards (
  id, competition_id, profile_id, award_type, server_seq, earned_at
) values (
  'f19a0000-0000-4000-8000-000000000002',
  'f1920000-0000-4000-8000-000000000003',
  'f1910000-0000-4000-8000-000000000001',
  'completion', 1, now()
);

insert into public.device_installations (
  id, profile_id, apns_token, environment, state, installation_id
) values (
  'f1940000-0000-4000-8000-000000000001',
  'f1910000-0000-4000-8000-000000000001',
  pg_catalog.repeat('a1', 32), 'sandbox', 'active',
  'f1950000-0000-4000-8000-000000000001'
);

insert into private.app_attest_keys (
  key_id, profile_id, installation_id, public_key_pem, receipt,
  environment, validation_category, bundle_version, sign_count
) values (
  pg_catalog.repeat('B', 43) || '=',
  'f1910000-0000-4000-8000-000000000001',
  'f1950000-0000-4000-8000-000000000001',
  '-----BEGIN PUBLIC KEY-----' || pg_catalog.repeat('B', 96),
  pg_catalog.decode('01', 'hex'),
  'development', 1, '1', 0
);

insert into private.app_attest_challenges (
  id, profile_id, installation_id, requested_key_id, payload_sha256,
  challenge, proof_kind, created_at, expires_at, consumed_at
) values (
  'f19b0000-0000-4000-8000-000000000001',
  'f1910000-0000-4000-8000-000000000001',
  'f1950000-0000-4000-8000-000000000001',
  pg_catalog.repeat('B', 43) || '=',
  pg_catalog.decode(pg_catalog.repeat('ab', 32), 'hex'),
  pg_catalog.decode(pg_catalog.repeat('ac', 32), 'hex'),
  'assertion', pg_catalog.statement_timestamp(),
  pg_catalog.statement_timestamp() + interval '5 minutes',
  pg_catalog.statement_timestamp()
);

insert into private.app_attest_submission_grants (
  id, challenge_id, profile_id, installation_id, key_id, payload_sha256,
  competition_id, semantic_event_id, day_ordinal, client_revision,
  evaluated_at, wire_content_sha256, created_at, expires_at
)
select
  'f19c0000-0000-4000-8000-000000000001',
  'f19b0000-0000-4000-8000-000000000001',
  'f1910000-0000-4000-8000-000000000001',
  'f1950000-0000-4000-8000-000000000001',
  pg_catalog.repeat('B', 43) || '=',
  pg_catalog.decode(pg_catalog.repeat('ab', 32), 'hex'),
  'f1920000-0000-4000-8000-000000000002',
  'f1970000-0000-4000-8000-000000000010',
  1, 41, bound_evaluated_at,
  pg_catalog.decode(bound_wire_digest, 'hex'),
  pg_catalog.statement_timestamp(),
  pg_catalog.statement_timestamp() + interval '2 minutes'
from pg_temp.healthcomp_adversarial_values;

insert into public.support_events (
  id, profile_id, competition_id, kind, code
) values (
  'f1960000-0000-4000-8000-000000000001',
  'f1910000-0000-4000-8000-000000000001',
  'f1920000-0000-4000-8000-000000000001',
  'adversarial_probe', 'synthetic_only'
);

update public.profiles
set auth_user_id = null,
    display_name = 'Former competitor',
    state = 'anonymized',
    anonymized_at = now(),
    updated_at = now()
where id = 'f1910000-0000-4000-8000-000000000004';

delete from auth.users
where id = 'f1900000-0000-4000-8000-000000000004';

set local role anon;
set local request.jwt.claims = '{"role":"anon"}';

select pg_temp.healthcomp_assert_zero_or_denied(
  'select id from public.profiles where id in (
     ''f1910000-0000-4000-8000-000000000001'',
     ''f1910000-0000-4000-8000-000000000002'',
     ''f1910000-0000-4000-8000-000000000003'',
     ''f1910000-0000-4000-8000-000000000004''
   )'
);
select pg_temp.healthcomp_assert_zero_or_denied(
  'select id from public.competitions where id in (
     ''f1920000-0000-4000-8000-000000000001'',
     ''f1920000-0000-4000-8000-000000000002'',
     ''f1920000-0000-4000-8000-000000000003'',
     ''f1920000-0000-4000-8000-000000000004''
   )'
);
select pg_temp.healthcomp_assert_zero_or_denied(
  'select competition_id from public.competition_participants
   where competition_id in (
     ''f1920000-0000-4000-8000-000000000001'',
     ''f1920000-0000-4000-8000-000000000002'',
     ''f1920000-0000-4000-8000-000000000003'',
     ''f1920000-0000-4000-8000-000000000004''
   )'
);
select pg_temp.healthcomp_assert_zero_or_denied(
  'select competition_id from public.competition_invites
   where competition_id = ''f1920000-0000-4000-8000-000000000001'''
);
select pg_temp.healthcomp_assert_zero_or_denied(
  'select competition_id from public.competition_change_log
   where competition_id in (
     ''f1920000-0000-4000-8000-000000000001'',
     ''f1920000-0000-4000-8000-000000000002'',
     ''f1920000-0000-4000-8000-000000000003'',
     ''f1920000-0000-4000-8000-000000000004''
   )'
);
select pg_temp.healthcomp_assert_zero_or_denied(
  'select competition_id from public.daily_score_revisions
   where competition_id = ''f1920000-0000-4000-8000-000000000002'''
);
select pg_temp.healthcomp_assert_zero_or_denied(
  'select competition_id from public.participant_finalization_attestations
   where competition_id in (
     ''f1920000-0000-4000-8000-000000000001'',
     ''f1920000-0000-4000-8000-000000000002'',
     ''f1920000-0000-4000-8000-000000000003'',
     ''f1920000-0000-4000-8000-000000000004''
   )'
);
select pg_temp.healthcomp_assert_zero_or_denied(
  'select competition_id from public.competition_results
   where competition_id = ''f1920000-0000-4000-8000-000000000003'''
);
select pg_temp.healthcomp_assert_zero_or_denied(
  'select competition_id from public.competition_awards
   where competition_id in (
     ''f1920000-0000-4000-8000-000000000001'',
     ''f1920000-0000-4000-8000-000000000002'',
     ''f1920000-0000-4000-8000-000000000003'',
     ''f1920000-0000-4000-8000-000000000004''
   )'
);
select pg_temp.healthcomp_assert_zero_or_denied(
  'select id from public.device_installations
   where profile_id = ''f1910000-0000-4000-8000-000000000001'''
);
select pg_temp.healthcomp_assert_zero_or_denied(
  'select id from public.support_events
   where competition_id = ''f1920000-0000-4000-8000-000000000001'''
);
select pg_temp.healthcomp_assert('anonymous_cross_account_reads', true);

reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"f1900000-0000-4000-8000-000000000002","role":"authenticated"}';

do $same_claimant$
declare
  first_claim uuid;
  second_claim uuid;
begin
  first_claim := public.claim_competition_invite(
    pg_catalog.decode(pg_catalog.repeat('91', 32), 'hex')
  );
  second_claim := public.claim_competition_invite(
    pg_catalog.decode(pg_catalog.repeat('91', 32), 'hex')
  );

  if first_claim <> 'f1920000-0000-4000-8000-000000000001'::uuid
     or second_claim <> first_claim
     or (
       select pg_catalog.count(*)
       from public.competition_participants
       where competition_id = first_claim
     ) <> 2 then
    raise exception 'healthcomp_staging_adversarial invite replay was not idempotent'
      using errcode = 'P0001';
  end if;

  perform pg_temp.healthcomp_assert('same_claimant_replay_is_idempotent', true);
end;
$same_claimant$;

set local request.jwt.claims =
  '{"sub":"f1900000-0000-4000-8000-000000000003","role":"authenticated"}';

do $different_claimant$
declare
  returned_state text;
  returned_message text;
begin
  begin
    perform public.claim_competition_invite(
      pg_catalog.decode(pg_catalog.repeat('91', 32), 'hex')
    );
  exception
    when others then
      get stacked diagnostics
        returned_state = returned_sqlstate,
        returned_message = message_text;
  end;

  if returned_state is distinct from 'P0001'
     or returned_message is distinct from 'invite_unavailable' then
    raise exception 'healthcomp_staging_adversarial consumed invite leaked or replayed'
      using errcode = 'P0001';
  end if;

  perform pg_temp.healthcomp_assert('different_claimant_replay_is_denied', true);
end;
$different_claimant$;

reset role;
set constraints all immediate;

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"f1900000-0000-4000-8000-000000000001","role":"authenticated"}';

do $participant_scope$
begin
  if (
    select pg_catalog.count(*)
    from public.competitions
    where id = any(array[
      'f1920000-0000-4000-8000-000000000001'::uuid,
      'f1920000-0000-4000-8000-000000000002'::uuid,
      'f1920000-0000-4000-8000-000000000003'::uuid,
      'f1920000-0000-4000-8000-000000000004'::uuid
    ])
  ) <> 3
  or exists (
    select 1
    from public.competitions
    where id = 'f1920000-0000-4000-8000-000000000004'::uuid
  )
  or (
    select pg_catalog.count(*)
    from public.competition_participants
    where competition_id = any(array[
      'f1920000-0000-4000-8000-000000000001'::uuid,
      'f1920000-0000-4000-8000-000000000002'::uuid,
      'f1920000-0000-4000-8000-000000000003'::uuid,
      'f1920000-0000-4000-8000-000000000004'::uuid
    ])
  ) <> 6
  or exists (
    select 1
    from public.competition_participants
    where competition_id = 'f1920000-0000-4000-8000-000000000004'::uuid
  )
  or (
    select pg_catalog.count(*)
    from public.competition_results
    where competition_id = any(array[
      'f1920000-0000-4000-8000-000000000003'::uuid,
      'f1920000-0000-4000-8000-000000000004'::uuid
    ])
  ) <> 1
  or (
    select pg_catalog.count(*)
    from public.profiles
    where id = any(array[
      'f1910000-0000-4000-8000-000000000001'::uuid,
      'f1910000-0000-4000-8000-000000000002'::uuid,
      'f1910000-0000-4000-8000-000000000003'::uuid,
      'f1910000-0000-4000-8000-000000000004'::uuid
    ])
  ) <> 3
  or exists (
    select 1
    from public.profiles
    where id = 'f1910000-0000-4000-8000-000000000003'::uuid
  )
  or not exists (
    select 1
    from public.profiles
    where id = 'f1910000-0000-4000-8000-000000000004'::uuid
      and display_name = 'Former competitor'
  ) then
    raise exception 'healthcomp_staging_adversarial participant scope leaked'
      using errcode = 'P0001';
  end if;

  perform pg_temp.healthcomp_assert('participant_scope_isolation', true);
end;
$participant_scope$;

set local request.jwt.claims =
  '{"sub":"f1900000-0000-4000-8000-000000000003","role":"authenticated"}';

do $outsider_scope$
begin
  if (
    select pg_catalog.count(*)
    from public.competitions
    where id = any(array[
      'f1920000-0000-4000-8000-000000000001'::uuid,
      'f1920000-0000-4000-8000-000000000002'::uuid,
      'f1920000-0000-4000-8000-000000000003'::uuid,
      'f1920000-0000-4000-8000-000000000004'::uuid
    ])
  ) <> 1
  or not exists (
    select 1
    from public.competitions
    where id = 'f1920000-0000-4000-8000-000000000004'::uuid
  )
  or (
    select pg_catalog.count(*)
    from public.competition_participants
    where competition_id = any(array[
      'f1920000-0000-4000-8000-000000000001'::uuid,
      'f1920000-0000-4000-8000-000000000002'::uuid,
      'f1920000-0000-4000-8000-000000000003'::uuid,
      'f1920000-0000-4000-8000-000000000004'::uuid
    ])
  ) <> 1
  or exists (
    select 1
    from public.competition_results
    where competition_id = any(array[
      'f1920000-0000-4000-8000-000000000003'::uuid,
      'f1920000-0000-4000-8000-000000000004'::uuid
    ])
  )
  or (
    select pg_catalog.count(*)
    from public.profiles
    where id = any(array[
      'f1910000-0000-4000-8000-000000000001'::uuid,
      'f1910000-0000-4000-8000-000000000002'::uuid,
      'f1910000-0000-4000-8000-000000000003'::uuid,
      'f1910000-0000-4000-8000-000000000004'::uuid
    ])
  ) <> 1 then
    raise exception 'healthcomp_staging_adversarial outsider scope leaked'
      using errcode = 'P0001';
  end if;

  perform pg_temp.healthcomp_assert('outsider_scope_isolation', true);
end;
$outsider_scope$;

set local request.jwt.claims =
  '{"sub":"f1900000-0000-4000-8000-000000000004","role":"authenticated"}';

do $stale_profile$
begin
  if exists (
    select 1
    from public.profiles
    where id = any(array[
      'f1910000-0000-4000-8000-000000000001'::uuid,
      'f1910000-0000-4000-8000-000000000004'::uuid
    ])
  )
  or exists (
    select 1
    from public.competitions
    where id = 'f1920000-0000-4000-8000-000000000003'::uuid
  )
  or exists (
    select 1
    from public.competition_participants
    where competition_id = 'f1920000-0000-4000-8000-000000000003'::uuid
  )
  or exists (
    select 1
    from public.competition_results
    where competition_id = 'f1920000-0000-4000-8000-000000000003'::uuid
  ) then
    raise exception 'healthcomp_staging_adversarial stale deleted profile retained access'
      using errcode = 'P0001';
  end if;

  perform pg_temp.healthcomp_assert('stale_deleted_profile_isolation', true);
end;
$stale_profile$;

set local request.jwt.claims =
  '{"sub":"f1900000-0000-4000-8000-000000000001","role":"authenticated"}';

select pg_temp.healthcomp_assert_insufficient_privilege(
  'select token_digest from public.competition_invites
   where id = ''f1930000-0000-4000-8000-000000000001'''
);
select pg_temp.healthcomp_assert_insufficient_privilege(
  'select payload_snapshot from public.competition_change_log
   where competition_id = ''f1920000-0000-4000-8000-000000000001'''
);
select pg_temp.healthcomp_assert_insufficient_privilege(
  'select code from public.support_events
   where id = ''f1960000-0000-4000-8000-000000000001'''
);
select pg_temp.healthcomp_assert_insufficient_privilege(
  'select auth_user_id from public.profiles
   where id = ''f1910000-0000-4000-8000-000000000001'''
);
select pg_temp.healthcomp_assert_insufficient_privilege(
  'select apns_token from public.device_installations
   where id = ''f1940000-0000-4000-8000-000000000001'''
);
select pg_temp.healthcomp_assert('raw_secret_table_denial', true);

select pg_temp.healthcomp_assert_insufficient_privilege(
  'update public.competitions
   set lifecycle = ''cancelled''
   where id = ''f1920000-0000-4000-8000-000000000001'''
);
select pg_temp.healthcomp_assert_insufficient_privilege(
  'insert into public.competition_invites (
     competition_id, token_digest, expires_at
   ) values (
     ''f1920000-0000-4000-8000-000000000004'',
     decode(repeat(''93'', 32), ''hex''),
     now() + interval ''1 day''
   )'
);
select pg_temp.healthcomp_assert_insufficient_privilege(
  'insert into public.competition_change_log (
     competition_id, server_seq, change_kind, entity_id
   ) values (
     ''f1920000-0000-4000-8000-000000000001'', 9999,
     ''client_injected'', ''f1910000-0000-4000-8000-000000000001''
   )'
);
select pg_temp.healthcomp_assert_insufficient_privilege(
  'insert into public.support_events (
     profile_id, competition_id, kind, code
   ) values (
     ''f1910000-0000-4000-8000-000000000001'',
     ''f1920000-0000-4000-8000-000000000001'',
     ''client'', ''injected''
   )'
);
select pg_temp.healthcomp_assert('direct_mutation_denial', true);

do $modified_score$
declare
  returned_state text;
  returned_message text;
begin
  if pg_catalog.has_function_privilege(
       'authenticated',
       'public.submit_score_revision(uuid,uuid,integer,bigint,timestamptz,text,text,integer,integer,integer,text,text,text)',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'authenticated',
       'public.submit_score_revision(uuid,uuid,integer,bigint,timestamptz,text,text,integer,integer,integer,text,text)',
       'EXECUTE'
     ) then
    raise exception 'healthcomp_staging_adversarial legacy score RPC is exposed'
      using errcode = 'P0001';
  end if;

  begin
    perform public.submit_attested_score_revision(
      'f1990000-0000-4000-8000-000000000001',
      'f1920000-0000-4000-8000-000000000002',
      'f1970000-0000-4000-8000-000000000001',
      1,
      1,
      ((current_date - 2)::timestamp + interval '12 hours') at time zone 'UTC',
      'activeEnergyKilocalories',
      'standHours',
      20000, 20000, 20000,
      'available',
      'healthcomp.activity-score.v1',
      pg_catalog.repeat('ab', 32),
      pg_catalog.repeat('cd', 32)
    );
  exception
    when others then
      get stacked diagnostics
        returned_state = returned_sqlstate,
        returned_message = message_text;
  end;

  if returned_state is distinct from 'P0001'
     or returned_message is distinct from 'app_attest_grant_unavailable' then
    raise exception 'healthcomp_staging_adversarial modified score bypassed App Attest'
      using errcode = 'P0001';
  end if;

  perform pg_temp.healthcomp_assert('modified_score_without_grant_is_denied', true);
end;
$modified_score$;

do $bound_app_attest_score$
declare
  returned_state text;
  returned_message text;
begin
  begin
    perform public.submit_attested_score_revision(
      'f19c0000-0000-4000-8000-000000000001',
      'f1920000-0000-4000-8000-000000000002',
      'f1970000-0000-4000-8000-000000000010',
      1,
      41,
      (select bound_evaluated_at
       from pg_temp.healthcomp_adversarial_values),
      'activeEnergyKilocalories',
      'standHours',
      10000, 5000, 12500,
      'available',
      'healthcomp.activity-score.v1',
      pg_catalog.repeat('ad', 32),
      (select bound_wire_digest
       from pg_temp.healthcomp_adversarial_values)
    );
  exception
    when others then
      get stacked diagnostics
        returned_state = returned_sqlstate,
        returned_message = message_text;
  end;

  if returned_state is distinct from 'P0001'
     or returned_message is distinct from 'app_attest_grant_unavailable' then
    raise exception 'healthcomp_staging_adversarial grant binding accepted a modified payload'
      using errcode = 'P0001';
  end if;

  returned_state := null;
  returned_message := null;

  begin
    perform public.submit_attested_score_revision(
      'f19c0000-0000-4000-8000-000000000001',
      'f1920000-0000-4000-8000-000000000002',
      'f1970000-0000-4000-8000-000000000010',
      1,
      41,
      (select bound_evaluated_at
       from pg_temp.healthcomp_adversarial_values),
      'activeEnergyKilocalories',
      'standHours',
      10001, 5000, 12500,
      'available',
      'healthcomp.activity-score.v1',
      pg_catalog.repeat('ab', 32),
      (select bound_wire_digest
       from pg_temp.healthcomp_adversarial_values)
    );
  exception
    when others then
      get stacked diagnostics
        returned_state = returned_sqlstate,
        returned_message = message_text;
  end;

  if returned_state is distinct from '22023'
     or returned_message is distinct from 'wire_digest_mismatch' then
    raise exception 'healthcomp_staging_adversarial bound score content was accepted'
      using errcode = 'P0001';
  end if;
end;
$bound_app_attest_score$;

reset role;

do $bound_app_attest_residue$
begin
  if exists (
    select 1
    from public.daily_score_revisions
    where competition_id = 'f1920000-0000-4000-8000-000000000002'::uuid
      and participant_profile_id = 'f1910000-0000-4000-8000-000000000001'::uuid
      and (
        semantic_event_id = 'f1970000-0000-4000-8000-000000000010'::text
        or client_revision = 41
      )
  )
  or not exists (
    select 1
    from private.app_attest_submission_grants
    where id = 'f19c0000-0000-4000-8000-000000000001'::uuid
      and consumed_at is null
  ) then
    raise exception 'healthcomp_staging_adversarial rejected score changed bound state'
      using errcode = 'P0001';
  end if;

  perform pg_temp.healthcomp_assert(
    'bound_app_attest_score_tampering_is_denied',
    true
  );
end;
$bound_app_attest_residue$;

set local request.jwt.claims =
  '{"sub":"f1900000-0000-4000-8000-000000000001","role":"authenticated"}';

do $score_contracts$
declare
  response jsonb;
  expected_digest text;
  evaluated_day_one timestamptz :=
    ((current_date - 2)::timestamp + interval '12 hours') at time zone 'UTC';
  evaluated_day_two timestamptz :=
    ((current_date - 1)::timestamp + interval '12 hours') at time zone 'UTC';
  evaluated_day_three timestamptz :=
    (current_date::timestamp + interval '12 hours') at time zone 'UTC';
begin
  expected_digest := pg_catalog.encode(
    private.wire_score_digest_v1(
      'f1920000-0000-4000-8000-000000000002',
      'f1910000-0000-4000-8000-000000000001',
      1::smallint,
      'activeEnergyKilocalories', 'standHours',
      10000, 5000, 12500, 27500,
      'available', 'healthcomp.activity-score.v1', 1
    ),
    'hex'
  );
  response := public.submit_score_revision(
    'f1920000-0000-4000-8000-000000000002',
    'f1970000-0000-4000-8000-000000000002',
    1, 1, evaluated_day_one,
    'activeEnergyKilocalories', 'standHours',
    10000, 5000, 12500,
    'available', 'healthcomp.activity-score.v1', expected_digest
  );
  if response->>'disposition' <> 'appended' then
    raise exception 'healthcomp_staging_adversarial score fixture did not append'
      using errcode = 'P0001';
  end if;

  expected_digest := pg_catalog.encode(
    private.wire_score_digest_v1(
      'f1920000-0000-4000-8000-000000000002',
      'f1910000-0000-4000-8000-000000000001',
      1::smallint,
      'activeEnergyKilocalories', 'standHours',
      10001, 5000, 12500, 27501,
      'available', 'healthcomp.activity-score.v1', 1
    ),
    'hex'
  );
  response := public.submit_score_revision(
    'f1920000-0000-4000-8000-000000000002',
    'f1970000-0000-4000-8000-000000000002',
    1, 1, evaluated_day_one,
    'activeEnergyKilocalories', 'standHours',
    10001, 5000, 12500,
    'available', 'healthcomp.activity-score.v1', expected_digest
  );
  if response->>'disposition' <> 'rejected'
     or response->>'code' <> 'divergent_duplicate'
     or (
       select pg_catalog.count(*)
       from public.daily_score_revisions
       where competition_id = 'f1920000-0000-4000-8000-000000000002'
         and participant_profile_id = 'f1910000-0000-4000-8000-000000000001'
     ) <> 1 then
    raise exception 'healthcomp_staging_adversarial divergent_duplicate was not rejected'
      using errcode = 'P0001';
  end if;
  perform pg_temp.healthcomp_assert('divergent_duplicate_is_rejected', true);

  expected_digest := pg_catalog.encode(
    private.wire_score_digest_v1(
      'f1920000-0000-4000-8000-000000000002',
      'f1910000-0000-4000-8000-000000000001',
      2::smallint,
      'activeEnergyKilocalories', 'standHours',
      0, 0, 0, 0,
      'available', 'healthcomp.activity-score.v1', 3
    ),
    'hex'
  );
  response := public.submit_score_revision(
    'f1920000-0000-4000-8000-000000000002',
    'f1970000-0000-4000-8000-000000000003',
    2, 3, evaluated_day_two,
    'activeEnergyKilocalories', 'standHours',
    0, 0, 0,
    'available', 'healthcomp.activity-score.v1', expected_digest
  );
  if response->>'disposition' <> 'appended' then
    raise exception 'healthcomp_staging_adversarial higher revision did not append'
      using errcode = 'P0001';
  end if;

  expected_digest := pg_catalog.encode(
    private.wire_score_digest_v1(
      'f1920000-0000-4000-8000-000000000002',
      'f1910000-0000-4000-8000-000000000001',
      3::smallint,
      'activeEnergyKilocalories', 'standHours',
      0, 0, 0, 0,
      'available', 'healthcomp.activity-score.v1', 2
    ),
    'hex'
  );
  response := public.submit_score_revision(
    'f1920000-0000-4000-8000-000000000002',
    'f1970000-0000-4000-8000-000000000004',
    3, 2, evaluated_day_three,
    'activeEnergyKilocalories', 'standHours',
    0, 0, 0,
    'available', 'healthcomp.activity-score.v1', expected_digest
  );
  if response->>'disposition' <> 'rejected'
     or response->>'code' <> 'revision_regression'
     or (
       select pg_catalog.count(*)
       from public.daily_score_revisions
       where competition_id = 'f1920000-0000-4000-8000-000000000002'
         and participant_profile_id = 'f1910000-0000-4000-8000-000000000001'
     ) <> 2 then
    raise exception 'healthcomp_staging_adversarial revision_regression was not rejected'
      using errcode = 'P0001';
  end if;
  perform pg_temp.healthcomp_assert('revision_regression_is_rejected', true);
end;
$score_contracts$;

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"f1900000-0000-4000-8000-000000000001","role":"authenticated"}';

do $participant_cross_table_visibility$
begin
  if (
    select pg_catalog.count(*)
    from public.daily_score_revisions
    where competition_id = 'f1920000-0000-4000-8000-000000000002'::uuid
      and participant_profile_id = 'f1910000-0000-4000-8000-000000000001'::uuid
  ) <> 2
  or (
    select pg_catalog.count(*)
    from public.participant_finalization_attestations
    where id = 'f19a0000-0000-4000-8000-000000000001'::uuid
  ) <> 1
  or (
    select pg_catalog.count(*)
    from public.competition_awards
    where id = 'f19a0000-0000-4000-8000-000000000002'::uuid
  ) <> 1 then
    raise exception 'healthcomp_staging_adversarial participant cross-table visibility failed'
      using errcode = 'P0001';
  end if;
end;
$participant_cross_table_visibility$;

set local request.jwt.claims =
  '{"sub":"f1900000-0000-4000-8000-000000000003","role":"authenticated"}';

select pg_temp.healthcomp_assert_zero_or_denied(
  'select id from public.device_installations
   where id = ''f1940000-0000-4000-8000-000000000001'''
);
select pg_temp.healthcomp_assert_zero_or_denied(
  'select id from public.daily_score_revisions
   where competition_id = ''f1920000-0000-4000-8000-000000000002''
     and participant_profile_id = ''f1910000-0000-4000-8000-000000000001'''
);
select pg_temp.healthcomp_assert_zero_or_denied(
  'select id from public.participant_finalization_attestations
   where id = ''f19a0000-0000-4000-8000-000000000001'''
);
select pg_temp.healthcomp_assert_zero_or_denied(
  'select id from public.competition_awards
   where id = ''f19a0000-0000-4000-8000-000000000002'''
);
select pg_temp.healthcomp_assert('cross_table_authenticated_isolation', true);

set local request.jwt.claims =
  '{"sub":"f1900000-0000-4000-8000-000000000001","role":"authenticated"}';

select pg_temp.healthcomp_assert_insufficient_privilege(
  'update public.competition_results
   set finalization_basis = ''best_available''
   where competition_id = ''f1920000-0000-4000-8000-000000000003'''
);
select pg_temp.healthcomp_assert('result_rewrite_is_denied', true);

do $unregistered_installation$
declare
  returned_state text;
  returned_message text;
begin
  begin
    perform public.issue_app_attest_challenge(
      'f1950000-0000-4000-8000-000000000099',
      pg_catalog.repeat('ef', 32),
      pg_catalog.repeat('A', 43) || '='
    );
  exception
    when others then
      get stacked diagnostics
        returned_state = returned_sqlstate,
        returned_message = message_text;
  end;

  if returned_state is distinct from 'P0002'
     or returned_message is distinct from 'app_attest_installation_unavailable' then
    raise exception 'healthcomp_staging_adversarial unregistered installation was accepted'
      using errcode = 'P0001';
  end if;

  perform pg_temp.healthcomp_assert('unregistered_installation_is_denied', true);
end;
$unregistered_installation$;

reset role;

do $assertion_count$
begin
  if (
    select pg_catalog.count(*)
    from pg_temp.healthcomp_adversarial_assertions
  ) <> 15 then
    raise exception 'healthcomp_staging_adversarial assertion matrix incomplete'
      using errcode = 'P0001';
  end if;
end;
$assertion_count$;

rollback;

set default_transaction_read_only = on;
set statement_timeout = '30s';
set lock_timeout = '5s';
set idle_in_transaction_session_timeout = '30s';

do $zero_residue$
declare
  synthetic_rows_remaining bigint;
begin
  select pg_catalog.sum(row_count)
  into synthetic_rows_remaining
  from (
    select pg_catalog.count(*)::bigint as row_count
    from auth.users
    where id = any(array[
      'f1900000-0000-4000-8000-000000000001'::uuid,
      'f1900000-0000-4000-8000-000000000002'::uuid,
      'f1900000-0000-4000-8000-000000000003'::uuid,
      'f1900000-0000-4000-8000-000000000004'::uuid
    ])
       or email like 'healthcomp-staging-adversarial-%@example.invalid'
    union all
    select pg_catalog.count(*)::bigint
    from public.profiles
    where id = any(array[
      'f1910000-0000-4000-8000-000000000001'::uuid,
      'f1910000-0000-4000-8000-000000000002'::uuid,
      'f1910000-0000-4000-8000-000000000003'::uuid,
      'f1910000-0000-4000-8000-000000000004'::uuid
    ])
    union all
    select pg_catalog.count(*)::bigint
    from public.competitions
    where id = any(array[
      'f1920000-0000-4000-8000-000000000001'::uuid,
      'f1920000-0000-4000-8000-000000000002'::uuid,
      'f1920000-0000-4000-8000-000000000003'::uuid,
      'f1920000-0000-4000-8000-000000000004'::uuid
    ])
    union all
    select pg_catalog.count(*)::bigint
    from public.competition_participants
    where competition_id = any(array[
      'f1920000-0000-4000-8000-000000000001'::uuid,
      'f1920000-0000-4000-8000-000000000002'::uuid,
      'f1920000-0000-4000-8000-000000000003'::uuid,
      'f1920000-0000-4000-8000-000000000004'::uuid
    ])
    union all
    select pg_catalog.count(*)::bigint
    from public.competition_invites
    where id = 'f1930000-0000-4000-8000-000000000001'::uuid
       or competition_id = 'f1920000-0000-4000-8000-000000000001'::uuid
    union all
    select pg_catalog.count(*)::bigint
    from public.competition_change_log
    where competition_id = any(array[
      'f1920000-0000-4000-8000-000000000001'::uuid,
      'f1920000-0000-4000-8000-000000000002'::uuid,
      'f1920000-0000-4000-8000-000000000003'::uuid,
      'f1920000-0000-4000-8000-000000000004'::uuid
    ])
    union all
    select pg_catalog.count(*)::bigint
    from public.daily_score_revisions
    where competition_id = 'f1920000-0000-4000-8000-000000000002'::uuid
    union all
    select pg_catalog.count(*)::bigint
    from public.competition_results
    where competition_id = 'f1920000-0000-4000-8000-000000000003'::uuid
    union all
    select pg_catalog.count(*)::bigint
    from public.participant_finalization_attestations
    where id = 'f19a0000-0000-4000-8000-000000000001'::uuid
       or competition_id = 'f1920000-0000-4000-8000-000000000003'::uuid
    union all
    select pg_catalog.count(*)::bigint
    from public.competition_awards
    where id = 'f19a0000-0000-4000-8000-000000000002'::uuid
       or competition_id = 'f1920000-0000-4000-8000-000000000003'::uuid
    union all
    select pg_catalog.count(*)::bigint
    from public.device_installations
    where id = 'f1940000-0000-4000-8000-000000000001'::uuid
       or installation_id = 'f1950000-0000-4000-8000-000000000001'::uuid
       or apns_token = pg_catalog.repeat('a1', 32)
    union all
    select pg_catalog.count(*)::bigint
    from public.support_events
    where id = 'f1960000-0000-4000-8000-000000000001'::uuid
    union all
    select pg_catalog.count(*)::bigint
    from private.app_attest_keys
    where key_id = pg_catalog.repeat('B', 43) || '='
    union all
    select pg_catalog.count(*)::bigint
    from private.app_attest_challenges
    where id = 'f19b0000-0000-4000-8000-000000000001'::uuid
       or challenge = pg_catalog.decode(pg_catalog.repeat('ac', 32), 'hex')
    union all
    select pg_catalog.count(*)::bigint
    from private.app_attest_submission_grants
    where id = 'f19c0000-0000-4000-8000-000000000001'::uuid
       or challenge_id = 'f19b0000-0000-4000-8000-000000000001'::uuid
  ) residue_counts;

  if synthetic_rows_remaining <> 0 then
    raise exception 'healthcomp_staging_adversarial rollback left synthetic rows'
      using errcode = 'P0001';
  end if;
end;
$zero_residue$;

select pg_catalog.jsonb_build_object(
  'verification', 'healthcomp_staging_adversarial_v1',
  'status', 'pass',
  'assertionsPassed', 15,
  'syntheticRowsRemaining', 0,
  'privateValuesReturned', false,
  'transactionOutcome', 'rolled_back'
) as healthcomp_staging_adversarial_receipt;
