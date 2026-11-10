create function private.group_revision_strings(revisions bigint[])
returns text[] language sql immutable set search_path = '' as $$
  select case when revisions is null then null else array(select r::text from pg_catalog.unnest(revisions) r) end;
$$;
revoke all on function private.group_revision_strings(bigint[]) from public,anon,authenticated,service_role;

-- Named immutable lineups. Match ids are route identifiers, never bearer credentials.
create function private.group_lineup_blocked(cid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.account_blocks b
    join public.competition_participants a on a.profile_id = b.blocker_profile_id and a.competition_id = cid
    join public.competition_participants z on z.profile_id = b.blocked_profile_id and z.competition_id = cid);
$$;

-- Generator v1: SHA-256(seed || ':' || domain || ':' || day), first 32 bits unsigned.
-- Percent = inclusive lower + hash mod range; round half up once, then clamp 0..600.
-- Erratic's three high days are the first three in hash(shuffle,day),day order.
-- This server generator is intentionally independent of the Swift practice generator.
create function private.group_bot_week(seed text, mode text, baseline integer)
returns integer[] language sql immutable set search_path = '' as $$
  with samples as (
    select d, ('x' || pg_catalog.substr(pg_catalog.encode(extensions.digest(seed || ':percent:' || d::text,'sha256'),'hex'),1,8))::bit(32)::bigint as sample,
      pg_catalog.row_number() over (order by extensions.digest(seed || ':shuffle:' || d::text,'sha256'),d) as shuffled
    from pg_catalog.generate_series(1,7) d
  ), bounds as (
    select *, case mode when 'pacer' then 90 when 'chill' then 75 when 'beast' then 125
      when 'erratic' then case when shuffled <= 3 then 130 else 30 end end as lo,
      case mode when 'pacer' then 110 when 'chill' then 90 when 'beast' then 150
      when 'erratic' then case when shuffled <= 3 then 160 else 65 end end as hi from samples
  ) select pg_catalog.array_agg(least(600,greatest(0,((baseline::bigint * (lo + sample % (hi-lo+1)) + 50)/100)::integer)) order by d) from bounds;
$$;

create function private.bank_group_match_seat(cid uuid, pid uuid, as_of timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c record; p record;
begin
  select * into c from public.competitions where id = cid and format <> 'duel' for update;
  if not found then raise exception 'group_match_unavailable' using errcode = 'P0001'; end if;
  select * into p from public.competition_participants where competition_id = cid and profile_id = pid;
  if not found or p.state not in ('accepted','anonymized') then raise exception 'group_match_unavailable' using errcode = 'P0001'; end if;
  if p.left_at is null then
    if c.lifecycle not in ('scheduled','active','ends_today','tallying')
      or (as_of at time zone c.time_zone_identifier)::date < c.start_day
      or exists (select 1 from public.competition_group_results r where r.competition_id = cid) then
      raise exception 'leave_not_allowed' using errcode = 'P0001';
    end if;
    update public.competition_participants set left_at = as_of,
      frozen_through_day = least(7,greatest(0,(as_of at time zone c.time_zone_identifier)::date - c.start_day + 1)),
      frozen_revisions = private.latest_revision_vector(cid,pid), updated_at = as_of
    where competition_id = cid and profile_id = pid returning * into p;
    perform private.allocate_competition_server_seq(cid,'group_seat_left',pid,as_of);
    perform private.finalize_competition_locked(cid,as_of);
  end if;
  return pg_catalog.jsonb_build_object('left_at',p.left_at,'frozen_through_day',p.frozen_through_day,
    'accepted_revisions',private.group_revision_strings(p.frozen_revisions),'bank',private.participant_projection_v2(cid,pid,p.frozen_revisions,
      private.owner_window_commitment_v1(cid,pid,p.frozen_revisions)));
end; $$;

create function public.create_group_match(format text, seats jsonb, time_zone_identifier text, creation_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  input_format alias for format; input_seats alias for seats; input_zone alias for time_zone_identifier;
  input_key alias for creation_idempotency_key;
  caller uuid; cid uuid := extensions.gen_random_uuid(); existing record; request_hash bytea;
  entry jsonb; normalized jsonb := '[]'::jsonb; pid uuid; humans uuid[] := '{}'::uuid[];
  idx integer := 0; n integer; missing record; decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  if input_format is null or input_format not in ('three_way','four_way','doubles')
    or pg_catalog.jsonb_typeof(input_seats) is distinct from 'array'
    or input_zone is null or not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = input_zone) then
    raise exception 'invalid_group_match' using errcode = '22023';
  end if;
  n := pg_catalog.jsonb_array_length(input_seats);
  if n <> (case when input_format = 'three_way' then 3 else 4 end) then
    raise exception 'invalid_group_match' using errcode = '22023';
  end if;
  -- Validate the entire shape before any code resolution or profile lookup.
  if input_key is null then raise exception 'invalid_group_match' using errcode = '22023'; end if;
  for entry in select value from pg_catalog.jsonb_array_elements(input_seats) loop
    idx := idx + 1;
    if pg_catalog.jsonb_typeof(entry) is distinct from 'object'
      or coalesce(entry->>'kind','') not in ('human','bot')
      or exists (select 1 from pg_catalog.jsonb_object_keys(entry) k where k not in ('kind','profile_id','challenge_link_code','team_number','bot_mode'))
      or (input_format = 'doubles' and coalesce(entry->>'team_number','') not in ('1','2'))
      or (input_format <> 'doubles' and entry->>'team_number' is not null) then
      raise exception 'invalid_group_seat' using errcode = '22023';
    end if;
    if entry->>'kind' = 'human' then
      if (entry->>'profile_id' is null) = (entry->>'challenge_link_code' is null)
        or entry->>'bot_mode' is not null
        or (entry->>'profile_id' is not null and entry->>'profile_id' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
        or (entry->>'challenge_link_code' is not null and entry->>'challenge_link_code' !~ '^[A-Za-z0-9_-]{22}$')
        or (idx = 1 and entry->>'profile_id' is null) then
        raise exception 'invalid_group_seat' using errcode = '22023';
      end if;
    elsif idx = 1 or coalesce(entry->>'bot_mode','') not in ('pacer','chill','erratic','beast')
      or entry->>'profile_id' is not null or entry->>'challenge_link_code' is not null then
      raise exception 'invalid_group_seat' using errcode = '22023';
    end if;
  end loop;
  if (select pg_catalog.count(*) from pg_catalog.jsonb_array_elements(input_seats) e where e->>'kind' = 'human') < 2
    or (input_format = 'doubles' and (select pg_catalog.count(*) from pg_catalog.jsonb_array_elements(input_seats) e where e->>'team_number' = '1') <> 2)
    or exists (select 1 from pg_catalog.jsonb_array_elements(input_seats) e where e->>'profile_id' is not null
      group by (e->>'profile_id')::uuid having pg_catalog.count(*) > 1) then
    raise exception 'invalid_group_match' using errcode = '22023';
  end if;
  caller := private.require_active_caller_profile_id();
  request_hash := extensions.digest(pg_catalog.jsonb_build_object('format',input_format,'seats',input_seats,'zone',input_zone)::text,'sha256');
  -- Serialize retries independently of link resolution, including a link reset after the first commit.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('group-create/' || caller::text || '/' || input_key::text,0));
  select c.id,c.group_creation_request_sha256 into existing from public.competitions c
    where c.creator_profile_id = caller and c.invite_creation_idempotency_key = input_key;
  if found then
    if existing.group_creation_request_sha256 is distinct from request_hash then raise exception 'idempotency_conflict' using errcode = 'P0001'; end if;
    return pg_catalog.jsonb_build_object('competition_id',existing.id);
  end if;
  idx := 0;
  for entry in select value from pg_catalog.jsonb_array_elements(input_seats) loop
    idx := idx + 1; pid := (entry->>'profile_id')::uuid;
    if entry->>'kind' = 'human' then
      if entry->>'challenge_link_code' is not null then
        select l.profile_id into pid from private.challenge_links l where l.code = entry->>'challenge_link_code';
      end if;
      if pid is null or pid = any(humans) or (idx = 1 and pid <> caller) or (idx <> 1 and pid = caller) then
        raise exception 'recipient_unavailable' using errcode = 'P0001';
      end if;
      humans := pg_catalog.array_append(humans,pid);
      entry := entry || pg_catalog.jsonb_build_object('profile_id',pid);
    end if;
    normalized := normalized || pg_catalog.jsonb_build_array(entry);
  end loop;
  -- The same ordered profile locks serialize creation, acceptance and blocking.
  perform 1 from public.profiles p where p.id = any(humans) order by p.id for no key update;
  if exists (select 1 from pg_catalog.unnest(humans) h(id)
    where not exists (select 1 from public.profiles p where p.id = h.id and p.state = 'active'))
    or exists (select 1 from pg_catalog.jsonb_array_elements(normalized) e
      where e->>'kind' = 'human' and (e->>'profile_id')::uuid <> caller
        and ((e->>'challenge_link_code' is null and not private.are_friends(caller,(e->>'profile_id')::uuid)
            and private.challenge_link_revoked_v1(caller,(e->>'profile_id')::uuid))
          or (e->>'challenge_link_code' is not null and not exists (select 1 from private.challenge_links l
            where l.profile_id = (e->>'profile_id')::uuid and l.code = e->>'challenge_link_code'))))
    or exists (select 1 from pg_catalog.jsonb_array_elements(normalized) e
      join public.profiles recipient on recipient.id = (e->>'profile_id')::uuid
      where e->>'kind' = 'human' and recipient.id <> caller
        and not private.are_friends(caller,recipient.id)
        and (recipient.challenge_policy = 'friends_only'
          or (e->>'challenge_link_code' is null and recipient.username is not null
            and not private.has_direct_challenge_history(caller,recipient.id))))
    or exists (select 1 from private.account_blocks b where b.blocker_profile_id = any(humans) and b.blocked_profile_id = any(humans)) then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  -- Capability is checked last so blocked, reset-link and inactive profiles have no update oracle.
  select p.id,p.display_name into missing from public.profiles p where p.id = any(humans)
    and not exists (select 1 from public.device_installations i where i.profile_id = p.id and i.state = 'active' and i.supports_group_matches)
    order by pg_catalog.array_position(humans,p.id) limit 1;
  if found then raise exception 'group_update_required' using errcode = 'P0001', detail = missing.id::text,
    hint = missing.display_name || ' needs to update HealthComp first.'; end if;
  if (select count(*) from public.competitions c where c.creator_profile_id = caller and c.format <> 'duel'
    and ((c.lifecycle = 'pending' and c.invitation_expires_at > decision_time)
      or (c.lifecycle in ('scheduled','active','ends_today','tallying') and
        (decision_time at time zone c.time_zone_identifier)::date <= c.start_day + 6))) >= 5 then
    raise exception 'group_creation_limit' using errcode = 'P0001';
  end if;
  insert into public.competitions(id,creator_profile_id,format,seat_count,time_zone_identifier,scoring_policy_identity,lifecycle,invitation_expires_at,invite_creation_idempotency_key,group_creation_request_sha256)
    values(cid,caller,input_format,n,input_zone,'healthcomp.activity-score.v1','pending',decision_time + private.invitation_expiry_interval_v1(),input_key,request_hash);
  idx := 0;
  for entry in select value from pg_catalog.jsonb_array_elements(normalized) loop
    idx := idx + 1; pid := (entry->>'profile_id')::uuid;
    if entry->>'kind' = 'human' then
      insert into public.competition_participants(competition_id,profile_id,role,state,seat_index,team_number)
        values(cid,pid,case when idx = 1 then 'creator' else 'invitee' end,
          case when idx = 1 then 'accepted' else 'pending' end,idx,(entry->>'team_number')::integer);
    end if;
    insert into public.competition_seats(competition_id,seat_index,team_number,kind,profile_id,challenge_link_code,bot_mode)
      values(cid,idx,(entry->>'team_number')::integer,entry->>'kind',pid,entry->>'challenge_link_code',entry->>'bot_mode');
  end loop;
  insert into public.competition_invites(competition_id,token_digest,expires_at)
    values(cid,extensions.digest(extensions.gen_random_bytes(32),'sha256'),decision_time + private.invitation_expiry_interval_v1());
  for pid in select h from pg_catalog.unnest(humans) h where h <> caller loop
    perform private.enqueue_challenge_notification(cid,'challenge_received',pid,caller);
  end loop;
  return pg_catalog.jsonb_build_object('competition_id',cid);
end; $$;

-- Only finalized accepted rows participate in a person's 14-date baseline.
-- Latest finalization, then match id, breaks ties between overlapping dates.
create function private.group_player_baseline(pid uuid)
returns integer language sql stable security definer set search_path = '' as $$
  with finalized as (
    select r.competition_id,r.completed_at from public.competition_results r
    union all select r.competition_id,r.completed_at from public.competition_group_results r
  ), heads as (
    select distinct on (c.start_day + s.day_ordinal - 1)
      c.start_day + s.day_ordinal - 1 as local_day, s.accepted_centi_points
    from finalized f join public.competitions c on c.id = f.competition_id
    join public.competition_participants p on p.competition_id = c.id and p.profile_id = pid
    join lateral (select distinct on (r.day_ordinal) r.* from public.daily_score_revisions r
      where r.competition_id = c.id and r.participant_profile_id = pid
        and (p.left_at is null or r.client_revision = p.frozen_revisions[r.day_ordinal])
      order by r.day_ordinal,r.client_revision desc) s on s.availability_reason = 'available'
    order by c.start_day + s.day_ordinal - 1 desc, f.completed_at desc,c.id desc
  ) select coalesce(pg_catalog.round(pg_catalog.avg(accepted_centi_points)/100)::integer,300)
    from (select * from heads order by local_day desc limit 14) recent;
$$;

create function public.accept_group_match(competition_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare cid alias for competition_id; caller uuid := private.require_active_caller_profile_id();
  c record; p record; baseline integer; start_date date; seed_value text; decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  if not exists (select 1 from public.competition_participants cp where cp.competition_id = cid and cp.profile_id = caller) then
    raise exception 'group_match_unavailable' using errcode = 'P0001'; end if;
  -- Profile locks precede the competition lock everywhere that checks all-pairs blocks.
  perform 1 from public.profiles pr join public.competition_participants cp on cp.profile_id = pr.id
    where cp.competition_id = cid order by pr.id for no key update of pr;
  select co.* into c from public.competitions co join public.competition_participants cp on cp.competition_id = co.id
    and cp.profile_id = caller and cp.state in ('pending','accepted') where co.id = cid and co.format <> 'duel' for update of co;
  if not found or private.group_lineup_blocked(cid) or exists (select 1 from public.competition_participants cp
      join public.profiles pr on pr.id = cp.profile_id where cp.competition_id = cid and pr.state <> 'active') then
    raise exception 'group_match_unavailable' using errcode = 'P0001';
  end if;
  if c.lifecycle = 'scheduled' then return pg_catalog.jsonb_build_object('competition_id',cid,'state','scheduled'); end if;
  if c.lifecycle = 'expired' then return pg_catalog.jsonb_build_object('competition_id',cid,'state','expired'); end if;
  if c.lifecycle <> 'pending' then raise exception 'group_match_unavailable' using errcode = 'P0001'; end if;
  if c.invitation_expires_at <= decision_time then
    update public.competitions set lifecycle = 'expired' where id = cid;
    return pg_catalog.jsonb_build_object('competition_id',cid,'state','expired');
  end if;
  update public.competition_participants cp set state = 'accepted',updated_at = decision_time where cp.competition_id = cid and cp.profile_id = caller;
  if not exists (select 1 from public.competition_participants cp where cp.competition_id = cid and cp.state <> 'accepted') then
    select least(600,greatest(100,pg_catalog.round(pg_catalog.avg(private.group_player_baseline(cp.profile_id)))::integer)) into baseline
      from public.competition_participants cp where cp.competition_id = cid;
    for p in select s.* from public.competition_seats s where s.competition_id = cid and s.kind = 'bot' order by s.seat_index loop
      seed_value := pg_catalog.mod(('x' || pg_catalog.encode(extensions.gen_random_bytes(8),'hex'))::bit(64)::bigint::numeric
        + 18446744073709551616,18446744073709551616)::text;
      update public.competition_seats set bot_seed = seed_value,bot_baseline = baseline,bot_generator_version = 1,
        bot_daily_totals = private.group_bot_week(seed_value,bot_mode,baseline) where id = p.id;
    end loop;
    start_date := (decision_time at time zone c.time_zone_identifier)::date + 1;
    update public.competitions set lifecycle = 'scheduled',start_day = start_date,
      best_available_deadline = (start_date + private.best_available_local_day_offset_v1())::timestamp at time zone c.time_zone_identifier,
      updated_at = decision_time where id = cid;
    update public.competition_invites ci set claimed_profile_id = c.creator_profile_id,consumed_at = decision_time where ci.competition_id = cid;
    return pg_catalog.jsonb_build_object('competition_id',cid,'state','scheduled');
  end if;
  return pg_catalog.jsonb_build_object('competition_id',cid,'state','pending');
end; $$;

create function public.decline_group_match(competition_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare cid alias for competition_id; caller uuid := private.require_active_caller_profile_id(); c record; pid uuid;
  decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  select co.* into c from public.competitions co join public.competition_participants cp on cp.competition_id = co.id
    and cp.profile_id = caller where co.id = cid and co.format <> 'duel' and co.creator_profile_id <> caller for update of co;
  if not found then raise exception 'group_match_unavailable' using errcode = 'P0001'; end if;
  if c.lifecycle = 'expired' then return pg_catalog.jsonb_build_object('competition_id',cid); end if;
  if c.lifecycle = 'declined' and c.closed_by_profile_id = caller then return pg_catalog.jsonb_build_object('competition_id',cid); end if;
  if not (c.lifecycle = 'pending' or (c.lifecycle = 'scheduled' and (decision_time at time zone c.time_zone_identifier)::date < c.start_day)) then
    raise exception 'withdraw_not_allowed' using errcode = 'P0001';
  end if;
  update public.competitions set lifecycle = case when c.lifecycle = 'pending' and c.invitation_expires_at <= decision_time then 'expired' else 'declined' end,
    closed_by_profile_id = case when c.lifecycle = 'pending' and c.invitation_expires_at <= decision_time then null else caller end,
    closed_at = case when c.lifecycle = 'pending' and c.invitation_expires_at <= decision_time then null else decision_time end,updated_at = decision_time where id = cid;
  if c.lifecycle = 'pending' and c.invitation_expires_at <= decision_time then return pg_catalog.jsonb_build_object('competition_id',cid); end if;
  for pid in select cp.profile_id from public.competition_participants cp where cp.competition_id = cid and cp.profile_id <> caller loop
    perform private.enqueue_challenge_notification(cid,'challenge_declined',pid,caller);
  end loop;
  return pg_catalog.jsonb_build_object('competition_id',cid);
end; $$;

create function public.cancel_group_match(competition_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare cid alias for competition_id; caller uuid := private.require_active_caller_profile_id(); c record; pid uuid;
  decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  select * into c from public.competitions co where co.id = cid and co.format <> 'duel' and co.creator_profile_id = caller for update;
  if not found then raise exception 'group_match_unavailable' using errcode = 'P0001'; end if;
  if c.lifecycle = 'cancelled' then return pg_catalog.jsonb_build_object('competition_id',cid); end if;
  if not (c.lifecycle = 'pending' or (c.lifecycle = 'scheduled' and (decision_time at time zone c.time_zone_identifier)::date < c.start_day)) then
    raise exception 'cancel_not_allowed' using errcode = 'P0001'; end if;
  update public.competitions set lifecycle = 'cancelled',closed_by_profile_id = caller,closed_at = decision_time,updated_at = decision_time where id = cid;
  for pid in select cp.profile_id from public.competition_participants cp where cp.competition_id = cid and cp.profile_id <> caller loop
    perform private.enqueue_challenge_notification(cid,'match_cancelled',pid,caller);
  end loop;
  return pg_catalog.jsonb_build_object('competition_id',cid);
end; $$;

create function public.leave_group_match(competition_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare cid alias for competition_id; caller uuid := private.require_active_caller_profile_id();
begin return private.bank_group_match_seat(cid,caller,pg_catalog.statement_timestamp()); end; $$;

create function private.group_match_projection(cid uuid, viewer uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select pg_catalog.jsonb_build_object('version',1,'competition_id',c.id,'format',c.format,
    'server_version',(c.next_server_seq-1)::text,'creator_profile_id',c.creator_profile_id,
    'lifecycle',case when c.lifecycle = 'pending' and c.invitation_expires_at <= pg_catalog.statement_timestamp() then 'expired' else c.lifecycle end,
    'time_zone_identifier',c.time_zone_identifier,'start_day',c.start_day,'scoring_policy_identity',c.scoring_policy_identity,
    'invitation_expires_at',c.invitation_expires_at,'best_available_deadline',c.best_available_deadline,
    'closed_by_profile_id',c.closed_by_profile_id,'closed_at',c.closed_at,
    'seats',(select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',s.id,'seat_index',s.seat_index,'team_number',s.team_number,'kind',s.kind,'profile_id',s.profile_id,
      'display_name',p.display_name,'can_view_photo',case when s.profile_id is null then false else private.can_view_profile_photo(s.profile_id) end,
      'state',cp.state,'left_at',cp.left_at,'frozen_through_day',cp.frozen_through_day,'frozen_revisions',private.group_revision_strings(cp.frozen_revisions),
      'attestation_basis',(select a.basis from public.participant_finalization_attestations a where a.competition_id = c.id and a.participant_profile_id = s.profile_id order by a.attestation_version desc limit 1),
      'bot_mode',s.bot_mode,'bot_seed',s.bot_seed,'bot_baseline',s.bot_baseline,'bot_generator_version',s.bot_generator_version,
      'bot_daily_totals',s.bot_daily_totals,
      'days',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(h) || pg_catalog.jsonb_build_object(
        'client_revision',h.client_revision::text,'server_seq',h.server_seq::text,'wire_content_sha256',pg_catalog.encode(h.wire_content_sha256,'hex')) order by h.day_ordinal)
        from (select distinct on (r.day_ordinal) r.* from public.daily_score_revisions r
          where r.competition_id = c.id and r.participant_profile_id = s.profile_id
            and (cp.left_at is null or r.client_revision = cp.frozen_revisions[r.day_ordinal])
          order by r.day_ordinal,r.client_revision desc) h),'[]'::jsonb)
      ) order by s.seat_index) from public.competition_seats s
      left join public.profiles p on p.id = s.profile_id left join public.competition_participants cp
        on cp.competition_id = s.competition_id and cp.profile_id = s.profile_id where s.competition_id = c.id),
    'owner',pg_catalog.jsonb_build_object('profile_id',viewer,
      'revision_high_water',coalesce((select max(r.client_revision) from public.daily_score_revisions r
        where r.competition_id = c.id and r.participant_profile_id = viewer),0)::text,
      'attestation',(select pg_catalog.to_jsonb(a) || pg_catalog.jsonb_build_object('attestation_version',a.attestation_version::text,
        'server_seq',a.server_seq::text,'accepted_revisions',private.group_revision_strings(a.accepted_revisions),'window_commitment_sha256',pg_catalog.encode(a.window_commitment_sha256,'hex'))
        from public.participant_finalization_attestations a where a.competition_id = c.id and a.participant_profile_id = viewer
        order by a.attestation_version desc limit 1)),
    'reactions',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.updated_at,r.author_profile_id)
      from private.competition_reactions r where r.competition_id = c.id),'[]'::jsonb),
    'result',(select (pg_catalog.to_jsonb(r) - 'frozen_payload') || pg_catalog.jsonb_build_object('server_seq',r.server_seq::text,
      'immutable_hash',pg_catalog.encode(r.immutable_hash,'hex')) from public.competition_group_results r where r.competition_id = c.id))
  from public.competitions c where c.id = cid and c.format <> 'duel';
$$;

create function public.list_group_matches()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare caller uuid := private.require_active_caller_profile_id(); result jsonb;
begin
  select coalesce(pg_catalog.jsonb_agg(private.group_match_projection(c.id,caller) order by c.created_at desc,c.id),'[]'::jsonb) into result
    from public.competitions c join public.competition_participants p on p.competition_id = c.id and p.profile_id = caller
    where c.format <> 'duel' and (c.lifecycle in ('scheduled','active','ends_today','tallying','completed','archived')
      or not private.group_lineup_blocked(c.id));
  return pg_catalog.jsonb_build_object('version',1,'matches',result);
end; $$;

create function public.preview_group_match(competition_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare cid alias for competition_id; caller uuid := private.require_active_caller_profile_id();
begin
  if not exists (select 1 from public.competition_participants p join public.competitions c on c.id = p.competition_id
      where c.id = cid and c.format <> 'duel' and p.profile_id = caller and p.state in ('pending','accepted'))
    or private.group_lineup_blocked(cid) then raise exception 'group_match_unavailable' using errcode = 'P0001'; end if;
  return private.group_match_projection(cid,caller);
end; $$;

revoke all on function private.group_lineup_blocked(uuid), private.group_bot_week(text,text,integer),
  private.bank_group_match_seat(uuid,uuid,timestamptz),private.group_player_baseline(uuid),private.group_match_projection(uuid,uuid)
  from public,anon,authenticated,service_role;
revoke all on function public.create_group_match(text,jsonb,text,uuid),public.accept_group_match(uuid),public.decline_group_match(uuid),
  public.cancel_group_match(uuid),public.leave_group_match(uuid),public.list_group_matches(),public.preview_group_match(uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.create_group_match(text,jsonb,text,uuid),public.accept_group_match(uuid),public.decline_group_match(uuid),
  public.cancel_group_match(uuid),public.leave_group_match(uuid),public.list_group_matches(),public.preview_group_match(uuid) to authenticated;
