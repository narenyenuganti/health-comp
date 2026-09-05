#!/usr/bin/env bash
# Synthetic wrapper-boundary tests, NOT validation of the substituted query.
# Run only in the separately provisioned, disposable PostgreSQL-17 fixture server:
# PGHOST=/absolute/socket/directory PGUSER=postgres bash scripts/test-recovery-history-wrapper.sh
# Port 5432 and database healthcomp_recovery_fixture are intentionally fixed.
# Never run against a linked project, hosted database, or shared database server.
# No roles/grants or permanent fixture objects are created. Session-temporary
# relations disappear on disconnect; deliberate DDL always raises in one atomic
# statement, so even a broken read-only wrapper cannot persist the probe table.
# PostgreSQL contracts: /docs/17/app-psql.html, /docs/17/sql-set.html,
# /docs/17/predefined-roles.html, and /docs/17/ddl-rowsecurity.html at postgresql.org.
set -euo pipefail
umask 077

recovery_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
recovery_wrapper="$recovery_script_dir/recovery-history-integrity.sql"
recovery_fail() {
  printf 'recovery_wrapper_assertion: %s\n' "$1" >&2
  exit 1
}

# Missing implementation must fail before connecting or creating any scratch files.
[[ -s "$recovery_wrapper" ]] || recovery_fail missing_wrapper_expected_red
[[ "$#" -eq 0 ]] || recovery_fail no_connection_arguments_allowed
[[ "${PGHOST:-}" == /* && -d "${PGHOST:-}" && "${PGHOST:-}" != *,* ]] \
  || recovery_fail explicit_single_socket_directory_required
[[ "${PGHOST:-}" != *$'\n'* && "${PGHOST:-}" != *$'\r'* ]] \
  || recovery_fail invalid_socket_directory
[[ "${PGUSER:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
  || recovery_fail explicit_fixture_user_required
command -v psql >/dev/null || recovery_fail psql_required
recovery_absent_password="$recovery_script_dir/.no-recovery-test-password"
[[ ! -e "$recovery_absent_password" && ! -L "$recovery_absent_password" ]] \
  || recovery_fail unexpected_test_password_path

recovery_psql() {
  # Do not inherit credentials, connection strings, services, PGOPTIONS, psqlrc,
  # or password-file defaults. The supplied host/user are the only connection input.
  env -i PATH="$PATH" LC_ALL=C PGHOST="$PGHOST" PGUSER="$PGUSER" \
    PGPORT=5432 PGDATABASE=healthcomp_recovery_fixture PGCONNECT_TIMEOUT=5 \
    PGPASSFILE="$recovery_absent_password" PGSERVICEFILE=/dev/null \
    psql -XqAt --no-password "$@"
}

recovery_guard_sql="$(cat <<'SQL'
\set ON_ERROR_STOP on
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
begin read only;
set local statement_timeout = '5s';
do $fixture_guard$
begin
  if current_database() <> 'healthcomp_recovery_fixture'
    or current_setting('server_version_num')::integer / 10000 <> 17
    or inet_server_addr() is not null
    or pg_catalog.pg_is_in_recovery()
    or not exists (select 1 from pg_catalog.pg_roles where rolname = current_user and rolsuper)
    or not exists (select 1 from pg_catalog.pg_roles
      where rolname = 'pg_read_all_data' and not rolsuper and not rolbypassrls)
    or exists (select 1 from pg_catalog.pg_namespace
      where nspname !~ '^pg_' and nspname not in ('public', 'information_schema'))
    or exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n
      on n.oid = c.relnamespace where n.nspname = 'public')
    or exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n
      on n.oid = p.pronamespace where n.nspname = 'public')
    or exists (select 1 from pg_catalog.pg_type t join pg_catalog.pg_namespace n
      on n.oid = t.typnamespace where n.nspname = 'public')
    or exists (select 1 from pg_catalog.pg_extension where extname <> 'plpgsql')
  then raise exception using errcode = 'P0001', message = 'isolated_empty_fixture_required'; end if;
end
$fixture_guard$;
rollback;
SQL
)"

# Guard output is never printed, including connection errors. No filesystem or
# synthetic database writes occur until the read-only guard succeeds.
if ! recovery_guard_output="$(recovery_psql -f - <<<"$recovery_guard_sql" 2>&1)"; then
  recovery_fail isolated_empty_postgres17_guard
fi
[[ -z "$recovery_guard_output" ]] || recovery_fail unexpected_guard_output

recovery_tmp="$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-recovery-wrapper.XXXXXX")"
recovery_cleanup() {
  # Only these exact files in this invocation's mktemp directory are ours.
  rm -f -- "$recovery_tmp/recovery-history-integrity.sql" \
    "$recovery_tmp/recovery-history-integrity-query.sql" "$recovery_tmp/driver.sql" \
    "$recovery_tmp/after.sql" "$recovery_tmp/stdout" "$recovery_tmp/stderr"
  rmdir -- "$recovery_tmp"
}
trap recovery_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$recovery_wrapper" "$recovery_tmp/recovery-history-integrity.sql"
cmp -s "$recovery_wrapper" "$recovery_tmp/recovery-history-integrity.sql" \
  || recovery_fail wrapper_copy_mismatch

recovery_driver_start() {
  # Repeat the guard in each connection immediately before synthetic setup.
  printf '%s\n' "$recovery_guard_sql" >"$recovery_tmp/driver.sql"
  cat >>"$recovery_tmp/driver.sql" <<'SQL'
set default_transaction_isolation = 'read committed';
set default_transaction_read_only = off;
set row_security = on;
set time zone 'Pacific/Honolulu';
set statement_timeout = '5s';
set lock_timeout = '5s';
SQL
}

recovery_driver_include() {
  # These deliberately adverse psql settings must be repaired by the REAL wrapper,
  # not masked by command-line flags or the guard's own error-handling settings.
  # Run the wrapper as a top-level --file, matching its documented entry contract.
  # An outer \ir caller with ON_ERROR_STOP=off caches that mode for the include
  # command and can resume after a child error, even if the child enabled stopping.
  cat >>"$recovery_tmp/driver.sql" <<'SQL'
\set ON_ERROR_STOP off
\set VERBOSITY verbose
\set SHOW_CONTEXT always
SQL
  : >"$recovery_tmp/after.sql"
}

recovery_run_probe() {
  local recovery_label="$1" recovery_expected_exit="$2" recovery_expected_stdout="$3"
  local recovery_expected_state="${4:-}" recovery_exit=0
  recovery_psql -f "$recovery_tmp/driver.sql" \
    -f "$recovery_tmp/recovery-history-integrity.sql" -f "$recovery_tmp/after.sql" \
    >"$recovery_tmp/stdout" 2>"$recovery_tmp/stderr" || recovery_exit=$?
  [[ "$recovery_exit" -eq "$recovery_expected_exit" ]] || recovery_fail "${recovery_label}_exit"
  [[ "$(<"$recovery_tmp/stdout")" == "$recovery_expected_stdout" ]] \
    || recovery_fail "${recovery_label}_stdout"
  if [[ -z "$recovery_expected_state" ]]; then
    [[ ! -s "$recovery_tmp/stderr" ]] || recovery_fail "${recovery_label}_stderr"
  else
    # Require SQLSTATE-only output, not just the absence of one known canary.
    awk -v code="$recovery_expected_state" '
      $0 !~ ("^psql:.*:[0-9]+: ERROR:[[:space:]]+" code "$") { bad = 1 }
      END { if (bad || NR != 1) exit 1 }
    ' "$recovery_tmp/stderr" || recovery_fail "${recovery_label}_sqlstate_only"
  fi
  printf 'Passed wrapper probe: %s\n' "$recovery_label"
}

# 1. Assert actual transaction settings and ROLLBACK in the SAME connection.
# Temporary-table writes are allowed in read-only transactions; their rollback
# distinguishes ROLLBACK from COMMIT without creating a permanent fixture.
recovery_driver_start
cat >>"$recovery_tmp/driver.sql" <<'SQL'
create temporary table recovery_wrapper_rollback_probe (value integer);
SQL
cat >"$recovery_tmp/recovery-history-integrity-query.sql" <<'SQL'
do $settings_probe$
begin
  if (current_setting('transaction_isolation') = 'repeatable read'
    and current_setting('transaction_read_only') = 'on'
    and current_setting('row_security') = 'off'
    and current_setting('TimeZone') = 'UTC'
    and current_setting('statement_timeout') = '30s') is not true
  then raise exception using errcode = 'P0001', message = 'transaction_settings'; end if;
end
$settings_probe$;
insert into pg_temp.recovery_wrapper_rollback_probe values (1);
select 'settings_inside';
SQL
recovery_driver_include
cat >>"$recovery_tmp/after.sql" <<'SQL'
do $cleanup_probe$
begin
  if (current_setting('transaction_isolation') = 'read committed'
    and current_setting('transaction_read_only') = 'off'
    and current_setting('row_security') = 'on'
    and current_setting('TimeZone') = 'Pacific/Honolulu'
    and current_setting('statement_timeout') = '5s'
    and (select count(*) from pg_temp.recovery_wrapper_rollback_probe) = 0) is not true
  then raise exception using errcode = 'P0001', message = 'rollback_cleanup'; end if;
end
$cleanup_probe$;
select 'rollback_cleanup';
SQL
recovery_run_probe settings_and_rollback 0 $'settings_inside\nrollback_cleanup'

# 2. Permanent DDL must fail with read_only_sql_transaction. If it unexpectedly
# succeeds, the following exception atomically rolls it back and has a DIFFERENT
# SQLSTATE, so the harness both fails and leaves no permanent probe relation.
recovery_driver_start
cat >"$recovery_tmp/recovery-history-integrity-query.sql" <<'SQL'
do $write_probe$
begin
  create table public.recovery_wrapper_write_probe (value integer);
  raise exception using errcode = 'P0002', message = 'permanent_write_was_allowed';
end
$write_probe$;
select 'query_continued_after_write_error';
SQL
recovery_driver_include
printf '%s\n' "select 'driver_continued_after_write_error';" >>"$recovery_tmp/after.sql"
recovery_run_probe permanent_write_rejected 3 '' 25006

# 3. A real policy filters a session-temporary row before the wrapper runs.
# This positive control establishes read permission, so 42501 from the wrapper
# cannot be mistaken for a missing table grant. SET ROLE changes only this session;
# the built-in reader is neither table owner, superuser, nor BYPASSRLS.
recovery_driver_start
cat >>"$recovery_tmp/driver.sql" <<'SQL'
create temporary table recovery_wrapper_rls_probe (value integer);
insert into pg_temp.recovery_wrapper_rls_probe values (1);
alter table pg_temp.recovery_wrapper_rls_probe enable row level security;
create policy recovery_wrapper_filter on pg_temp.recovery_wrapper_rls_probe using (false);
set role pg_read_all_data;
do $filtered_control$
begin
  if (current_user = 'pg_read_all_data'
    and (select count(*) from pg_temp.recovery_wrapper_rls_probe) = 0) is not true
  then raise exception using errcode = 'P0001', message = 'rls_control'; end if;
end
$filtered_control$;
select 'rls_filtered_control';
SQL
cat >"$recovery_tmp/recovery-history-integrity-query.sql" <<'SQL'
select count(*) from pg_temp.recovery_wrapper_rls_probe;
select 'query_continued_after_rls_error';
SQL
recovery_driver_include
printf '%s\n' "select 'driver_continued_after_rls_error';" >>"$recovery_tmp/after.sql"
recovery_run_probe filtered_visibility_rejected 3 rls_filtered_control 42501

# 4. Message/detail/hint and PL/pgSQL context must all be absent. Query and driver
# sentinels after the error must be unreachable; psql must terminate with status 3.
recovery_driver_start
cat >"$recovery_tmp/recovery-history-integrity-query.sql" <<'SQL'
do $synthetic_context_canary$
begin
  raise exception using errcode = 'P0001', message = 'synthetic_message_canary',
    detail = 'synthetic_detail_canary', hint = 'synthetic_hint_canary';
end
$synthetic_context_canary$;
select 'query_continued_after_canary_error';
SQL
recovery_driver_include
printf '%s\n' "select 'driver_continued_after_canary_error';" >>"$recovery_tmp/after.sql"
recovery_run_probe sqlstate_privacy_and_stop 3 '' P0001

# 5–6. Negative controls mutate only the temporary wrapper copy's BEGIN mode,
# independently exercising each half of the explicit mode guard. Unlike the
# first four probes these are deliberately NOT the byte-identical wrapper.
# Freshness cannot be inferred from flags: pre-existing transactions are outside
# the wrapper's supported fresh top-level --file entry contract.
for recovery_bad_mode in 'repeatable read read write' 'read committed read only'; do
  awk -v mode="$recovery_bad_mode" '
    $0 == "begin transaction isolation level repeatable read read only;" {
      replacements++; print "begin transaction isolation level " mode ";"; next
    }
    { print }
    END { if (replacements != 1) exit 1 }
  ' "$recovery_wrapper" >"$recovery_tmp/recovery-history-integrity.sql" \
    || recovery_fail mode_mutation_requires_one_begin
  if cmp -s "$recovery_wrapper" "$recovery_tmp/recovery-history-integrity.sql"; then
    recovery_fail mode_mutation_not_applied
  fi
  recovery_driver_start
  printf '%s\n' "select 'query_reached_with_invalid_mode';" \
    >"$recovery_tmp/recovery-history-integrity-query.sql"
  recovery_driver_include
  printf '%s\n' "select 'driver_continued_with_invalid_mode';" >>"$recovery_tmp/after.sql"
  recovery_run_probe "mode_guard_rejects_$recovery_bad_mode" 3 '' P0001
done

# Disconnects roll back failed transactions and discard temporary objects. A new
# read-only guard must still observe an empty database; no DROP/CASCADE is needed.
if ! recovery_guard_output="$(recovery_psql -f - <<<"$recovery_guard_sql" 2>&1)"; then
  recovery_fail final_empty_fixture_guard
fi
[[ -z "$recovery_guard_output" ]] || recovery_fail unexpected_final_guard_output
printf '%s\n' 'Four wrapper probes and two mode-guard negative controls passed; actual query and recovery qualification are separate gates.'
