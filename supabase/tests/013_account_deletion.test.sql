begin;

set local role postgres;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(72);

select has_table(
  'private', 'account_deletions',
  'account deletion progress is durable outside the exposed schema'
);
select hasnt_table(
  'public', 'account_deletions',
  'account deletion progress has no public Data API table'
);
select has_function(
  'public', 'begin_account_deletion', array['uuid'],
  'the server can durably prepare account deletion'
);
select has_function(
  'public', 'store_account_deletion_apple_token', array['uuid', 'text'],
  'the server can escrow a revocation token in Vault'
);
select has_function(
  'public', 'load_account_deletion_apple_token', array['uuid'],
  'the server can resume Apple revocation after a crash'
);
select has_function(
  'public', 'mark_account_deletion_apple_revoked', array['uuid'],
  'the server records confirmed Apple revocation'
);
select has_function(
  'public', 'anonymize_account_deletion', array['uuid'],
  'the server anonymizes shared history before auth deletion'
);
select has_function(
  'public', 'complete_account_deletion', array['uuid'],
  'the server confirms that the auth identity is gone'
);
select is((
  select count(*)::bigint
  from information_schema.role_table_grants grant_row
  where grant_row.table_schema = 'private'
    and grant_row.table_name = 'account_deletions'
    and grant_row.grantee in ('anon', 'authenticated', 'service_role')
), 0::bigint, 'API roles have no broad deletion-table privileges');
select is((
  select count(*)::bigint
  from information_schema.routine_privileges privilege_row
  where privilege_row.specific_schema = 'public'
    and privilege_row.routine_name in (
      'begin_account_deletion',
      'store_account_deletion_apple_token',
      'load_account_deletion_apple_token',
      'mark_account_deletion_apple_revoked',
      'anonymize_account_deletion',
      'complete_account_deletion'
    )
    and privilege_row.grantee in ('PUBLIC', 'anon', 'authenticated')
), 0::bigint, 'only the trusted service worker may execute deletion phases');

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values
  (
    'd1000000-0000-4000-8000-000000000001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'delete-alice@example.invalid', '',
    now(), now()
  ),
  (
    'd1000000-0000-4000-8000-000000000002',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'delete-bob@example.invalid', '',
    now(), now()
  );

insert into auth.identities (
  id, provider_id, user_id, identity_data, provider,
  last_sign_in_at, created_at, updated_at
) values
  (
    'd1500000-0000-4000-8000-000000000001',
    'apple-delete-alice',
    'd1000000-0000-4000-8000-000000000001',
    '{"sub":"apple-delete-alice","email":"delete-alice@example.invalid"}',
    'apple', now(), now(), now()
  ),
  (
    'd1500000-0000-4000-8000-000000000002',
    'apple-delete-bob',
    'd1000000-0000-4000-8000-000000000002',
    '{"sub":"apple-delete-bob","email":"delete-bob@example.invalid"}',
    'apple', now(), now(), now()
  );

insert into public.profiles (
  id, auth_user_id, display_name, state
) values
  (
    'd2000000-0000-4000-8000-000000000001',
    'd1000000-0000-4000-8000-000000000001',
    'Alice Delete', 'active'
  ),
  (
    'd2000000-0000-4000-8000-000000000002',
    'd1000000-0000-4000-8000-000000000002',
    'Bob Keeper', 'active'
  );

select throws_ok(
  $$
    insert into private.account_deletions (
      profile_id, auth_user_id, apple_provider_id, phase
    ) values (
      'd2000000-0000-4000-8000-000000000002',
      'd1000000-0000-4000-8000-000000000002',
      null,
      'prepared'
    )
  $$,
  '23514',
  'new row for relation "account_deletions" violates check constraint "account_deletions_identity_shape_check"',
  'an in-progress deletion cannot omit its Apple provider identity'
);
delete from private.account_deletions deletion_row
where deletion_row.profile_id = 'd2000000-0000-4000-8000-000000000002';

insert into public.competitions (
  id, creator_profile_id, time_zone_identifier, start_day,
  scoring_policy_identity, lifecycle, invitation_expires_at,
  best_available_deadline
) values
  (
    'd3000000-0000-4000-8000-000000000001',
    'd2000000-0000-4000-8000-000000000001',
    null, null, 'healthcomp.activity-score.v1', 'pending',
    now() + interval '1 day', null
  ),
  (
    'd3000000-0000-4000-8000-000000000002',
    'd2000000-0000-4000-8000-000000000001',
    'UTC', current_date - 2, 'healthcomp.activity-score.v1', 'active',
    now() - interval '3 days', now() + interval '5 days'
  ),
  (
    'd3000000-0000-4000-8000-000000000003',
    'd2000000-0000-4000-8000-000000000001',
    'UTC', current_date - 20, 'healthcomp.activity-score.v1', 'completed',
    now() - interval '21 days', now() - interval '10 days'
  );

insert into public.competition_participants (
  competition_id, profile_id, role, state
) values
  (
    'd3000000-0000-4000-8000-000000000001',
    'd2000000-0000-4000-8000-000000000001',
    'creator', 'accepted'
  ),
  (
    'd3000000-0000-4000-8000-000000000002',
    'd2000000-0000-4000-8000-000000000001',
    'creator', 'accepted'
  ),
  (
    'd3000000-0000-4000-8000-000000000002',
    'd2000000-0000-4000-8000-000000000002',
    'invitee', 'accepted'
  ),
  (
    'd3000000-0000-4000-8000-000000000003',
    'd2000000-0000-4000-8000-000000000001',
    'creator', 'accepted'
  ),
  (
    'd3000000-0000-4000-8000-000000000003',
    'd2000000-0000-4000-8000-000000000002',
    'invitee', 'accepted'
  );

set constraints all immediate;

insert into public.competition_invites (
  id, competition_id, token_digest, expires_at
) values (
  'd4000000-0000-4000-8000-000000000001',
  'd3000000-0000-4000-8000-000000000001',
  pg_catalog.decode(pg_catalog.repeat('a1', 32), 'hex'),
  now() + interval '12 hours'
);

insert into public.device_installations (
  id, profile_id, installation_id, apns_token, environment, state
) values
  (
    'd5000000-0000-4000-8000-000000000001',
    'd2000000-0000-4000-8000-000000000001',
    'd5000000-0000-4000-8000-000000000001',
    pg_catalog.repeat('ab', 32), 'sandbox', 'active'
  ),
  (
    'd5000000-0000-4000-8000-000000000002',
    'd2000000-0000-4000-8000-000000000002',
    'd5000000-0000-4000-8000-000000000002',
    pg_catalog.repeat('cd', 32), 'sandbox', 'active'
  );

insert into private.competition_notification_mutes (
  profile_id, opponent_profile_id
) values
  (
    'd2000000-0000-4000-8000-000000000001',
    'd2000000-0000-4000-8000-000000000002'
  ),
  (
    'd2000000-0000-4000-8000-000000000002',
    'd2000000-0000-4000-8000-000000000001'
  );

insert into private.competition_notification_work (
  semantic_id, competition_id, server_seq, kind,
  recipient_profile_id, source_profile_id, installation_id, state
) values (
  'healthcomp.server-notification:v1:account-deletion-test',
  'd3000000-0000-4000-8000-000000000002',
  (
    select pg_catalog.max(change_row.server_seq)
    from public.competition_change_log change_row
    where change_row.competition_id =
      'd3000000-0000-4000-8000-000000000002'
  ),
  'score_update',
  'd2000000-0000-4000-8000-000000000001',
  'd2000000-0000-4000-8000-000000000002',
  'd5000000-0000-4000-8000-000000000001',
  'pending'
);

select throws_ok(
  $$
    select public.begin_account_deletion(
      'd1000000-0000-4000-8000-000000000099'
    )
  $$,
  'P0002', 'account_deletion_profile_not_found',
  'an unknown authenticated identity cannot start deletion'
);

create temporary table deletion_results (
  name text primary key,
  payload jsonb not null
);

select lives_ok(
  $$
    insert into deletion_results (name, payload)
    select 'begin', public.begin_account_deletion(
      'd1000000-0000-4000-8000-000000000001'
    )
  $$,
  'deletion preparation commits as one durable phase'
);
select is(
  (select payload->>'phase' from deletion_results where name = 'begin'),
  'prepared',
  'the first durable phase is prepared'
);
select is(
  (
    select profile_row.state
    from public.profiles profile_row
    where profile_row.id = 'd2000000-0000-4000-8000-000000000001'
  ),
  'active',
  'unverified deletion preparation leaves the profile active'
);
select is(
  (
    select competition_row.lifecycle
    from public.competitions competition_row
    where competition_row.id = 'd3000000-0000-4000-8000-000000000001'
  ),
  'pending',
  'unverified deletion preparation leaves a pending competition intact'
);
select is(
  (
    select competition_row.lifecycle
    from public.competitions competition_row
    where competition_row.id = 'd3000000-0000-4000-8000-000000000002'
  ),
  'active',
  'unverified deletion preparation leaves an active competition intact'
);
select is(
  (
    select competition_row.lifecycle
    from public.competitions competition_row
    where competition_row.id = 'd3000000-0000-4000-8000-000000000003'
  ),
  'completed',
  'completed shared history is never cancelled'
);
select is(
  (
    select count(*)::bigint
    from public.competition_invites invite_row
    where invite_row.competition_id =
      'd3000000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'unverified deletion preparation leaves invitations intact'
);
select is(
  (
    select installation_row.state
    from public.device_installations installation_row
    where installation_row.id = 'd5000000-0000-4000-8000-000000000001'
  ),
  'active',
  'unverified deletion preparation leaves installations intact'
);
select is(
  (
    select installation_row.state
    from public.device_installations installation_row
    where installation_row.id = 'd5000000-0000-4000-8000-000000000002'
  ),
  'active',
  'another profile installation is untouched'
);
select is(
  (
    select work_row.state
    from private.competition_notification_work work_row
    where work_row.semantic_id =
      'healthcomp.server-notification:v1:account-deletion-test'
  ),
  'pending',
  'unverified deletion preparation leaves notification work intact'
);
select is(
  (
    select count(*)::bigint
    from private.competition_notification_mutes mute_row
    where mute_row.profile_id = 'd2000000-0000-4000-8000-000000000001'
       or mute_row.opponent_profile_id =
         'd2000000-0000-4000-8000-000000000001'
  ),
  2::bigint,
  'unverified deletion preparation leaves mute links intact'
);
select is(
  (
    select count(*)::bigint
    from public.support_events event_row
    where event_row.profile_id = 'd2000000-0000-4000-8000-000000000001'
      and event_row.kind = 'account_deletion'
      and event_row.code = 'started'
  ),
  1::bigint,
  'preparation writes one audit-safe start event'
);
select lives_ok(
  $$
    select public.begin_account_deletion(
      'd1000000-0000-4000-8000-000000000001'
    )
  $$,
  'preparation is idempotent after a crash'
);
select is(
  (
    select count(*)::bigint
    from public.support_events event_row
    where event_row.profile_id = 'd2000000-0000-4000-8000-000000000001'
      and event_row.kind = 'account_deletion'
      and event_row.code = 'started'
  ),
  1::bigint,
  'preparation retry does not duplicate the support event'
);
select throws_ok(
  $$
    delete from auth.users user_row
    where user_row.id = 'd1000000-0000-4000-8000-000000000001'
  $$,
  null::character(5), null,
  'auth deletion is rejected while reauthentication is still unverified'
);
select throws_ok(
  $$
    update private.account_deletions deletion_row
    set auth_user_id = null
    where deletion_row.profile_id =
      'd2000000-0000-4000-8000-000000000001'
  $$,
  '55000', 'account_deletion_auth_removed_before_anonymization',
  'the deletion phase machine independently rejects premature auth removal'
);

select throws_ok(
  $$
    select public.store_account_deletion_apple_token(
      'd2000000-0000-4000-8000-000000000001', 'short'
    )
  $$,
  '22023', 'invalid_apple_refresh_token',
  'an invalid revocation token is rejected without changing phase'
);
select lives_ok(
  $$
    select public.store_account_deletion_apple_token(
      'd2000000-0000-4000-8000-000000000001',
      'test-refresh-token-for-account-deletion'
    )
  $$,
  'a valid Apple refresh token is escrowed in Vault'
);
select is(
  (
    select deletion_row.phase
    from private.account_deletions deletion_row
    where deletion_row.profile_id =
      'd2000000-0000-4000-8000-000000000001'
  ),
  'token_ready',
  'the phase advances only after Vault storage succeeds'
);
select is(
  (
    select profile_row.state
    from public.profiles profile_row
    where profile_row.id = 'd2000000-0000-4000-8000-000000000001'
  ),
  'deleting',
  'verified reauthentication blocks new authenticated work'
);
select is(
  (
    select competition_row.lifecycle
    from public.competitions competition_row
    where competition_row.id = 'd3000000-0000-4000-8000-000000000001'
  ),
  'cancelled',
  'verified reauthentication cancels a pending competition'
);
select is(
  (
    select competition_row.lifecycle
    from public.competitions competition_row
    where competition_row.id = 'd3000000-0000-4000-8000-000000000002'
  ),
  'cancelled',
  'verified reauthentication cancels an active competition'
);
select is(
  (
    select count(*)::bigint
    from public.competition_invites invite_row
    where invite_row.competition_id =
      'd3000000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'verified reauthentication removes unconsumed invitations'
);
select is(
  (
    select installation_row.state
    from public.device_installations installation_row
    where installation_row.id = 'd5000000-0000-4000-8000-000000000001'
  ),
  'revoked',
  'verified reauthentication revokes the deleting profile installation'
);
select is(
  (
    select work_row.state
    from private.competition_notification_work work_row
    where work_row.semantic_id =
      'healthcomp.server-notification:v1:account-deletion-test'
  ),
  'superseded',
  'verified reauthentication closes related notification work'
);
select is(
  (
    select count(*)::bigint
    from private.competition_notification_mutes mute_row
    where mute_row.profile_id = 'd2000000-0000-4000-8000-000000000001'
       or mute_row.opponent_profile_id =
         'd2000000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'verified reauthentication removes profile-scoped mute links'
);
select is(
  (
    select competition_row.lifecycle
    from public.competitions competition_row
    where competition_row.id = 'd3000000-0000-4000-8000-000000000003'
  ),
  'completed',
  'verified deletion cleanup never cancels completed history'
);
select is(
  (
    select installation_row.state
    from public.device_installations installation_row
    where installation_row.id = 'd5000000-0000-4000-8000-000000000002'
  ),
  'active',
  'verified deletion cleanup leaves another profile installation untouched'
);
select throws_ok(
  $$
    delete from auth.users user_row
    where user_row.id = 'd1000000-0000-4000-8000-000000000001'
  $$,
  null::character(5), null,
  'auth deletion is rejected while the Apple token awaits revocation'
);
select is(
  public.load_account_deletion_apple_token(
    'd2000000-0000-4000-8000-000000000001'
  ),
  'test-refresh-token-for-account-deletion',
  'a crash-resume attempt can recover the escrowed token'
);
select lives_ok(
  $$
    insert into deletion_results (name, payload)
    select 'resume', public.begin_account_deletion(
      'd1000000-0000-4000-8000-000000000001'
    )
  $$,
  'a resumed authenticated request can inspect durable progress'
);
select is(
  (select payload->>'phase' from deletion_results where name = 'resume'),
  'token_ready',
  'resume returns the exact durable phase'
);

select lives_ok(
  $$
    select public.mark_account_deletion_apple_revoked(
      'd2000000-0000-4000-8000-000000000001'
    )
  $$,
  'confirmed Apple revocation advances the phase'
);
select is(
  (
    select deletion_row.phase
    from private.account_deletions deletion_row
    where deletion_row.profile_id =
      'd2000000-0000-4000-8000-000000000001'
  ),
  'apple_revoked',
  'Apple revocation is durable'
);
select throws_ok(
  $$
    delete from auth.users user_row
    where user_row.id = 'd1000000-0000-4000-8000-000000000001'
  $$,
  null::character(5), null,
  'auth deletion is rejected until historical anonymization commits'
);
select is(
  (
    select count(*)::bigint
    from vault.secrets secret_row
    where secret_row.name =
      'healthcomp_account_deletion_token:d2000000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'the temporary Apple token is destroyed after revocation'
);
select lives_ok(
  $$
    select public.mark_account_deletion_apple_revoked(
      'd2000000-0000-4000-8000-000000000001'
    )
  $$,
  'an already-revoked phase is idempotent'
);

select lives_ok(
  $$
    select public.anonymize_account_deletion(
      'd2000000-0000-4000-8000-000000000001'
    )
  $$,
  'the profile and shared memberships anonymize after Apple revocation'
);
select is(
  (
    select pg_catalog.jsonb_build_object(
      'auth_user_id', profile_row.auth_user_id,
      'display_name', profile_row.display_name,
      'state', profile_row.state,
      'has_anonymized_at', profile_row.anonymized_at is not null
    )
    from public.profiles profile_row
    where profile_row.id = 'd2000000-0000-4000-8000-000000000001'
  ),
  '{"auth_user_id":null,"display_name":"Former competitor","state":"anonymized","has_anonymized_at":true}'::jsonb,
  'the historical profile retains no authentication presentation'
);
select is(
  (
    select count(*)::bigint
    from public.competition_participants participant_row
    where participant_row.profile_id =
      'd2000000-0000-4000-8000-000000000001'
      and participant_row.state = 'anonymized'
  ),
  3::bigint,
  'every membership for the deleted profile is anonymized'
);
select is(
  (
    select count(*)::bigint
    from public.competition_participants participant_row
    where participant_row.profile_id =
      'd2000000-0000-4000-8000-000000000002'
      and participant_row.state = 'accepted'
  ),
  2::bigint,
  'the remaining participant memberships are unchanged'
);
select is(
  (
    select count(*)::bigint
    from public.competitions competition_row
    where competition_row.id = 'd3000000-0000-4000-8000-000000000003'
      and competition_row.lifecycle = 'completed'
  ),
  1::bigint,
  'completed opponent history remains intact'
);
select is(
  (
    select count(*)::bigint
    from auth.users user_row
    where user_row.id = 'd1000000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'Supabase auth deletion has not happened before anonymization commits'
);
select is(
  (
    select deletion_row.phase
    from private.account_deletions deletion_row
    where deletion_row.profile_id =
      'd2000000-0000-4000-8000-000000000001'
  ),
  'auth_delete_pending',
  'the state machine waits durably for Supabase auth deletion'
);
select lives_ok(
  $$
    insert into deletion_results (name, payload)
    select 'auth-delete-resume', public.begin_account_deletion(
      'd1000000-0000-4000-8000-000000000001'
    )
  $$,
  'a crash after anonymization can resume from the surviving auth identity'
);
select is(
  (
    select payload->>'phase'
    from deletion_results
    where name = 'auth-delete-resume'
  ),
  'auth_delete_pending',
  'the retry returns the durable auth-delete phase'
);
select is(
  (
    select payload->>'auth_user_id'
    from deletion_results
    where name = 'auth-delete-resume'
  ),
  'd1000000-0000-4000-8000-000000000001',
  'the retry preserves the exact auth user pending server deletion'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"d1000000-0000-4000-8000-000000000002","role":"authenticated"}',
  true
);
select is(
  (
    select profile_row.display_name
    from public.profiles profile_row
    where profile_row.id = 'd2000000-0000-4000-8000-000000000001'
  ),
  'Former competitor',
  'the opponent sees only the safe anonymized presentation'
);
reset role;

select throws_ok(
  $$
    select public.complete_account_deletion(
      'd2000000-0000-4000-8000-000000000001'
    )
  $$,
  '55000', 'account_auth_deletion_pending',
  'the server cannot report completion while the auth user exists'
);
select lives_ok(
  $$
    delete from auth.users user_row
    where user_row.id = 'd1000000-0000-4000-8000-000000000001'
  $$,
  'Supabase auth deletion succeeds only after historical anonymization'
);
select is(
  (
    select pg_catalog.jsonb_build_object(
      'phase', deletion_row.phase,
      'auth_user_id', deletion_row.auth_user_id,
      'apple_provider_id', deletion_row.apple_provider_id,
      'has_completed_at', deletion_row.completed_at is not null
    )
    from private.account_deletions deletion_row
    where deletion_row.profile_id =
      'd2000000-0000-4000-8000-000000000001'
  ),
  '{"phase":"completed","auth_user_id":null,"apple_provider_id":null,"has_completed_at":true}'::jsonb,
  'auth deletion atomically scrubs every reverse identity link'
);
select is(
  (
    select count(*)::bigint
    from auth.identities identity_row
    where identity_row.provider_id = 'apple-delete-alice'
  ),
  0::bigint,
  'the Apple identity row is removed with the Supabase auth user'
);
select is(
  (
    select
      (
        select count(*)
        from public.profiles profile_row
        where profile_row.auth_user_id =
          'd1000000-0000-4000-8000-000000000001'
      )
      + (
        select count(*)
        from private.account_deletions deletion_row
        where deletion_row.auth_user_id =
            'd1000000-0000-4000-8000-000000000001'
          or deletion_row.apple_provider_id = 'apple-delete-alice'
      )
      + (
        select count(*)
        from auth.identities identity_row
        where identity_row.provider_id = 'apple-delete-alice'
      )
  ),
  0::bigint,
  'the anonymized profile cannot be reverse-mapped to auth or Apple identity'
);
select is(
  (
    select count(*)::bigint
    from public.support_events event_row
    where event_row.profile_id = 'd2000000-0000-4000-8000-000000000001'
      and event_row.kind = 'account_deletion'
      and event_row.code = 'completed'
  ),
  1::bigint,
  'auth deletion writes one audit-safe completion event'
);
select lives_ok(
  $$
    select public.complete_account_deletion(
      'd2000000-0000-4000-8000-000000000001'
    )
  $$,
  'completion confirmation is idempotent'
);
select lives_ok(
  $$
    select public.anonymize_account_deletion(
      'd2000000-0000-4000-8000-000000000001'
    )
  $$,
  'anonymization retry returns the completed phase without mutation'
);
select throws_ok(
  $$
    update public.profiles profile_row
    set display_name = 'Resurrected'
    where profile_row.id = 'd2000000-0000-4000-8000-000000000001'
  $$,
  '23514', 'anonymized profile state is terminal',
  'completed anonymized history cannot be resurrected'
);
select is(
  (
    select count(*)::bigint
    from public.competitions competition_row
    join public.competition_participants participant_row
      on participant_row.competition_id = competition_row.id
    where participant_row.profile_id =
      'd2000000-0000-4000-8000-000000000001'
  ),
  3::bigint,
  'all cancelled and completed shared competition records remain durable'
);
select is(
  (
    select count(*)::bigint
    from vault.secrets secret_row
    where secret_row.name =
      'healthcomp_account_deletion_token:d2000000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'no temporary Apple token remains after completion'
);
select throws_ok(
  $$
    update private.account_deletions deletion_row
    set updated_at = pg_catalog.statement_timestamp()
    where deletion_row.profile_id =
      'd2000000-0000-4000-8000-000000000001'
  $$,
  '55000', 'completed_account_deletion_is_terminal',
  'completed deletion progress is immutable on every update path'
);

select * from finish();
rollback;
