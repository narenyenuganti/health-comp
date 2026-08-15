create policy healthcomp_profile_broadcast_read
on realtime.messages
for select
to authenticated
using (
  extension = 'broadcast'
  and (select realtime.topic()) = (
    'profile:' || (select private.current_profile_id())::text
  )
);

create or replace function private.broadcast_competition_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  recipient record;
begin
  for recipient in
    select distinct participant_row.profile_id
    from public.competition_participants participant_row
    join public.profiles profile_row
      on profile_row.id = participant_row.profile_id
    where participant_row.competition_id = new.competition_id
      and participant_row.state = 'accepted'
      and profile_row.state = 'active'
    order by participant_row.profile_id
  loop
    perform realtime.send(
      pg_catalog.jsonb_build_object(
        'server_cursor_hint', new.server_seq::text
      ),
      'competition_changed',
      'profile:' || recipient.profile_id::text,
      true
    );
  end loop;

  return new;
end;
$$;

revoke all on function private.broadcast_competition_change()
  from public, anon, authenticated, service_role;

create trigger broadcast_competition_change
after insert on public.competition_change_log
for each row execute function private.broadcast_competition_change();
