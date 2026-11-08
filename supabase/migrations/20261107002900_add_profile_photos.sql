-- Profile photos. A private bucket holds one 512 px JPEG per account at
-- '<profile id>/<photo version>.jpg'; profiles.photo_version names the
-- current one (null: initials). The profile id, not the auth user id, is the
-- folder: counterparts may know a profile id and never an auth user id.
--
-- A photo is visible to its owner, to people the owner has or had a match
-- with, and to someone the owner has a pending challenge out to. A block
-- either way hides it, and so does the viewer's own report. Clients read the
-- current version with list_profile_photos and download the object with
-- their own session (no public or signed URLs); storage RLS repeats the rule
-- per object, so a path is useless to anyone else.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('profile-photos', 'profile-photos', false, 524288, array['image/jpeg']);

alter table public.profiles add column photo_version uuid;
-- Set when a reviewer removes the photo, cleared by the owner's next set or
-- clear; the owner reads it through own_profile_photo.
alter table public.profiles add column photo_removed_by_review boolean not null default false;
-- The version a reviewer last removed. set_profile_photo refuses it, so the
-- owner can't put it back before its object is deleted. Kept past the
-- owner's next set or clear.
alter table public.profiles add column photo_removed_version uuid;
-- None is granted to authenticated: counterparts read photo_version only
-- through list_profile_photos, which applies the visibility rule.
alter table public.profiles add constraint profiles_photo_requires_active
  check (photo_version is null or state = 'active');

-- Reporting hides every photo of that person from the reporter, for good.
create table private.profile_photo_reports (
  reporter_profile_id uuid not null references public.profiles(id) on delete cascade,
  reported_profile_id uuid not null references public.profiles(id) on delete cascade,
  photo_version uuid not null,
  created_at timestamptz not null default pg_catalog.statement_timestamp(),
  primary key (reporter_profile_id, reported_profile_id),
  constraint profile_photo_reports_distinct_profiles
    check (reporter_profile_id <> reported_profile_id)
);
create index profile_photo_reports_reported_profile_id_idx
  on private.profile_photo_reports(reported_profile_id);
alter table private.profile_photo_reports enable row level security;
alter table private.profile_photo_reports force row level security;
revoke all on table private.profile_photo_reports
  from public, anon, authenticated, service_role;

-- The owner and version of a well-formed object name, else null.
create function private.profile_photo_object_owner(object_name text)
returns uuid language sql immutable set search_path = ''
as $$
  select case when object_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
    then pg_catalog.split_part(object_name, '/', 1)::uuid end;
$$;
create function private.profile_photo_object_version(object_name text)
returns uuid language sql immutable set search_path = ''
as $$
  select case when private.profile_photo_object_owner(object_name) is not null
    then pg_catalog.left(pg_catalog.split_part(object_name, '/', 2), 36)::uuid end;
$$;

-- Whether the caller may see target's photo (true for their own).
create function private.can_view_profile_photo(target_profile_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select viewer.id is not null
    and exists (select 1 from public.profiles p
      where p.id = target_profile_id and p.state = 'active')
    and (
      target_profile_id = viewer.id
      or (
        not exists (select 1 from private.account_blocks b
          where (b.blocker_profile_id = viewer.id and b.blocked_profile_id = target_profile_id)
             or (b.blocker_profile_id = target_profile_id and b.blocked_profile_id = viewer.id))
        and not exists (select 1 from private.profile_photo_reports r
          where r.reporter_profile_id = viewer.id and r.reported_profile_id = target_profile_id)
        and (
          exists (select 1 from public.competitions c
            join public.competition_participants own
              on own.competition_id = c.id and own.profile_id = viewer.id
                and own.state = 'accepted'
            join public.competition_participants other
              on other.competition_id = c.id and other.profile_id = target_profile_id
                and other.state = 'accepted'
            where c.lifecycle in ('scheduled', 'active', 'ends_today', 'tallying',
              'completed', 'archived'))
          or exists (select 1 from public.competitions c
            where c.creator_profile_id = target_profile_id
              and c.invited_profile_id = viewer.id and c.lifecycle = 'pending'
              and c.invitation_expires_at > pg_catalog.statement_timestamp())
        )
      )
    )
  from (select private.current_profile_id() as id) viewer;
$$;

-- Your own folder (any object, so you can list and remove leftovers), or
-- someone's current photo that you may see. Someone else's photo is never
-- signed: a signed URL is a bearer link that would outlive a block, report
-- or ended challenge (Storage names its operation in storage.operation).
create function private.can_read_profile_photo_object(object_name text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select owner_id is not null and (
    owner_id = private.current_profile_id()
    or (
      coalesce(pg_catalog.current_setting('storage.operation', true), '')
        not in ('storage.object.sign', 'storage.object.sign_many')
      and exists (select 1 from public.profiles p
        where p.id = owner_id
          and p.photo_version = private.profile_photo_object_version(object_name))
      and private.can_view_profile_photo(owner_id)
    ))
  from (select private.profile_photo_object_owner(object_name) as owner_id) parsed;
$$;

-- Your own folder, a well-formed name, and at most three objects at once
-- (the current photo, its replacement, and one leftover). Concurrent uploads
-- to one folder take turns, so the count can't be raced; volatile, so the
-- count after the wait sees what the other upload committed.
create function private.can_write_profile_photo_object(object_name text)
returns boolean language plpgsql volatile security definer set search_path = ''
as $$
declare
  caller_profile_id uuid := private.current_profile_id();
begin
  if caller_profile_id is null
    or private.profile_photo_object_owner(object_name) is distinct from caller_profile_id then
    return false;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('profile-photos/' || caller_profile_id::text, 0));
  return (select pg_catalog.count(*) from storage.objects o
    where o.bucket_id = 'profile-photos'
      and o.name like caller_profile_id::text || '/%') < 3;
end;
$$;

create policy profile_photos_read on storage.objects
for select to authenticated
using (bucket_id = 'profile-photos'
  and private.can_read_profile_photo_object(name));

create policy profile_photos_insert on storage.objects
for insert to authenticated
with check (bucket_id = 'profile-photos'
  and private.can_write_profile_photo_object(name));

create policy profile_photos_delete on storage.objects
for delete to authenticated
using (bucket_id = 'profile-photos'
  and private.profile_photo_object_owner(name) = private.current_profile_id());

-- After uploading '<your profile id>/<version>.jpg', makes it your photo.
create function public.set_profile_photo(photo_version uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_photo_version alias for photo_version;
  caller_profile_id uuid := private.require_active_caller_profile_id();
begin
  if input_photo_version is null then
    raise exception 'invalid_photo_version' using errcode = '22023';
  end if;
  if not exists (select 1 from storage.objects o
    where o.bucket_id = 'profile-photos'
      and o.name = caller_profile_id::text || '/' || input_photo_version::text || '.jpg') then
    raise exception 'photo_upload_required' using errcode = 'P0001';
  end if;
  -- A photo removed after review reads as one never uploaded.
  if exists (select 1 from public.profiles p
    where p.id = caller_profile_id and p.photo_removed_version = input_photo_version) then
    raise exception 'photo_upload_required' using errcode = 'P0001';
  end if;
  update public.profiles p
  set photo_version = input_photo_version, photo_removed_by_review = false,
    updated_at = pg_catalog.statement_timestamp()
  where p.id = caller_profile_id
    and (p.photo_version is distinct from input_photo_version or p.photo_removed_by_review);
  return pg_catalog.jsonb_build_object('photo_version', input_photo_version);
end;
$$;

-- The client then removes the objects in its folder.
create function public.clear_profile_photo()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  caller_profile_id uuid := private.require_active_caller_profile_id();
begin
  update public.profiles p
  set photo_version = null, photo_removed_by_review = false,
    updated_at = pg_catalog.statement_timestamp()
  where p.id = caller_profile_id
    and (p.photo_version is not null or p.photo_removed_by_review);
  return pg_catalog.jsonb_build_object('photo_version', null);
end;
$$;

-- Exactly {photo_version, removed_by_review} for the caller's own photo.
create function public.own_profile_photo()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  caller_profile_id uuid := private.require_active_caller_profile_id();
begin
  return (select pg_catalog.jsonb_build_object('photo_version', p.photo_version,
      'removed_by_review', p.photo_removed_by_review)
    from public.profiles p where p.id = caller_profile_id);
end;
$$;

-- Operators only (SQL editor), after reviewing a report: initials for
-- everyone, and the owner is told once in Account. Delete the objects in
-- '<profile id>/' with the Storage API or dashboard afterwards.
create function private.remove_profile_photo_after_review(target_profile_id uuid)
returns void language sql security definer set search_path = ''
as $$
  update public.profiles p
  set photo_removed_version = p.photo_version, photo_version = null, photo_removed_by_review = true,
    updated_at = pg_catalog.statement_timestamp()
  where p.id = target_profile_id and p.state = 'active' and p.photo_version is not null;
$$;

-- Exactly {photos: [{profile_id, photo_version}]}: only photos the caller may
-- see, so an absent id reads the same as no photo. At most 200 ids.
create function public.list_profile_photos(profile_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  input_profile_ids alias for profile_ids;
begin
  perform private.require_active_caller_profile_id();
  if input_profile_ids is null or pg_catalog.cardinality(input_profile_ids) > 200 then
    raise exception 'invalid_profile_ids' using errcode = '22023';
  end if;
  return pg_catalog.jsonb_build_object('photos', coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'profile_id', p.id, 'photo_version', p.photo_version) order by p.id)
    from public.profiles p
    where p.id = any(input_profile_ids) and p.photo_version is not null
      and private.can_view_profile_photo(p.id)
  ), '[]'::jsonb));
end;
$$;

-- Records the report and hides that person's photos from the caller at
-- once. Answers the same when already reported; a photo the caller can't see
-- reads as photo_unavailable, so nobody can probe for one.
create function public.report_profile_photo(profile_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_profile_id alias for profile_id;
  caller_profile_id uuid := private.require_active_caller_profile_id();
  reported_version uuid;
begin
  if input_profile_id is null then
    raise exception 'invalid_profile_id' using errcode = '22023';
  end if;
  if exists (select 1 from private.profile_photo_reports r
    where r.reporter_profile_id = caller_profile_id
      and r.reported_profile_id = input_profile_id) then
    return pg_catalog.jsonb_build_object('profile_id', input_profile_id);
  end if;
  select p.photo_version into reported_version from public.profiles p
  where p.id = input_profile_id and p.id <> caller_profile_id
    and p.photo_version is not null
    and private.can_view_profile_photo(p.id);
  if reported_version is null then
    raise exception 'photo_unavailable' using errcode = 'P0001';
  end if;
  insert into private.profile_photo_reports
    (reporter_profile_id, reported_profile_id, photo_version)
  values (caller_profile_id, input_profile_id, reported_version)
  on conflict do nothing;
  return pg_catalog.jsonb_build_object('profile_id', input_profile_id);
end;
$$;

-- Starting deletion clears the photo and the account's reports both ways,
-- like blocks (2600). The delete-account function removes the objects.
create function private.purge_profile_photo_on_profile_deactivation()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if old.state = 'active' and new.state <> 'active' then
    new.photo_version := null;
    new.photo_removed_version := null;
    delete from private.profile_photo_reports r
    where r.reporter_profile_id = new.id or r.reported_profile_id = new.id;
  end if;
  return new;
end;
$$;
create trigger purge_profile_photo_on_profile_deactivation
before update of state on public.profiles
for each row execute function private.purge_profile_photo_on_profile_deactivation();

-- 0450's presentation change, now also on a photo change: same payload
-- (display_name, profile_id), so counterparts' apps wake and re-read photos.
create or replace function private.record_profile_presentation_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  membership record;
begin
  if old.state = 'active'
     and new.state = 'active'
     and (old.display_name is distinct from new.display_name
       or old.photo_version is distinct from new.photo_version) then
    for membership in
      select participant_row.competition_id
      from public.competition_participants participant_row
      where participant_row.profile_id = new.id
    loop
      perform private.allocate_competition_server_seq(
        membership.competition_id,
        'profile_presentation_changed',
        new.id,
        new.updated_at
      );
    end loop;
  end if;

  return new;
end;
$$;
drop trigger record_profile_presentation_change on public.profiles;
create trigger record_profile_presentation_change
after update of display_name, photo_version on public.profiles
for each row execute function private.record_profile_presentation_change();

revoke all on function private.profile_photo_object_owner(text)
  from public, anon, authenticated, service_role;
revoke all on function private.profile_photo_object_version(text)
  from public, anon, authenticated, service_role;
revoke all on function private.can_view_profile_photo(uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.can_read_profile_photo_object(text)
  from public, anon, authenticated, service_role;
revoke all on function private.can_write_profile_photo_object(text)
  from public, anon, authenticated, service_role;
revoke all on function private.purge_profile_photo_on_profile_deactivation()
  from public, anon, authenticated, service_role;
revoke all on function public.set_profile_photo(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.clear_profile_photo()
  from public, anon, authenticated, service_role;
revoke all on function public.list_profile_photos(uuid[])
  from public, anon, authenticated, service_role;
revoke all on function public.own_profile_photo()
  from public, anon, authenticated, service_role;
revoke all on function private.remove_profile_photo_after_review(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.report_profile_photo(uuid)
  from public, anon, authenticated, service_role;
-- The storage policies run as the caller.
grant execute on function private.profile_photo_object_owner(text) to authenticated;
grant execute on function private.can_read_profile_photo_object(text) to authenticated;
grant execute on function private.can_write_profile_photo_object(text) to authenticated;
grant execute on function public.set_profile_photo(uuid) to authenticated;
grant execute on function public.clear_profile_photo() to authenticated;
grant execute on function public.list_profile_photos(uuid[]) to authenticated;
grant execute on function public.own_profile_photo() to authenticated;
grant execute on function public.report_profile_photo(uuid) to authenticated;
