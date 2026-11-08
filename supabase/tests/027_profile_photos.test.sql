begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();

select ok((
  select not b.public and b.file_size_limit = 524288 and b.allowed_mime_types = array['image/jpeg']
  from storage.buckets b where b.id = 'profile-photos'
), 'profile-photos is private, 512 KiB at most, image/jpeg only');
select ok((
  select bool_and(p.prosecdef and p.proconfig = array['search_path=""']
    and has_function_privilege('authenticated', p.oid, 'execute')
    and not has_function_privilege('anon', p.oid, 'execute')
    and not has_function_privilege('service_role', p.oid, 'execute')
    and not has_function_privilege('public', p.oid, 'execute')) and count(*) = 4
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in
    ('set_profile_photo', 'clear_profile_photo', 'list_profile_photos', 'report_profile_photo')
), 'the photo RPCs are security definers with an empty search path, for authenticated only');
select ok((
  select bool_and(not has_function_privilege('authenticated', p.oid, 'execute')
    and not has_function_privilege('service_role', p.oid, 'execute')) and count(*) = 3
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'private' and p.proname in ('can_view_profile_photo',
    'profile_photo_object_version', 'purge_profile_photo_on_profile_deactivation')
), 'the visibility rule and purge trigger are not callable by API roles');
select ok((
  select c.relrowsecurity and c.relforcerowsecurity
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'private' and c.relname = 'profile_photo_reports'
) and not has_table_privilege('authenticated', 'private.profile_photo_reports', 'select,insert,update,delete')
  and not has_table_privilege('service_role', 'private.profile_photo_reports', 'select,insert,update,delete'),
  'profile_photo_reports has RLS enabled and forced and no client privileges');
select ok(not has_column_privilege('authenticated', 'public.profiles', 'photo_version', 'select')
  and not has_column_privilege('anon', 'public.profiles', 'photo_version', 'select'),
  'photo_version is not readable from the profiles table');

-- A Naren (owner), B Maya (finished match), C Tess (Naren's pending
-- challenge), D Dev (stranger), E Eli (Naren blocked him), F Fay (blocked
-- Naren), G Gus (reports Naren), H Hal (deletes his account).
insert into auth.users (id) select ('ca000000-0000-4000-8000-00000000000' || n)::uuid
from unnest(array['1','2','3','4','5','6','7','8']) n;
insert into public.profiles (id, auth_user_id, display_name, state)
select ('ca100000-0000-4000-8000-00000000000' || n)::uuid,
  ('ca000000-0000-4000-8000-00000000000' || n)::uuid, name, 'active'
from unnest(array['1','2','3','4','5','6','7','8'],
  array['Naren','Maya','Tess','Dev','Eli','Fay','Gus','Hal']) as t(n, name);

create temporary table r (label text primary key, id uuid);
grant all on r to authenticated;
create function pg_temp.pid(n text) returns uuid language sql as $$
  select ('ca100000-0000-4000-8000-00000000000' || n)::uuid;
$$;
create function pg_temp.as_user(n text) returns void language sql as $$
  select set_config('request.jwt.claims', pg_catalog.jsonb_build_object('role', 'authenticated',
    'sub', 'ca000000-0000-4000-8000-00000000000' || n)::text, true);
$$;
create function pg_temp.ver(n text) returns uuid language sql as $$
  select ('cb000000-0000-4000-8000-00000000000' || n)::uuid;
$$;
create function pg_temp.obj(owner_n text, ver_n text) returns text language sql as $$
  select pg_temp.pid(owner_n)::text || '/' || pg_temp.ver(ver_n)::text || '.jpg';
$$;
create function pg_temp.challenge(sender text, recipient text, digest_byte text)
returns uuid language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  return public.create_competition_invite(decode(repeat(digest_byte, 32), 'hex'),
    'America/Los_Angeles', null, ('ca000000-0000-4000-8000-00000000000' || sender)::uuid,
    gen_random_uuid(), 1::smallint, pg_temp.pid(recipient));
end;
$$;
-- What the caller can see of target's photo: the listed version, and the
-- objects in target's folder the storage policies let them read.
create function pg_temp.sees(target text) returns text language sql as $$
  select coalesce((public.list_profile_photos(array[pg_temp.pid(target)])
      #>> '{photos,0,photo_version}'), 'none')
    || ' / ' || (select count(*) from storage.objects o
      where o.bucket_id = 'profile-photos' and o.name like pg_temp.pid(target)::text || '/%');
$$;
grant execute on function pg_temp.pid(text), pg_temp.ver(text), pg_temp.obj(text, text),
  pg_temp.sees(text) to authenticated;

-- Finished matches between Naren and Maya, Eli, Fay, Gus and Hal; Naren's
-- pending challenge to Tess; and Tess's photo, so the challenger can be checked.
do $$
declare
  other text;
  byte int := 160;
  match_id uuid;
begin
  foreach other in array array['2', '5', '6', '7', '8'] loop
    match_id := pg_temp.challenge('1', other, to_hex(byte));
    byte := byte + 1;
    update public.competition_participants set state = 'accepted', joined_at = now()
    where competition_id = match_id and profile_id = pg_temp.pid(other);
    update public.competitions set lifecycle = 'completed', start_day = current_date - 10,
      best_available_deadline = now() + interval '30 days'
    where competitions.id = match_id;
  end loop;
  insert into r values ('tess', pg_temp.challenge('1', '3', 'b0'));
end;
$$;
insert into private.account_blocks (blocker_profile_id, blocked_profile_id) values
  (pg_temp.pid('1'), pg_temp.pid('5')), (pg_temp.pid('6'), pg_temp.pid('1'));

-- Uploads: only your own folder, only '<profile id>/<uuid>.jpg', at most three.
set local role authenticated;
select pg_temp.as_user('1');
select lives_ok($$insert into storage.objects (bucket_id, name) values ('profile-photos', pg_temp.obj('1', '1'))$$,
  'Naren uploads to his own folder');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('profile-photos', pg_temp.obj('2', '9'))$$,
  '42501', null, 'nobody uploads into someone else''s folder');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('profile-photos', pg_temp.pid('1')::text || '/photo.png')$$,
  '42501', null, 'a name that is not <uuid>.jpg is refused');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('profile-photos', pg_temp.pid('1')::text || '/x/' || pg_temp.ver('2')::text || '.jpg')$$,
  '42501', null, 'a nested name is refused');
select throws_ok($$select public.set_profile_photo(pg_temp.ver('2'))$$,
  'P0001', 'photo_upload_required', 'a version without its upload is refused');
select is(public.set_profile_photo(pg_temp.ver('1')), jsonb_build_object('photo_version', pg_temp.ver('1')),
  'Naren sets his photo');
select pg_temp.as_user('3');
select lives_ok($$insert into storage.objects (bucket_id, name) values ('profile-photos', pg_temp.obj('3', '3'))$$,
  'Tess uploads');
select lives_ok($$select public.set_profile_photo(pg_temp.ver('3'))$$, 'Tess sets her photo');
select pg_temp.as_user('8');
select lives_ok($$insert into storage.objects (bucket_id, name) values ('profile-photos', pg_temp.obj('8', '8'))$$,
  'Hal uploads');
select lives_ok($$select public.set_profile_photo(pg_temp.ver('8'))$$, 'Hal sets his photo');
reset role;
select is((select count(*) from public.competition_change_log l
  where l.change_kind = 'profile_presentation_changed' and l.entity_id = pg_temp.pid('1')
    and l.payload_snapshot = jsonb_build_object('profile_id', pg_temp.pid('1'), 'display_name', 'Naren')),
  6::bigint, 'setting a photo wakes each of Naren''s matches with the unchanged presentation payload');

-- Who sees Naren's photo.
set local role authenticated;
select pg_temp.as_user('1');
select is(pg_temp.sees('1'), pg_temp.ver('1')::text || ' / 1', 'the owner sees his own photo');
select pg_temp.as_user('2');
select is(pg_temp.sees('1'), pg_temp.ver('1')::text || ' / 1', 'an opponent from a finished match sees it');
select pg_temp.as_user('3');
select is(pg_temp.sees('1'), pg_temp.ver('1')::text || ' / 1', 'the person Naren challenged sees it');
select pg_temp.as_user('1');
select is(pg_temp.sees('3'), 'none / 0', 'the challenger does not see the invitee''s photo before a match');
select pg_temp.as_user('4');
select is(pg_temp.sees('1'), 'none / 0', 'a stranger sees nothing');
select is((select count(*) from storage.objects where bucket_id = 'profile-photos'), 0::bigint,
  'a stranger can list no photo objects at all');
select pg_temp.as_user('5');
select is(pg_temp.sees('1'), 'none / 0', 'someone Naren blocked sees initials');
select pg_temp.as_user('1');
select is(pg_temp.sees('5'), 'none / 0', 'and Naren sees nothing of him either');
select pg_temp.as_user('6');
select is(pg_temp.sees('1'), 'none / 0', 'someone who blocked Naren sees initials');
select pg_temp.as_user('2');
select is(public.list_profile_photos(array[pg_temp.pid('1'), pg_temp.pid('4'), pg_temp.pid('8')]),
  jsonb_build_object('photos', jsonb_build_array(
    jsonb_build_object('profile_id', pg_temp.pid('1'), 'photo_version', pg_temp.ver('1')))),
  'the list names only photos the caller may see');
select throws_ok($$select public.list_profile_photos((select array_agg(gen_random_uuid()) from generate_series(1, 201)))$$,
  '22023', 'invalid_profile_ids', 'at most 200 ids');
select throws_ok($$select public.list_profile_photos(null)$$, '22023', 'invalid_profile_ids', 'ids are required');

-- Reports hide the photo for the reporter only, and only after a sighting.
select pg_temp.as_user('4');
select throws_ok($$select public.report_profile_photo(pg_temp.pid('1'))$$,
  'P0001', 'photo_unavailable', 'a stranger cannot report (or probe) a photo');
select pg_temp.as_user('7');
select is(public.report_profile_photo(pg_temp.pid('1')), jsonb_build_object('profile_id', pg_temp.pid('1')),
  'Gus reports Naren''s photo');
select is(pg_temp.sees('1'), 'none / 0', 'the reporter no longer sees it');
select is(public.report_profile_photo(pg_temp.pid('1')), jsonb_build_object('profile_id', pg_temp.pid('1')),
  'reporting again answers the same');
select pg_temp.as_user('2');
select is(pg_temp.sees('1'), pg_temp.ver('1')::text || ' / 1', 'everyone else still sees it');
reset role;
select results_eq($$select reporter_profile_id, reported_profile_id, photo_version from private.profile_photo_reports$$,
  $$values (pg_temp.pid('7'), pg_temp.pid('1'), pg_temp.ver('1'))$$, 'one report row names the reported version');

-- Changing: the new version replaces the old for others; leftovers stay the owner's.
set local role authenticated;
select pg_temp.as_user('1');
select lives_ok($$insert into storage.objects (bucket_id, name) values ('profile-photos', pg_temp.obj('1', '2'))$$,
  'Naren uploads a second photo');
select lives_ok($$insert into storage.objects (bucket_id, name) values ('profile-photos', pg_temp.obj('1', '4'))$$,
  'and a third');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('profile-photos', pg_temp.obj('1', '5'))$$,
  '42501', null, 'a fourth object is refused');
select lives_ok($$select public.set_profile_photo(pg_temp.ver('2'))$$, 'Naren switches to the second');
select is(pg_temp.sees('1'), pg_temp.ver('2')::text || ' / 3', 'he still reads all three of his objects');
select pg_temp.as_user('2');
select is(pg_temp.sees('1'), pg_temp.ver('2')::text || ' / 1', 'Maya reads only the current one');
select is((select count(*) from storage.objects where name = pg_temp.obj('1', '1')), 0::bigint,
  'and not the old one by name');
reset role;
-- The Storage API sets this for its own deletes.
set local storage.allow_delete_query = 'true';
set local role authenticated;
select pg_temp.as_user('2');
with deleted as (delete from storage.objects where bucket_id = 'profile-photos'
  and name like pg_temp.pid('1')::text || '/%' returning 1)
select is((select count(*) from deleted), 0::bigint, 'nobody else can delete Naren''s objects');
select pg_temp.as_user('1');
with deleted as (delete from storage.objects where name in (pg_temp.obj('1', '1'), pg_temp.obj('1', '4')) returning 1)
select is((select count(*) from deleted), 2::bigint, 'Naren removes his leftovers');

-- A declined challenge ends the invitee's view.
select pg_temp.as_user('3');
select lives_ok($$select public.decline_competition_challenge((select id from r where label = 'tess'))$$,
  'Tess declines');
select is(pg_temp.sees('1'), 'none / 0', 'and sees initials from then on');

-- Removing.
select pg_temp.as_user('1');
select is(public.clear_profile_photo(), jsonb_build_object('photo_version', null), 'Naren removes his photo');
select is(pg_temp.sees('1'), 'none / 1', 'his object stays his own until the app deletes it');
select pg_temp.as_user('2');
select is(pg_temp.sees('1'), 'none / 0', 'Maya sees initials');

-- Deleting an account: its photo and its reports both ways go at once.
reset role;
insert into private.profile_photo_reports (reporter_profile_id, reported_profile_id, photo_version)
values (pg_temp.pid('8'), pg_temp.pid('3'), pg_temp.ver('3')), (pg_temp.pid('2'), pg_temp.pid('8'), pg_temp.ver('8'));
set local role authenticated;
select pg_temp.as_user('1');
select is(pg_temp.sees('8'), pg_temp.ver('8')::text || ' / 1', 'Naren sees Hal''s photo before deletion');
reset role;
update public.profiles set state = 'deleting' where id = pg_temp.pid('8');
select ok((select photo_version is null from public.profiles where id = pg_temp.pid('8')),
  'starting deletion clears the photo version');
select is((select count(*) from private.profile_photo_reports
  where pg_temp.pid('8') in (reporter_profile_id, reported_profile_id)), 0::bigint,
  'and the account''s reports both ways');
set local role authenticated;
select pg_temp.as_user('1');
select is(pg_temp.sees('8'), 'none / 0', 'nobody reads a deleting account''s object');
select pg_temp.as_user('8');
select throws_ok($$select public.list_profile_photos(array[pg_temp.pid('1')])$$,
  '42501', 'active_profile_required', 'a deleting account reads no photos');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('profile-photos', pg_temp.obj('8', '9'))$$,
  '42501', null, 'and uploads none');
reset role;
select throws_ok($$update public.profiles set photo_version = pg_temp.ver('8') where id = pg_temp.pid('8')$$,
  '23514', null, 'only an active profile can have a photo');

-- Anonymous callers get nothing.
set local role anon;
select throws_ok($$select public.list_profile_photos(array[pg_temp.pid('1')])$$,
  '42501', null, 'anon cannot list photos');
select is((select count(*) from storage.objects where bucket_id = 'profile-photos'), 0::bigint,
  'anon reads no photo objects');
reset role;

select * from finish();
rollback;
