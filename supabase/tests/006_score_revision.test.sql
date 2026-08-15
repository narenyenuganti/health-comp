begin;
select plan(30);

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
 ('61000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'score-a@example.invalid', '', now(), now()),
 ('61000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'score-b@example.invalid', '', now(), now()),
 ('61000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'outsider@example.invalid', '', now(), now());
insert into public.profiles (id, auth_user_id, display_name, state) values
 ('62000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', 'A', 'active'),
 ('62000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000002', 'B', 'active'),
 ('62000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000003', 'X', 'active');
insert into public.competitions (id, creator_profile_id, time_zone_identifier, start_day, scoring_policy_identity, lifecycle, invitation_expires_at, best_available_deadline)
values ('63000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000001', 'UTC', '2026-08-12', 'healthcomp.activity-score.v1', 'active', '2026-08-11T00:00:00Z', '2099-08-20T00:00:00Z');
insert into public.competition_participants (competition_id, profile_id, role, state) values
 ('63000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000001', 'creator', 'accepted'),
 ('63000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000002', 'invitee', 'accepted');

select set_config('request.jwt.claims', '{"sub":"61000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is(
  public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000001',1,1,'2026-08-12T12:00:00Z','activeEnergyKilocalories','standHours',10000,5000,12500,'available','healthcomp.activity-score.v1')->>'disposition',
  'appended', 'valid score appends');
select is((select accepted_centi_points from public.daily_score_revisions where semantic_event_id='64000000-0000-4000-8000-000000000001'),27500,'server recomputes points');
select is((select encode(wire_content_sha256,'hex') from public.daily_score_revisions where semantic_event_id='64000000-0000-4000-8000-000000000001'),
  encode(private.wire_score_digest_v1('63000000-0000-0000-0000-000000000001'::uuid,'62000000-0000-0000-0000-000000000001'::uuid,1::smallint,'activeEnergyKilocalories','standHours',10000,5000,12500,27500,'available','healthcomp.activity-score.v1',1::bigint),'hex'), 'server recomputes digest');
select is(encode(private.wire_score_digest_v1('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002',1::smallint,'activeEnergyKilocalories','standHours',10000,5000,12500,27500,'available','healthcomp.activity-score.v1',7),'hex'),'37df3f48a20b0b6e042e2450241af9c84ec7696ee505b97d9052dc201afb7fd9','PostgreSQL available digest matches the sole fixture');
select is(encode(private.wire_score_digest_v1('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002',3::smallint,'moveMinutes','rollHours',20000,20000,20000,60000,'available','healthcomp.activity-score.v1',9),'hex'),'2297a9990a6855c5e9b86402c1d806610a5d0e7b1eb842ded05bcc1cce13fd0c','PostgreSQL capped digest matches the sole fixture');
select is(encode(private.wire_score_digest_v1('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002',2::smallint,'activeEnergyKilocalories','standHours',null,null,null,null,'sourceDataUnavailable','healthcomp.activity-score.v1',8),'hex'),'9ae1b056c0a331f571d6e906b43051d36f47020187b9729e9048f4666fe81660','PostgreSQL unavailable digest matches the sole fixture');
select is(encode(private.wire_score_digest_v1('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002',4::smallint,'activeEnergyKilocalories','standHours',0,0,0,0,'available','healthcomp.activity-score.v1',10),'hex'),'68c2f5a45a8725094df3b2fe0df4ff035cecb14c82fca380def4763cd423bcca','PostgreSQL all-zero digest matches the sole fixture');
select is(public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000001',1,1,'2026-08-12T12:00:00Z','activeEnergyKilocalories','standHours',10000,5000,12500,'available','healthcomp.activity-score.v1')->>'disposition','duplicate','exact semantic duplicate is a no-op');
select is((select count(*)::int from public.daily_score_revisions),1,'duplicate writes no row');
select is(public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000001',1,1,'2026-08-12T12:00:00Z','activeEnergyKilocalories','standHours',10001,5000,12500,'available','healthcomp.activity-score.v1')->>'code','divergent_duplicate','divergent semantic duplicate returns typed rejection');
select is(public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000002',2,1,'2026-08-13T12:00:00Z','activeEnergyKilocalories','standHours',0,0,0,'available','healthcomp.activity-score.v1')->>'code','divergent_duplicate','global revision reuse returns typed rejection');
select throws_ok($$select public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000003',2,2,'2026-08-12T12:00:00Z','activeEnergyKilocalories','standHours',0,0,0,'available','healthcomp.activity-score.v1')$$,'22023','day_mismatch','evaluated date must map to frozen day');
select throws_ok($$select public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000004',2,2,'2026-08-13T12:00:00Z','activeEnergyKilocalories','standHours',20001,0,0,'available','healthcomp.activity-score.v1')$$,'22023','invalid_score','wire ring cap is enforced');
select throws_ok($$select public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000005',2,2,'2026-08-13T12:00:00Z','activeEnergyKilocalories','standHours',0,0,0,'available','wrong.policy')$$,'22023','wrong_policy','wrong policy rejects');
select is(public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000006',2,3,'2026-08-13T12:00:00Z','moveMinutes','rollHours',null,null,null,'sourceDataUnavailable','healthcomp.activity-score.v1')->>'disposition','appended','unavailable row appends');
select is((select participant_profile_id::text from public.daily_score_revisions where semantic_event_id='64000000-0000-4000-8000-000000000006'),'62000000-0000-0000-0000-000000000001','participant derives from JWT');
select is(public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000011',3,2,'2026-08-14T12:00:00Z','activeEnergyKilocalories','standHours',0,0,0,'available','healthcomp.activity-score.v1')->>'disposition','rejected','revision regression returns a typed rejection');
select is(public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000012',3,2,'2026-08-14T12:00:00Z','activeEnergyKilocalories','standHours',0,0,0,'available','healthcomp.activity-score.v1')->>'code','revision_regression','typed rejection identifies the business conflict');
select ok((public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000013',3,2,'2026-08-14T12:00:00Z','activeEnergyKilocalories','standHours',0,0,0,'available','healthcomp.activity-score.v1')->>'acceptedServerSeq') is not null,'typed rejection carries the current accepted cursor');
select is((select pg_catalog.array_agg(key order by key) from pg_catalog.jsonb_object_keys(public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000014',3,2,'2026-08-14T12:00:00Z','activeEnergyKilocalories','standHours',0,0,0,'available','healthcomp.activity-score.v1')) key),array['acceptedCentiPoints','acceptedServerSeq','code','competitionCursor','disposition','wireContentSHA256']::text[],'typed rejection has the frozen convergent key set');
select throws_ok($$select public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000001',1,1,'2026-08-12T12:00:00Z','activeEnergyKilocalories','standHours',10000,5000,12500,'available','healthcomp.activity-score.v1',repeat('0',64))$$,'22023','wire_digest_mismatch','client digest must match server recomputation even for duplicates');
select throws_ok($$select public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000009',3,4,'2026-08-14T12:00:00Z','activeEnergyKilocalories','standHours',null,null,null,'missing','healthcomp.activity-score.v1')$$,'22023','invalid_score','client score input cannot synthesize server-only missing');
select throws_ok($$select public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000010',3,4,'2026-08-14T12:00:00Z','activeEnergyKilocalories','unknown',0,0,0,'available','healthcomp.activity-score.v1')$$,'22023','invalid_score','available input cannot use unknown stand mode');
select is((select pg_catalog.array_agg(key order by key) from pg_catalog.jsonb_object_keys(public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000001',1,1,'2026-08-12T12:00:00Z','activeEnergyKilocalories','standHours',10000,5000,12500,'available','healthcomp.activity-score.v1')) key),array['acceptedCentiPoints','acceptedServerSeq','competitionCursor','disposition','wireContentSHA256']::text[],'duplicate response has frozen convergent key set');
select set_config('request.jwt.claims', '{"sub":"61000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select throws_ok($$select public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000007',3,4,'2026-08-14T12:00:00Z','activeEnergyKilocalories','standHours',0,0,0,'available','healthcomp.activity-score.v1')$$,'P0002','competition_not_found','outsider learns no membership detail');
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$select public.submit_score_revision('63000000-0000-0000-0000-000000000001','64000000-0000-4000-8000-000000000008',3,4,'2026-08-14T12:00:00Z','activeEnergyKilocalories','standHours',0,0,0,'available','healthcomp.activity-score.v1')$$,'42501','authentication_required','anonymous rejects');
select ok(exists(select 1 from pg_constraint where conname='daily_score_revision_global_number_unique'),'global revision uniqueness exists');
select ok(not has_function_privilege('anon','public.submit_score_revision(uuid,uuid,integer,bigint,timestamptz,text,text,integer,integer,integer,text,text)','EXECUTE'),'anonymous lacks score RPC execute');
select ok(not has_function_privilege('authenticated','public.submit_score_revision(uuid,uuid,integer,bigint,timestamptz,text,text,integer,integer,integer,text,text,text)','EXECUTE'),'authenticated clients cannot bypass App Attest through the digest score RPC');
select ok(has_function_privilege('authenticated','public.submit_attested_score_revision(uuid,uuid,uuid,integer,bigint,timestamptz,text,text,integer,integer,integer,text,text,text,text)','EXECUTE'),'authenticated clients can reach only the grant-backed score RPC');

select * from finish();
rollback;
