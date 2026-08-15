create table private.competition_notification_work (
  id uuid primary key default gen_random_uuid(),
  semantic_id text not null unique check (
    semantic_id ~ '^healthcomp[.]server-notification:v1:'
    and pg_catalog.length(semantic_id) <= 255
  ),
  competition_id uuid not null,
  server_seq bigint not null check (server_seq > 0),
  kind text not null check (kind in ('score_update', 'result')),
  recipient_profile_id uuid not null,
  source_profile_id uuid not null,
  installation_id uuid not null,
  state text not null check (
    state in (
      'pending', 'leased', 'sent', 'suppressed', 'superseded',
      'discarded'
    )
  ),
  attempt_count integer not null default 0 check (
    attempt_count between 0 and 10
  ),
  available_at timestamptz not null default now(),
  lease_token uuid,
  lease_expires_at timestamptz,
  leased_apns_token_sha256 bytea,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint competition_notification_work_change_fk
    foreign key (competition_id, server_seq)
    references public.competition_change_log(competition_id, server_seq),
  constraint competition_notification_work_recipient_fk
    foreign key (competition_id, recipient_profile_id)
    references public.competition_participants(competition_id, profile_id),
  constraint competition_notification_work_source_fk
    foreign key (competition_id, source_profile_id)
    references public.competition_participants(competition_id, profile_id),
  constraint competition_notification_work_installation_fk
    foreign key (recipient_profile_id, installation_id)
    references public.device_installations(profile_id, installation_id)
    on delete cascade,
  constraint competition_notification_work_distinct_profiles
    check (recipient_profile_id <> source_profile_id),
  constraint competition_notification_work_identity_unique
    unique (
      competition_id, server_seq, kind, recipient_profile_id,
      installation_id
    ),
  constraint competition_notification_work_state_shape check (
    (
      state = 'pending'
      and lease_token is null
      and lease_expires_at is null
      and leased_apns_token_sha256 is null
      and completed_at is null
    )
    or (
      state = 'leased'
      and lease_token is not null
      and lease_expires_at is not null
      and leased_apns_token_sha256 is not null
      and pg_catalog.octet_length(leased_apns_token_sha256) = 32
      and completed_at is null
    )
    or (
      state in ('sent', 'suppressed', 'superseded', 'discarded')
      and lease_token is null
      and lease_expires_at is null
      and leased_apns_token_sha256 is null
      and completed_at is not null
    )
  ),
  constraint competition_notification_work_timestamps check (
    updated_at >= created_at
    and (completed_at is null or completed_at >= created_at)
  )
);

alter table private.competition_notification_work enable row level security;
alter table private.competition_notification_work force row level security;

revoke all on table private.competition_notification_work
  from public, anon, authenticated, service_role;

create index competition_notification_work_available_idx
  on private.competition_notification_work(available_at, created_at, id)
  where state in ('pending', 'leased');
create index competition_notification_work_installation_idx
  on private.competition_notification_work(
    recipient_profile_id, installation_id, state
  );
create index competition_notification_work_competition_idx
  on private.competition_notification_work(
    competition_id, recipient_profile_id, installation_id, kind, server_seq
  );

create or replace function private.request_competition_notification_worker()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  worker_url text;
  worker_token text;
begin
  select secret_row.decrypted_secret
  into worker_url
  from vault.decrypted_secrets secret_row
  where secret_row.name = 'healthcomp_notification_worker_url'
  order by secret_row.created_at desc
  limit 1;

  select secret_row.decrypted_secret
  into worker_token
  from vault.decrypted_secrets secret_row
  where secret_row.name = 'healthcomp_notification_worker_token'
  order by secret_row.created_at desc
  limit 1;

  if worker_url is null
     or worker_url !~ '^https://[a-z0-9]{20}[.]supabase[.]co/functions/v1/send-competition-notification$'
     or worker_token is null
     or worker_token !~ '^[A-Za-z0-9_-]{43,128}$' then
    return;
  end if;

  perform net.http_post(
    url := worker_url,
    headers := pg_catalog.jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || worker_token
    ),
    body := '{"batchSize":25}'::jsonb,
    timeout_milliseconds := 5000
  );
exception
  when others then
    return;
end;
$$;

revoke all on function private.request_competition_notification_worker()
  from public, anon, authenticated, service_role;

create or replace function private.enqueue_competition_notification_work()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_competition_id uuid;
  target_server_seq bigint;
  target_kind text;
  score_source_profile_id uuid;
  decision_time timestamptz := pg_catalog.statement_timestamp();
  recipient record;
  is_muted boolean;
  semantic_id text;
begin
  if tg_table_schema <> 'public' then
    raise exception 'invalid_notification_trigger' using errcode = '55000';
  end if;

  if tg_table_name = 'daily_score_revisions' then
    target_competition_id := new.competition_id;
    target_server_seq := new.server_seq;
    target_kind := 'score_update';
    score_source_profile_id := new.participant_profile_id;

    if not exists (
      select 1
      from public.competition_participants source_participant
      join public.profiles source_profile
        on source_profile.id = source_participant.profile_id
      where source_participant.competition_id = target_competition_id
        and source_participant.profile_id = score_source_profile_id
        and source_participant.state = 'accepted'
        and source_profile.state = 'active'
    ) then
      return new;
    end if;
  elsif tg_table_name = 'competition_results' then
    target_competition_id := new.competition_id;
    target_server_seq := new.server_seq;
    target_kind := 'result';
    score_source_profile_id := null;
  else
    raise exception 'invalid_notification_trigger' using errcode = '55000';
  end if;

  for recipient in
    select participant_row.profile_id as recipient_profile_id,
           opponent_row.profile_id as source_profile_id,
           installation_row.installation_id
    from public.competition_participants participant_row
    join public.profiles profile_row
      on profile_row.id = participant_row.profile_id
    join public.device_installations installation_row
      on installation_row.profile_id = participant_row.profile_id
     and installation_row.state = 'active'
    join lateral (
      select other_participant.profile_id
      from public.competition_participants other_participant
      join public.profiles other_profile
        on other_profile.id = other_participant.profile_id
      where other_participant.competition_id = target_competition_id
        and other_participant.profile_id <> participant_row.profile_id
        and other_participant.state = 'accepted'
        and other_profile.state = 'active'
      order by other_participant.profile_id
      limit 1
    ) opponent_row on true
    where participant_row.competition_id = target_competition_id
      and participant_row.state = 'accepted'
      and profile_row.state = 'active'
      and (
        target_kind = 'result'
        or participant_row.profile_id <> score_source_profile_id
      )
    order by participant_row.profile_id, installation_row.installation_id
  loop
    if target_kind = 'score_update'
       and recipient.source_profile_id <> score_source_profile_id then
      continue;
    end if;

    update private.competition_notification_work work_row
    set state = 'superseded',
        lease_token = null,
        lease_expires_at = null,
        leased_apns_token_sha256 = null,
        updated_at = decision_time,
        completed_at = decision_time
    where work_row.competition_id = target_competition_id
      and work_row.recipient_profile_id = recipient.recipient_profile_id
      and work_row.installation_id = recipient.installation_id
      and work_row.kind = 'score_update'
      and work_row.server_seq < target_server_seq
      and (
        work_row.state = 'pending'
        or (
          work_row.state = 'leased'
          and work_row.lease_expires_at <= decision_time
        )
      );

    is_muted := exists (
      select 1
      from private.competition_notification_mutes mute_row
      where mute_row.profile_id = recipient.recipient_profile_id
        and mute_row.opponent_profile_id = recipient.source_profile_id
    );
    semantic_id := 'healthcomp.server-notification:v1:'
      || target_competition_id::text || ':' || target_kind || ':'
      || target_server_seq::text || ':'
      || recipient.recipient_profile_id::text || ':'
      || recipient.installation_id::text;

    insert into private.competition_notification_work (
      semantic_id, competition_id, server_seq, kind,
      recipient_profile_id, source_profile_id, installation_id,
      state, available_at, created_at, updated_at, completed_at
    ) values (
      semantic_id, target_competition_id, target_server_seq, target_kind,
      recipient.recipient_profile_id, recipient.source_profile_id,
      recipient.installation_id,
      case when is_muted then 'suppressed' else 'pending' end,
      decision_time, decision_time, decision_time,
      case when is_muted then decision_time else null end
    )
    on conflict on constraint competition_notification_work_identity_unique
    do nothing;
  end loop;

  perform private.request_competition_notification_worker();

  return new;
end;
$$;

revoke all on function private.enqueue_competition_notification_work()
  from public, anon, authenticated, service_role;

create trigger enqueue_competition_notification_work_from_score
after insert on public.daily_score_revisions
for each row execute function private.enqueue_competition_notification_work();

create trigger enqueue_competition_notification_work_from_result
after insert on public.competition_results
for each row execute function private.enqueue_competition_notification_work();

create or replace function public.lease_competition_notification_work(
  batch_size integer default 25,
  lease_seconds integer default 180
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_batch_size alias for batch_size;
  input_lease_seconds alias for lease_seconds;
  as_of timestamptz := pg_catalog.statement_timestamp();
  result jsonb;
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  if input_batch_size is null or input_batch_size not between 1 and 100 then
    raise exception 'invalid_batch_size' using errcode = '22023';
  end if;
  if input_lease_seconds is null or input_lease_seconds not between 15 and 300 then
    raise exception 'invalid_lease_seconds' using errcode = '22023';
  end if;

  with locked_candidates as materialized (
    select work_row.id,
           work_row.available_at,
           work_row.created_at,
           installation_row.apns_token,
           installation_row.environment,
           case
             when work_row.attempt_count >= 10
               or installation_row.installation_id is null
               or installation_row.state <> 'active'
               or profile_row.id is null
               or profile_row.state <> 'active'
               then 'discarded'
             when exists (
               select 1
               from private.competition_notification_mutes mute_row
               where mute_row.profile_id = work_row.recipient_profile_id
                 and mute_row.opponent_profile_id
                   = work_row.source_profile_id
             ) then 'suppressed'
             else 'lease'
           end as disposition
    from private.competition_notification_work work_row
    left join public.device_installations installation_row
      on installation_row.profile_id = work_row.recipient_profile_id
     and installation_row.installation_id = work_row.installation_id
    left join public.profiles profile_row
      on profile_row.id = work_row.recipient_profile_id
    where (
        work_row.state = 'pending'
        or (
          work_row.state = 'leased'
          and work_row.lease_expires_at <= as_of
        )
      )
    order by work_row.available_at, work_row.created_at, work_row.id
    for update of work_row skip locked
    limit input_batch_size * 4
  ), housekept as (
    update private.competition_notification_work work_row
    set state = candidate.disposition,
        lease_token = null,
        lease_expires_at = null,
        leased_apns_token_sha256 = null,
        updated_at = as_of,
        completed_at = as_of
    from locked_candidates candidate
    where work_row.id = candidate.id
      and candidate.disposition in ('discarded', 'suppressed')
    returning work_row.id
  ), candidates as materialized (
    select candidate.id,
           candidate.apns_token,
           candidate.environment,
           candidate.created_at
    from locked_candidates candidate
    where candidate.disposition = 'lease'
      and candidate.available_at <= as_of
    order by candidate.available_at, candidate.created_at, candidate.id
    limit input_batch_size
  ), leased as (
    update private.competition_notification_work work_row
    set state = 'leased',
        attempt_count = work_row.attempt_count + 1,
        lease_token = extensions.gen_random_uuid(),
        lease_expires_at = as_of
          + pg_catalog.make_interval(secs => input_lease_seconds),
        leased_apns_token_sha256 = extensions.digest(
          candidate.apns_token, 'sha256'
        ),
        updated_at = as_of,
        completed_at = null
    from candidates candidate
    where work_row.id = candidate.id
    returning work_row.id,
              work_row.lease_token,
              work_row.semantic_id,
              work_row.competition_id,
              work_row.kind,
              candidate.created_at,
              candidate.apns_token,
              candidate.environment
  )
  select pg_catalog.jsonb_build_object(
    'items', coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'workId', leased.id,
          'leaseToken', leased.lease_token,
          'semanticId', leased.semantic_id,
          'competitionId', leased.competition_id,
          'kind', leased.kind,
          'apnsToken', leased.apns_token,
          'environment', leased.environment
        ) order by leased.created_at, leased.id
      ),
      '[]'::jsonb
    )
  )
  into result
  from leased;

  return result;
end;
$$;

create or replace function public.resolve_competition_notification_work(
  work_id uuid,
  lease_token uuid,
  outcome text,
  retry_after_seconds integer default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_work_id alias for work_id;
  input_lease_token alias for lease_token;
  input_outcome alias for outcome;
  input_retry_after_seconds alias for retry_after_seconds;
  as_of timestamptz := pg_catalog.statement_timestamp();
  work_record record;
  should_retry boolean;
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  if input_work_id is null
     or input_lease_token is null
     or input_outcome not in ('sent', 'retry', 'invalid_token', 'discard') then
    raise exception 'invalid_notification_resolution' using errcode = '22023';
  end if;
  if input_outcome = 'retry' then
    if input_retry_after_seconds is null
       or input_retry_after_seconds not between 1 and 3600 then
      raise exception 'invalid_notification_resolution' using errcode = '22023';
    end if;
  elsif input_retry_after_seconds is not null then
    raise exception 'invalid_notification_resolution' using errcode = '22023';
  end if;

  select work_row.*
  into work_record
  from private.competition_notification_work work_row
  where work_row.id = input_work_id
    and work_row.state = 'leased'
    and work_row.lease_token = input_lease_token
  for update;

  if not found then
    return false;
  end if;

  if input_outcome = 'invalid_token' then
    update public.device_installations installation_row
    set state = 'revoked',
        updated_at = as_of
    where installation_row.profile_id = work_record.recipient_profile_id
      and installation_row.installation_id = work_record.installation_id
      and installation_row.state = 'active'
      and extensions.digest(installation_row.apns_token, 'sha256')
        = work_record.leased_apns_token_sha256;
  end if;

  should_retry := input_outcome = 'retry'
    and work_record.attempt_count < 10;

  update private.competition_notification_work work_row
  set state = case
        when input_outcome = 'sent' then 'sent'
        when should_retry then 'pending'
        else 'discarded'
      end,
      available_at = case
        when should_retry then as_of + pg_catalog.make_interval(
          secs => input_retry_after_seconds
        )
        else work_row.available_at
      end,
      lease_token = null,
      lease_expires_at = null,
      leased_apns_token_sha256 = null,
      updated_at = as_of,
      completed_at = case when should_retry then null else as_of end
  where work_row.id = work_record.id;

  return true;
end;
$$;

revoke all on function public.lease_competition_notification_work(
  integer, integer
) from public, anon, authenticated, service_role;
revoke all on function public.resolve_competition_notification_work(
  uuid, uuid, text, integer
) from public, anon, authenticated, service_role;

grant execute on function public.lease_competition_notification_work(
  integer, integer
) to service_role;
grant execute on function public.resolve_competition_notification_work(
  uuid, uuid, text, integer
) to service_role;
