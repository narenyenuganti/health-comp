-- Use a fresh noninteractive psql -X -qAt --file session with separately
-- verified transport. This is not an export/restore or shared-snapshot runner.
\set ON_ERROR_STOP on
\set ON_ERROR_ROLLBACK off
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never

begin transaction isolation level repeatable read read only;
set local row_security = off;
set local time zone 'UTC';
set local statement_timeout = '30s';

-- Verify effective mode, not transaction freshness. PostgreSQL can apply BEGIN
-- options inside an existing transaction. A fresh top-level connection is a
-- caller precondition; existing transactions are unsupported, not detected here.
do $recovery_read_only_guard$
begin
  if (current_setting('transaction_isolation') = 'repeatable read'
    and current_setting('transaction_read_only') = 'on') is not true
  then
    raise exception using errcode = 'P0001', message = 'read_only_repeatable_read_required';
  end if;
end
$recovery_read_only_guard$;

\ir recovery-history-integrity-query.sql
rollback;
