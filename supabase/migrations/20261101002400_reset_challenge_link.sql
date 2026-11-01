-- Reset Link: replace your challenge link code so the old link stops
-- resolving (it reads as any unknown code). Challenges already created keep
-- no reference to the link and stay. Same {code} shape as get_my_challenge_link.
create function public.reset_my_challenge_link()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  caller_profile_id uuid := private.require_active_caller_profile_id();
  link_code text;
begin
  insert into private.challenge_links as l (profile_id, code)
  values (caller_profile_id, private.new_challenge_link_code_v1())
  on conflict (profile_id) do update
    set code = excluded.code, created_at = pg_catalog.now()
  returning l.code into link_code;
  return pg_catalog.jsonb_build_object('code', link_code);
end;
$$;

revoke all on function public.reset_my_challenge_link()
  from public, anon, authenticated, service_role;
grant execute on function public.reset_my_challenge_link() to authenticated;
