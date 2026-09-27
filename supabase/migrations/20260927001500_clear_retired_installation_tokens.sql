-- Retain installation identities/history, but release delivery tokens on every
-- retirement path: sign-out, account deletion, and an APNs invalid-token result.
alter table public.device_installations
  alter column apns_token drop not null;

create function private.clear_retired_installation_apns_token()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.state = 'revoked' then
    new.apns_token := null;
  end if;
  return new;
end;
$$;

revoke all on function private.clear_retired_installation_apns_token()
  from public, anon, authenticated, service_role;

create trigger clear_retired_installation_apns_token
before insert or update of state, apns_token on public.device_installations
for each row execute function private.clear_retired_installation_apns_token();

update public.device_installations
set apns_token = null
where state = 'revoked';

alter table public.device_installations
  add constraint device_installations_active_token_check
    check ((state = 'active') = (apns_token is not null));
