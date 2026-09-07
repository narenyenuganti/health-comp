begin;
set local role postgres;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();

select has_column('private', 'account_deletions', 'apple_client_id',
  'deletion progress records the Apple client binding');
select has_function('public', 'store_account_deletion_apple_token',
  array['uuid', 'text', 'text'], 'token storage requires an explicit client');
select hasnt_function('public', 'store_account_deletion_apple_token',
  array['uuid', 'text'], 'the unbound public token writer is removed');

insert into auth.users (id, aud, role, created_at, updated_at)
values ('e1000000-0000-4000-8000-000000000001',
  'authenticated', 'authenticated', now(), now());
insert into auth.identities (id, provider_id, user_id, identity_data, provider,
  created_at, updated_at)
values ('e1500000-0000-4000-8000-000000000001', 'synthetic-binding-account',
  'e1000000-0000-4000-8000-000000000001',
  '{"sub":"synthetic-binding-account"}', 'apple', now(), now());
insert into public.profiles (id, auth_user_id, display_name, state)
values ('e2000000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000001', 'Synthetic binding', 'active');

select lives_ok($$select public.begin_account_deletion(
  'e1000000-0000-4000-8000-000000000001')$$,
  'native preparation remains available');
select throws_ok($$select public.store_account_deletion_apple_token(
  'e2000000-0000-4000-8000-000000000001', 'synthetic-refresh-token', '')$$,
  '22023', 'invalid_apple_client_binding', 'empty client cannot be stored');
select throws_ok($$select public.store_account_deletion_apple_token(
  'e2000000-0000-4000-8000-000000000001', 'short', 'com.example.native')$$,
  '22023', 'invalid_apple_refresh_token', 'token failure rolls back binding');
select is((select to_jsonb(d)->>'apple_client_id'
  from private.account_deletions d
  where profile_id = 'e2000000-0000-4000-8000-000000000001'), null::text,
  'failed storage leaves no client binding');
select lives_ok($$select public.store_account_deletion_apple_token(
  'e2000000-0000-4000-8000-000000000001', 'synthetic-refresh-token',
  'com.example.native')$$, 'token and client store together');
select is((select to_jsonb(d)->>'apple_client_id'
  from private.account_deletions d
  where profile_id = 'e2000000-0000-4000-8000-000000000001'),
  'com.example.native', 'durable binding matches the exchange client');
select is(public.begin_account_deletion(
  'e1000000-0000-4000-8000-000000000001')->>'apple_client_id',
  'com.example.native', 'resume returns durable client binding');
select lives_ok($$select public.store_account_deletion_apple_token(
  'e2000000-0000-4000-8000-000000000001', 'different-synthetic-token',
  'com.example.native')$$, 'same-client retry is idempotent');
select throws_ok($$select public.store_account_deletion_apple_token(
  'e2000000-0000-4000-8000-000000000001', 'different-synthetic-token',
  'com.example.web')$$, '55000', 'account_deletion_client_binding_mismatch',
  'retry cannot replace the committed client');
select is((select decrypted_secret from vault.decrypted_secrets
  where name = private.account_deletion_secret_name(
    'e2000000-0000-4000-8000-000000000001')),
  'synthetic-refresh-token', 'retries preserve the original token');
select is(has_function_privilege('authenticated',
  to_regprocedure('public.store_account_deletion_apple_token(uuid,text,text)'),
  'EXECUTE'), false, 'authenticated users cannot invoke privileged storage');
select is(has_function_privilege('service_role',
  to_regprocedure('private.store_account_deletion_apple_token(uuid,text)'),
  'EXECUTE'), false, 'service workers cannot bypass binding through the inner writer');

select * from finish();
rollback;
