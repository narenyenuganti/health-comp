-- Fresh, noninteractive psql -XqAt --file only. Transport and a common recovery
-- point are caller prerequisites; this component never exports or restores data.
\set ON_ERROR_STOP on
\set ON_ERROR_ROLLBACK off
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never

begin transaction isolation level repeatable read read only;
set local row_security = off;
set local time zone 'UTC';
set local statement_timeout = '30s';
set local search_path = pg_catalog;

-- Effective mode/origin only: BEGIN options cannot prove connection freshness.
do $recovery_state_guard$
begin
  if (current_setting('transaction_isolation') = 'repeatable read'
    and current_setting('transaction_read_only') = 'on'
    and current_setting('session_replication_role') = 'origin') is not true
  then
    raise exception using errcode = 'P0001', message = 'recovery_state_mode_required';
  end if;
end
$recovery_state_guard$;

\ir recovery-state-acceptance-query.sql
rollback;
