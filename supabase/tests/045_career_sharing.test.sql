begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();

-- Results here are synthetic, so the frozen-window proofs can't hold. Rolled back.
alter table public.competition_results drop constraint competition_result_frozen_window_check;
alter table public.competition_results drop constraint competition_result_immutable_hash_check;

create function pg_temp.pid(n integer) returns uuid language sql immutable as $$ select md5('career-profile-' || n)::uuid $$;
create function pg_temp.uid(n integer) returns uuid language sql immutable as $$ select md5('career-auth-' || n)::uuid $$;
create function pg_temp.as_user(n integer) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('role','authenticated','sub',pg_temp.uid(n))::text, true);
$$;

insert into auth.users(id) select pg_temp.uid(n) from generate_series(1,10) n;
insert into public.profiles(id, auth_user_id, display_name, state)
  select pg_temp.pid(n), pg_temp.uid(n), 'Player ' || n, 'active' from generate_series(1,10) n;

-- Player 1's weeks, oldest first by start day.
create function pg_temp.week(days_ago integer, a integer, b integer, a_points integer, b_points integer, fmt text default 'duel',
  cid uuid default gen_random_uuid())
returns void language plpgsql as $$
begin
  insert into public.competitions(id, creator_profile_id, time_zone_identifier, start_day, scoring_policy_identity,
    lifecycle, invitation_expires_at, best_available_deadline, format, seat_count)
  values (cid, pg_temp.pid(a), 'UTC', current_date - days_ago, 'healthcomp.activity-score.v1', 'completed',
    now() + interval '1 day', now() + interval '9 days', fmt, case when fmt = 'duel' then 2 else 3 end);
  if fmt <> 'duel' then
    insert into public.competition_participants(competition_id, profile_id, role, state, seat_index) values
      (cid, pg_temp.pid(a), 'creator', 'accepted', 1), (cid, pg_temp.pid(b), 'invitee', 'accepted', 2);
    insert into public.competition_seats(competition_id, seat_index, kind, profile_id, bot_mode) values
      (cid, 1, 'human', pg_temp.pid(a), null), (cid, 2, 'human', pg_temp.pid(b), null), (cid, 3, 'bot', null, 'pacer');
    insert into public.competition_group_results(competition_id, format, finalization_basis, completed_at, standings,
      frozen_payload, immutable_hash, server_seq)
    values (cid, fmt, 'stable', now(), '[]'::jsonb, '{"version": 1}'::jsonb, decode(repeat('11', 32), 'hex'), 1);
    return;
  end if;
  insert into public.competition_participants(competition_id, profile_id, role, state) values
    (cid, pg_temp.pid(a), 'creator', 'accepted'), (cid, pg_temp.pid(b), 'invitee', 'accepted');
  insert into public.competition_results(competition_id, participant_a_profile_id, participant_b_profile_id,
    participant_a_total_centi_points, participant_b_total_centi_points, winner_profile_id, outcome,
    finalization_basis, completed_at, frozen_window, immutable_hash, server_seq)
  values (cid, pg_temp.pid(a), pg_temp.pid(b), a_points, b_points,
    case when a_points > b_points then pg_temp.pid(a) when b_points > a_points then pg_temp.pid(b) end,
    case when a_points = b_points then 'tie' else 'winner' end, 'stable', now(), '{}'::jsonb, decode(repeat('11', 32), 'hex'), 1);
end; $$;

select pg_temp.week(70, 1, 2, 10000, 5000);
select pg_temp.week(63, 1, 2, 12000, 5000);
select pg_temp.week(56, 1, 2, 9000, 9000);
select pg_temp.week(49, 2, 1, 15000, 9000);   -- Player 2 takes that belt back.
select pg_temp.week(42, 3, 1, 8000, 25000);   -- Player 1 as participant b; best week.
select pg_temp.week(35, 1, 5, 11000, 2000);   -- Player 5 deletes, retiring this belt.
select pg_temp.week(28, 1, 3, 13000, 4000);
select pg_temp.week(21, 1, 6, 13000, 4000);   -- Player 6 will block player 1.
select pg_temp.week(14, 1, 7, 300000, 1, 'three_way');  -- Group: never counts.

update public.profiles set state = 'deleting' where id = pg_temp.pid(5);

select is(private.career_summary(pg_temp.pid(1)),
  jsonb_build_object('wins', 6, 'losses', 1, 'ties', 1, 'people', 4, 'belts', 2,
    'win_streak', 4, 'best_week_centi_points', 25000),
  'wins, losses and ties add up, ties and losses end a streak, the latest decided week holds each belt, group weeks and deleted opponents'' belts do not count');
select is(private.career_summary(pg_temp.pid(7)),
  jsonb_build_object('wins', 0, 'losses', 0, 'ties', 0, 'people', 0, 'belts', 0, 'win_streak', 0, 'best_week_centi_points', 0),
  'someone with no finished weeks has an all-zero career');

select pg_temp.as_user(2);
select is(public.get_career_summary(pg_temp.pid(1)), null, 'off by default, even to an opponent');

select pg_temp.as_user(1);
select is(public.get_career_sharing(), '{"enabled": false}'::jsonb, 'sharing starts off');
select is(public.set_career_sharing(true), '{"enabled": true}'::jsonb, 'turning sharing on reports it');
select throws_ok($$ select public.set_career_sharing(null) $$, '22023', 'invalid_career_sharing', 'null is refused');
select is(public.get_career_summary(pg_temp.pid(1)), null, 'not a way to read your own');

select pg_temp.as_user(2);
select is((public.get_career_summary(pg_temp.pid(1))->>'wins')::integer, 6, 'someone you played can see it once on');

select pg_temp.as_user(4);
select is(public.get_career_summary(pg_temp.pid(1)), null, 'a stranger cannot');

insert into private.friendships(profile_low, profile_high)
  values (least(pg_temp.pid(1), pg_temp.pid(4)), greatest(pg_temp.pid(1), pg_temp.pid(4)));
select is((public.get_career_summary(pg_temp.pid(1))->>'ties')::integer, 1, 'a friend you never played can');

insert into private.account_blocks(blocker_profile_id, blocked_profile_id) values (pg_temp.pid(6), pg_temp.pid(1));
select pg_temp.as_user(6);
select is(public.get_career_summary(pg_temp.pid(1)), null, 'someone who blocked them cannot, though they played');
select pg_temp.as_user(1);
update public.profiles set show_career = true where id = pg_temp.pid(6);
select is(public.get_career_summary(pg_temp.pid(6)), null, 'and the person they blocked sees the same empty answer');

select pg_temp.as_user(1);
select is(public.set_career_sharing(false), '{"enabled": false}'::jsonb, 'turning sharing off reports it');
select pg_temp.as_user(2);
select is(public.get_career_summary(pg_temp.pid(1)), null, 'and it disappears at once');

-- Who counts as "played with": a finished group's co-player does; a pending
-- invitee and a duel cancelled after acceptance but before day one do not.
select pg_temp.as_user(1);
select is(public.set_career_sharing(true), '{"enabled": true}'::jsonb, 'sharing back on');
select pg_temp.as_user(7);
select is((public.get_career_summary(pg_temp.pid(1))->>'wins')::integer, 6, 'a finished group co-player is someone you played with');
create function pg_temp.duel_with(b integer, life text, b_state text) returns void language plpgsql as $$
declare cid uuid := gen_random_uuid();
begin
  insert into public.competitions(id, creator_profile_id, invited_profile_id, time_zone_identifier, start_day, scoring_policy_identity,
    lifecycle, invitation_expires_at, best_available_deadline)
  values (cid, pg_temp.pid(1), pg_temp.pid(b), 'UTC', case when life = 'pending' then null else current_date + 1 end,
    'healthcomp.activity-score.v1', life, now() + interval '1 day',
    case when life = 'pending' then null else now() + interval '9 days' end);
  insert into public.competition_participants(competition_id, profile_id, role, state) values
    (cid, pg_temp.pid(1), 'creator', 'accepted'), (cid, pg_temp.pid(b), 'invitee', b_state);
end; $$;
select pg_temp.duel_with(9, 'pending', 'pending');
select pg_temp.duel_with(10, 'cancelled', 'accepted');
select pg_temp.as_user(9);
select is(public.get_career_summary(pg_temp.pid(1)), null, 'a pending invitee cannot');
select pg_temp.as_user(10);
select is(public.get_career_summary(pg_temp.pid(1)), null, 'an opponent from a duel cancelled before day one cannot');

-- Weeks that end together fold in uuid order, as the app's career does.
select pg_temp.week(7, 8, 9, 9000, 1000, 'duel', '00000000-0000-4000-8000-000000000001');   -- win
select pg_temp.week(7, 10, 8, 9000, 1000, 'duel', 'ffffffff-0000-4000-8000-000000000001');  -- loss, same day
select pg_temp.week(0, 8, 9, 9000, 1000);                                                   -- win
select is((private.career_summary(pg_temp.pid(8))->>'win_streak')::integer, 1, 'same-day weeks fold by uuid: win, loss, win is a streak of one');

select ok(not has_function_privilege('anon', 'public.get_career_summary(uuid)', 'EXECUTE'), 'signed-out callers cannot read a career');
select ok(not has_function_privilege('authenticated', 'private.career_summary(uuid)', 'EXECUTE'), 'the unguarded summary is not exposed');
select ok(not has_column_privilege('authenticated', 'public.profiles', 'show_career', 'UPDATE'), 'the switch only moves through its function');

set constraints all immediate;
select * from finish();
rollback;
