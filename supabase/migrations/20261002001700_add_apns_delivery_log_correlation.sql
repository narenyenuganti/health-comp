-- Development APNs acceptance can be correlated with Apple's delivery logs.
-- This operational identifier is server-only and is not a device-delivery receipt.
alter table private.competition_notification_work
  add column apns_development_delivery_log_id text,
  add constraint competition_notification_work_delivery_log_shape check (
    apns_development_delivery_log_id is null
    or (
      state = 'sent'
      and pg_catalog.octet_length(apns_development_delivery_log_id) between 1 and 256
      and apns_development_delivery_log_id collate "C" ~ '^[!-~]+$'
    )
  );

-- Keep the four-argument resolution RPC unchanged for older workers and for
-- responses without a usable development header. This narrower RPC resolves
-- only APNs acceptance, atomically with its optional private correlation.
create function public.resolve_competition_notification_work_with_delivery_log(
  work_id uuid,
  lease_token uuid,
  apns_unique_id text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_work_id alias for work_id;
  input_lease_token alias for lease_token;
  input_apns_unique_id alias for apns_unique_id;
  work_record record;
  retain_identifier boolean := false;
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  if input_work_id is null or input_lease_token is null
     or input_apns_unique_id is null
     or pg_catalog.octet_length(input_apns_unique_id) not between 1 and 256
     or input_apns_unique_id collate "C" !~ '^[!-~]+$' then
    raise exception 'invalid_notification_resolution' using errcode = '22023';
  end if;

  select work_row.* into work_record
  from private.competition_notification_work work_row
  where work_row.id = input_work_id
    and work_row.state = 'leased'
    and work_row.lease_token = input_lease_token
  for update;
  if not found then return false; end if;

  -- Do not attach a development identifier to a rotated, retired, production,
  -- or expired binding. Skip a busy installation rather than reversing the
  -- installation-to-work lock order used by cascading deletion. Correlation is
  -- optional; acceptance still resolves through the original RPC.
  if work_record.lease_expires_at > pg_catalog.statement_timestamp() then
    select true into retain_identifier
    from public.device_installations installation_row
    where installation_row.profile_id = work_record.recipient_profile_id
      and installation_row.installation_id = work_record.installation_id
      and installation_row.state = 'active'
      and installation_row.environment = 'sandbox'
      and extensions.digest(installation_row.apns_token, 'sha256')
        = work_record.leased_apns_token_sha256
    for share skip locked;
  end if;

  if not public.resolve_competition_notification_work(
    input_work_id, input_lease_token, 'sent', null
  ) then return false; end if;

  if retain_identifier then
    update private.competition_notification_work
    set apns_development_delivery_log_id = input_apns_unique_id
    where id = input_work_id;
  end if;
  return true;
end;
$$;

revoke all on function public.resolve_competition_notification_work_with_delivery_log(
  uuid, uuid, text
) from public, anon, authenticated, service_role;
grant execute on function public.resolve_competition_notification_work_with_delivery_log(
  uuid, uuid, text
) to service_role;
