-- No private helper is callable by an API role unless this migration grants it
-- explicitly. This also closes PostgreSQL's default PUBLIC EXECUTE privilege
-- before the policy helpers are created.
revoke execute on all functions in schema private
  from public, anon, authenticated, service_role;

alter default privileges in schema private
  revoke execute on functions from public, anon, authenticated, service_role;

create or replace function private.current_profile_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select profile_row.id
  from public.profiles profile_row
  where profile_row.auth_user_id = (select auth.uid())
    and profile_row.state = 'active';
$$;

create or replace function private.is_competition_participant(
  target_competition_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select current_profile.id is not null
    and exists (
      select 1
      from public.competition_participants participant_row
      where participant_row.competition_id = target_competition_id
        and participant_row.profile_id = current_profile.id
        and participant_row.state = 'accepted'
    )
  from (select private.current_profile_id() as id) current_profile;
$$;

create or replace function private.can_view_profile(
  target_profile_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select current_profile.id is not null
    and (
      target_profile_id = current_profile.id
      or exists (
        select 1
        from public.competition_participants own_membership
        join public.competition_participants counterpart_membership
          on counterpart_membership.competition_id = own_membership.competition_id
        join public.competitions competition_row
          on competition_row.id = own_membership.competition_id
        where own_membership.profile_id = current_profile.id
          and own_membership.state = 'accepted'
          and counterpart_membership.profile_id = target_profile_id
          and counterpart_membership.state in ('accepted', 'anonymized')
          and competition_row.lifecycle in (
            'pending', 'scheduled', 'active', 'ends_today', 'tallying',
            'completed', 'archived'
          )
      )
    )
  from (select private.current_profile_id() as id) current_profile;
$$;

revoke all on function private.current_profile_id()
  from public, anon, authenticated, service_role;
revoke all on function private.is_competition_participant(uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.can_view_profile(uuid)
  from public, anon, authenticated, service_role;

grant usage on schema private to authenticated;
grant execute on function private.current_profile_id() to authenticated;
grant execute on function private.is_competition_participant(uuid) to authenticated;
grant execute on function private.can_view_profile(uuid) to authenticated;

-- RLS cannot hide individual columns. Counterpart profile access therefore
-- receives only the presentation-safe projection and never auth_user_id.
grant select (
  id, display_name
) on public.profiles to authenticated;

grant select on table
  public.competitions,
  public.competition_participants,
  public.daily_score_revisions,
  public.participant_finalization_attestations,
  public.competition_results,
  public.competition_awards,
  public.device_installations
to authenticated;

create policy profiles_participant_read
on public.profiles
for select
to authenticated
using ((select private.can_view_profile(profiles.id)));

create policy competitions_participant_read
on public.competitions
for select
to authenticated
using ((select private.is_competition_participant(competitions.id)));

create policy competition_participants_participant_read
on public.competition_participants
for select
to authenticated
using ((select private.is_competition_participant(competition_participants.competition_id)));

create policy daily_score_revisions_participant_read
on public.daily_score_revisions
for select
to authenticated
using ((select private.is_competition_participant(daily_score_revisions.competition_id)));

create policy participant_attestations_participant_read
on public.participant_finalization_attestations
for select
to authenticated
using ((select private.is_competition_participant(participant_finalization_attestations.competition_id)));

create policy competition_results_participant_read
on public.competition_results
for select
to authenticated
using ((select private.is_competition_participant(competition_results.competition_id)));

create policy competition_awards_participant_read
on public.competition_awards
for select
to authenticated
using ((select private.is_competition_participant(competition_awards.competition_id)));

create policy device_installations_owner_read
on public.device_installations
for select
to authenticated
using (device_installations.profile_id = (select private.current_profile_id()));
