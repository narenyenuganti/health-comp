create function public.sign_up_with_username(username text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_username text := pg_catalog.lower(pg_catalog.btrim(username));
  profile_record record;
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select p.id, p.display_name, p.state into profile_record
  from public.profiles p
  where p.auth_user_id = (select auth.uid())
  for update;

  if not found then
    if input_username is null or input_username !~ '^[a-z0-9_]{3,20}$' then
      raise exception 'invalid_username' using errcode = '22023';
    end if;
    if private.is_reserved_username(input_username) then
      raise exception 'username_unavailable' using errcode = 'P0001';
    end if;

    begin
      insert into public.profiles (auth_user_id, display_name, username, state)
      values ((select auth.uid()), input_username, input_username, 'active')
      on conflict (auth_user_id) do nothing
      returning id, display_name, state into profile_record;
    exception when unique_violation then
      raise exception 'username_unavailable' using errcode = 'P0001';
    end;

    if profile_record.id is null then
      select p.id, p.display_name, p.state into profile_record
      from public.profiles p
      where p.auth_user_id = (select auth.uid())
      for update;
    end if;
  end if;

  if profile_record.id is null or profile_record.state <> 'active' then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'id', profile_record.id,
    'display_name', profile_record.display_name
  );
end;
$$;

revoke all on function public.sign_up_with_username(text)
  from public, anon, authenticated, service_role;
grant execute on function public.sign_up_with_username(text) to authenticated;
