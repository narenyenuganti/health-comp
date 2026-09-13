-- Approved privacy exception: erase only historical display-name fields for
-- anonymized profiles. Event identity/order, all other fields, scores and
-- results remain append-only. Install the compatible iOS reader before rollout.
create or replace function private.reject_append_only_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_schema = 'public'
     and tg_table_name = 'competition_change_log'
     and tg_op = 'UPDATE' then
    if old.change_kind in ('profile_presentation_changed', 'profile_anonymized')
       and old.payload_snapshot->>'profile_id' = old.entity_id::text
       and pg_catalog.jsonb_typeof(old.payload_snapshot->'display_name') = 'string'
       and old.payload_snapshot->>'display_name' <> 'Former competitor'
       and new.payload_snapshot = pg_catalog.jsonb_set(
         old.payload_snapshot, array['display_name'], '"Former competitor"'::jsonb, false
       )
       and pg_catalog.to_jsonb(new) - 'payload_snapshot'
         = pg_catalog.to_jsonb(old) - 'payload_snapshot'
       and exists (
         select 1 from public.profiles profile_row
         where profile_row.id = old.entity_id and profile_row.state = 'anonymized'
       ) then
      return new;
    end if;
  end if;

  raise exception '% is append-only', tg_table_name using errcode = '55000';
end;
$$;

-- Reuse the shared profile transition hook so every anonymization path erases
-- prior names in the same transaction that records the terminal presentation.
create or replace function private.record_profile_anonymization()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  membership record;
begin
  if old.state is distinct from new.state and new.state = 'anonymized' then
    update public.competition_change_log change_row
    set payload_snapshot = pg_catalog.jsonb_set(
      change_row.payload_snapshot, array['display_name'], '"Former competitor"'::jsonb, false
    )
    where change_row.entity_id = new.id
      and change_row.change_kind in ('profile_presentation_changed', 'profile_anonymized')
      and change_row.payload_snapshot->>'display_name' <> 'Former competitor';

    for membership in
      select participant.competition_id
      from public.competition_participants participant
      where participant.profile_id = new.id
    loop
      perform private.allocate_competition_server_seq(
        membership.competition_id,
        'profile_anonymized',
        new.id,
        new.anonymized_at
      );
    end loop;
  end if;
  return new;
end;
$$;

-- Repair only the approved identifying field for already-anonymized profiles.
-- The same row guard protects this forward migration and future transitions.
update public.competition_change_log change_row
set payload_snapshot = pg_catalog.jsonb_set(
  change_row.payload_snapshot, array['display_name'], '"Former competitor"'::jsonb, false
)
from public.profiles profile_row
where profile_row.id = change_row.entity_id
  and profile_row.state = 'anonymized'
  and change_row.change_kind in ('profile_presentation_changed', 'profile_anonymized')
  and change_row.payload_snapshot->>'display_name' <> 'Former competitor';
