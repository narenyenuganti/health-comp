# Hosted Finalizer Runtime

## Observed failure

The first staging execution of `healthcomp-finalize-due` failed with
`service_role_required`. Supabase Cron stored and ran the job as database role
`postgres`, while `auth.role()` was null. The scheduled command called the
public finalization RPC, whose intentional boundary is a service-role JWT.

The failing finalizer job was removed immediately. The independent
`healthcomp-notification-repair` job remained active and its pg_net request
reached the notification worker with HTTP 200.

## Chosen design

Keep `public.finalize_due_competitions(integer)` service-role-only. Extract its
bounded, lock-skipping loop into a private helper, then add a no-argument private
scheduler entry point. The scheduler entry point:

- is a security-definer function with an empty search path;
- accepts only a postgres session;
- is revoked from PUBLIC, anon, authenticated, and service_role; and
- uses the same private finalization primitive, deadline policy, batch bound,
  append-only result path, and idempotent locking behavior as the public RPC.

The hosted job command becomes:

~~~sql
select private.run_due_competition_finalizer();
~~~

This avoids weakening the public RPC and avoids introducing an HTTP hop or a
service-role secret into Cron/Vault.

## Verification and promotion

The regression must prove the public RPC remains service-role-only, the private
scheduler surface is unavailable to API roles, a postgres-owned call finalizes
one genuinely due competition, and a subsequent public batch converges at zero.
Then replay all migrations, run the full pgTAP/backend matrix, lint, and require
an empty schema diff.

Only after merge and fresh action-time approval may staging receive migration
`20260811000900` and the corrected five-minute job. Hosted evidence requires a
successful cron run plus confirmation that due competitions and notification
work remain within their reviewed state machines.

Promotion completed after that approval on 2026-08-15 local time
(2026-08-16 UTC). The pre-promotion history had 13 paired migrations through
`20260811000850` with only `20260811000900` pending; the post-promotion history
had 14 pairs and an empty second dry run. Hosted lint found no schema errors,
and live privilege readback confirmed the private scheduler remained a
postgres-owned, empty-search-path security definer unavailable to PUBLIC and
all API roles while the public RPC remained service-role-only.

The corrected job was recreated with the reviewed five-minute command. Its
first execution succeeded at 2026-08-16 04:00 UTC, with no due competition
left unfinalized. Notification repair also continued succeeding, its pg_net
request returned HTTP 200 without timeout or error, and all six non-sensitive
worker outcome counts plus pending-due and leased work counts were zero.
