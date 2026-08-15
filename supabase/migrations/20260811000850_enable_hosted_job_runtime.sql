-- The durable notification worker introduced in 20260811000700 calls
-- net.http_post. Local Supabase images enable pg_net implicitly, but a fresh
-- hosted project does not, so the executable migration chain must own it.
create extension if not exists pg_net with schema extensions;

-- Task 19's finalizer and notification-repair jobs use Supabase Cron. Keep the
-- scheduling engine deterministic across fresh staging and production projects;
-- the environment-specific job definitions remain an explicit hosted action.
create extension if not exists pg_cron;
