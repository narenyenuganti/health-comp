-- Reset Link, and challenge links that really stop working once reset.
-- A link no longer hands out its owner's account id: resolving it returns
-- only the display name, and a challenge from a link is created by its
-- current code. Challenges already created keep no reference to the link
-- and stay. The id-based create remains for rematches and 1.0.2.

-- Replaces the caller's code; the old one reads as any unknown code.
-- Same {code} shape as get_my_challenge_link.
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

-- 1900's resolve without the account id.
create or replace function public.resolve_challenge_link(code text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  input_code alias for code;
  caller_profile_id uuid := private.require_active_caller_profile_id();
  target record;
begin
  if input_code is null or input_code !~ '^[A-Za-z0-9_-]{22}$' then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  select p.id, p.display_name, p.state into target
  from private.challenge_links l
  join public.profiles p on p.id = l.profile_id
  where l.code = input_code;
  if found and target.id = caller_profile_id then
    raise exception 'own_challenge_link' using errcode = 'P0001';
  end if;
  if not found or target.state <> 'active' then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  return pg_catalog.jsonb_build_object('display_name', target.display_name);
end;
$$;

-- Create from a challenge link: the code must be the owner's current one,
-- else the same recipient_unavailable as an unknown code. The link row is
-- share-locked so a concurrent reset waits for this create to finish.
-- An exact retry of a challenge already created (a lost response, or the
-- app recovering its link) returns it even after a reset; 1900's create
-- still checks that the retry matches.
create function public.create_competition_invite_from_link(
  token_digest bytea,
  creator_time_zone_identifier text,
  creator_auth_user_id uuid,
  creation_idempotency_key uuid,
  token_derivation_version smallint,
  challenge_link_code text
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  input_creator_auth_user_id alias for creator_auth_user_id;
  input_idempotency_key alias for creation_idempotency_key;
  input_code alias for challenge_link_code;
  recipient_id uuid;
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  select c.invited_profile_id into recipient_id
  from public.competitions c
  join public.profiles p on p.id = c.creator_profile_id
  where p.auth_user_id = input_creator_auth_user_id
    and c.invite_creation_idempotency_key = input_idempotency_key;
  if not found then
    if input_code is null or input_code !~ '^[A-Za-z0-9_-]{22}$' then
      raise exception 'recipient_unavailable' using errcode = 'P0001';
    end if;
    select l.profile_id into recipient_id
    from private.challenge_links l
    where l.code = input_code
    for share;
    if recipient_id is null then
      raise exception 'recipient_unavailable' using errcode = 'P0001';
    end if;
  end if;
  return public.create_competition_invite(token_digest, creator_time_zone_identifier,
    null, input_creator_auth_user_id, input_idempotency_key, token_derivation_version,
    recipient_id);
end;
$$;

revoke all on function public.reset_my_challenge_link()
  from public, anon, authenticated, service_role;
revoke all on function public.resolve_challenge_link(text)
  from public, anon, authenticated, service_role;
revoke all on function public.create_competition_invite_from_link(
  bytea, text, uuid, uuid, smallint, text)
  from public, anon, authenticated, service_role;
grant execute on function public.reset_my_challenge_link() to authenticated;
grant execute on function public.resolve_challenge_link(text) to authenticated;
grant execute on function public.create_competition_invite_from_link(
  bytea, text, uuid, uuid, smallint, text) to service_role;
