-- Installed builds decode each group reaction against exactly these seven keys.
-- Name them, so a column added to private.competition_reactions later stays
-- server-side instead of rejecting every group match list. Otherwise unchanged
-- from 20261110003900.
create or replace function private.group_match_projection(cid uuid, viewer uuid)
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
    'reactions',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'competition_id',r.competition_id,'author_profile_id',r.author_profile_id,'target_profile_id',r.target_profile_id,
        'day_ordinal',r.day_ordinal,'reaction',r.reaction,'created_at',r.created_at,'updated_at',r.updated_at)
        order by r.updated_at,r.author_profile_id)
      from private.competition_reactions r where r.competition_id = c.id),'[]'::jsonb),
    'result',(select (pg_catalog.to_jsonb(r) - 'frozen_payload') || pg_catalog.jsonb_build_object('server_seq',r.server_seq::text,
      'immutable_hash',pg_catalog.encode(r.immutable_hash,'hex'),'version',1,
      'seats',(select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'seat_index',(s->>'seat_index')::integer,'total_centi_points',s->>'total_centi_points',
        'days',case when s->>'kind' = 'bot' then
          (select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'ordinal',d.ordinal,'status','available','centi_points',((d.points::text)::bigint*100)::text,'reason',null)
            order by d.ordinal)
            from pg_catalog.jsonb_array_elements(s->'bot_daily_totals') with ordinality d(points,ordinal))
        else (select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'ordinal',(d->>'ordinal')::integer,
          'status',case when d->>'status' = 'points' then 'available' else d->>'status' end,
          'centi_points',case when d->>'status' = 'points' then d->>'centi_points' else null end,
          'reason',case when d->>'status' = 'afterLeave' then 'afterLeave' else d->>'reason' end)
          order by (d->>'ordinal')::integer) from pg_catalog.jsonb_array_elements(s->'window'->'days') d) end)
        order by (s->>'seat_index')::integer) from pg_catalog.jsonb_array_elements(r.frozen_payload->'seats') s)) from public.competition_group_results r where r.competition_id = c.id))
  from public.competitions c where c.id = cid and c.format <> 'duel';
$$;
