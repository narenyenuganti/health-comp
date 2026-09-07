begin;
set local role postgres;
set local search_path = extensions, public, pg_catalog;
select no_plan();
select has_table('private', 'apple_deletion_web_requests', 'web grants have private durable state');
select hasnt_table('public', 'apple_deletion_web_requests', 'web grants are not exposed tables');

insert into auth.users (id, aud, role, created_at, updated_at)
values ('f1000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', now(), now());
insert into public.profiles (id, auth_user_id, display_name, state)
values ('f2000000-0000-4000-8000-000000000001',
  'f1000000-0000-4000-8000-000000000001', 'Synthetic web claim', 'active');

select lives_ok($$select public.begin_apple_deletion_web_request(
  'f1000000-0000-4000-8000-000000000001', repeat('a',64), repeat('b',64),
  repeat('c',64), repeat('d',64), 'com.example.web',
  'https://example.invalid/apple-deletion-callback')$$, 'begin binds an active profile');
select is(public.receive_apple_deletion_web_callback(repeat('b',64),
  'synthetic-authorization-code', false), repeat('a',64), 'callback escrows a code');
select is(public.claim_apple_deletion_web_request(
  'f1000000-0000-4000-8000-000000000002', repeat('a',64), repeat('c',64)),
  null::jsonb, 'another account cannot claim');
select is(public.claim_apple_deletion_web_request(
  'f1000000-0000-4000-8000-000000000001', repeat('a',64), repeat('e',64)),
  null::jsonb, 'wrong verifier cannot claim');
select is(public.claim_apple_deletion_web_request(
  'f1000000-0000-4000-8000-000000000001', repeat('a',64), repeat('c',64)),
  jsonb_build_object('authorization_code','synthetic-authorization-code',
    'apple_client_id','com.example.web','redirect_uri','https://example.invalid/apple-deletion-callback',
    'nonce',repeat('d',64)), 'claim returns only the bound grant to the trusted worker');
select is(public.claim_apple_deletion_web_request(
  'f1000000-0000-4000-8000-000000000001', repeat('a',64), repeat('c',64)),
  null::jsonb, 'claim is single use');
select is(public.receive_apple_deletion_web_callback(repeat('b',64),
  'synthetic-authorization-code', false), null::text, 'callback replay cannot restore claimed grant');
select is((select count(*) from vault.secrets where name = 'healthcomp_web_deletion_code:'||repeat('a',64)),
  0::bigint, 'claim destroys the temporary Vault secret');
select is((select count(*) from information_schema.role_table_grants
  where table_schema='private' and table_name='apple_deletion_web_requests'
    and grantee in ('anon','authenticated','service_role')), 0::bigint, 'no API role gets table access');
select lives_ok($$select public.begin_apple_deletion_web_request(
  'f1000000-0000-4000-8000-000000000001', repeat('e',64), repeat('f',64),
  repeat('c',64), repeat('d',64), 'com.example.web',
  'https://example.invalid/apple-deletion-callback')$$, 'a new request can follow a consumed request');
select is(public.receive_apple_deletion_web_callback(repeat('f',64), null, true),
  repeat('e',64), 'cancellation transitions the matching request');
select is(public.claim_apple_deletion_web_request(
  'f1000000-0000-4000-8000-000000000001', repeat('e',64), repeat('c',64)),
  null::jsonb, 'cancelled request cannot be claimed');
select lives_ok($$select public.begin_apple_deletion_web_request(
  'f1000000-0000-4000-8000-000000000001', repeat('0',64), repeat('1',64),
  repeat('c',64), repeat('d',64), 'com.example.web',
  'https://example.invalid/apple-deletion-callback')$$, 'begin an expiry fixture');
select is(public.receive_apple_deletion_web_callback(repeat('1',64),
  'synthetic-expiring-code', false), repeat('0',64), 'expiry fixture stores a code');
update private.apple_deletion_web_requests
set created_at=now()-interval '20 minutes', expires_at=now()-interval '1 minute'
where request_id=repeat('0',64);
select is(public.claim_apple_deletion_web_request(
  'f1000000-0000-4000-8000-000000000001', repeat('0',64), repeat('c',64)),
  null::jsonb, 'expired code cannot be claimed');
select is((select count(*) from vault.secrets where name = 'healthcomp_web_deletion_code:'||repeat('0',64)),
  0::bigint, 'expiry destroys temporary material');
select is(has_function_privilege('authenticated',
  'public.claim_apple_deletion_web_request(uuid,text,text)','EXECUTE'), false,
  'claim is callable only through the trusted worker');
select is((select count(*) from cron.job where jobname='healthcomp-expire-apple-web-deletion'
  and active and command='select private.expire_apple_deletion_web_requests()'),
  1::bigint, 'abandoned requests have a scheduled cleanup');
select is(private.expire_apple_deletion_web_requests(), 1::bigint,
  'bounded cleanup removes the expired fixture');
select * from finish();
rollback;
