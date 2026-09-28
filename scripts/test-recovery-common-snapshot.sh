#!/usr/bin/env bash
# Synthetic PostgreSQL-17 component test, not an operator/hosted backup command.
set -euo pipefail
umask 077
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

fail() { printf 'recovery_snapshot_assertion: %s\n' "$1" >&2; exit 1; }
[[ $# -eq 0 ]] || fail unexpected_arguments
for wrapper in recovery-history-integrity recovery-state-acceptance; do
  [[ -s "$script_dir/$wrapper.sql" ]] || fail receipt_wrapper_required
done
[[ ${PGHOST:-} == /* && -d ${PGHOST:-} && ${PGHOST:-} != *,* ]] \
  || fail explicit_single_socket_directory_required
[[ ${PGHOST:-} != *$'\n'* && ${PGHOST:-} != *$'\r'* ]] || fail invalid_socket_directory
[[ ${PGUSER:-} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail explicit_fixture_superuser_required
for tool in psql pg_dump pg_restore; do
  [[ $("$tool" --version) == "$tool (PostgreSQL) 17."* ]] || fail postgres17_clients_required
done
absent_password="$script_dir/.no-recovery-test-password"
[[ ! -e "$absent_password" && ! -L "$absent_password" ]] || fail unexpected_password_file

# No inherited credentials, service file, connection options, or psql startup file.
native() {
  local database=$1
  shift
  env -i PATH="$PATH" LC_ALL=C PGHOST="$PGHOST" PGUSER="$PGUSER" \
    PGPORT=5432 PGDATABASE="$database" PGCONNECT_TIMEOUT=5 \
    PGPASSFILE="$absent_password" PGSERVICEFILE=/dev/null \
    PGOPTIONS='-c statement_timeout=10000 -c lock_timeout=5000 -c idle_in_transaction_session_timeout=60000' \
    "$@"
}
sql() {
  local database=$1
  shift
  native "$database" psql -XqAt --no-password --set=ON_ERROR_STOP=on \
    --set=VERBOSITY=sqlstate --set=SHOW_CONTEXT=never "$@"
}
# Wrappers must establish their own fail-closed, privacy-safe error settings.
wrapper_sql() {
  sql "$source_db" --set=ON_ERROR_STOP=off --set=ON_ERROR_ROLLBACK=on \
    --set=VERBOSITY=verbose --set=SHOW_CONTEXT=always "$@"
}
source_db=healthcomp_recovery_fixture
restore_db=healthcomp_snapshot_restored
guard_sql="
begin read only;
select current_database() = 'healthcomp_recovery_fixture'
  and current_setting('server_version_num')::integer / 10000 = 17
  and inet_server_addr() is null and not pg_is_in_recovery()
  and exists (select 1 from pg_roles where rolname = current_user and rolsuper)
  and not exists (select 1 from pg_namespace
    where nspname !~ '^pg_' and nspname not in ('public', 'information_schema'))
  and not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public')
  and not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public')
  and not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public')
  and not exists (select 1 from pg_extension where extname <> 'plpgsql')
  and not exists (select 1 from pg_database where datname = 'healthcomp_snapshot_restored');
rollback;"
guard=$(sql "$source_db" -c "$guard_sql" 2>/dev/null) || fail isolated_empty_postgres17_guard
[[ $guard == t ]] || fail isolated_empty_postgres17_guard

scratch=$(mktemp -d /tmp/healthcomp-recovery-snapshot.XXXXXX)
source_owned=0
restore_owned=0
exporter_pid=''
drop_sql='begin;
drop table recovery_snapshot_probe.entries;
drop table recovery_snapshot_probe.batches;
drop schema recovery_snapshot_probe;
commit;'
stop_exporter() {
  if [[ -n "$exporter_pid" ]]; then
    printf 'rollback;\n\\q\n' >&3
    exec 3>&-
    local result=0
    wait "$exporter_pid" || result=1
    exporter_pid=''
    exec 4>&-
    return "$result"
  fi
}
cleanup() {
  local result=$?
  trap - EXIT
  stop_exporter || result=1
  if [[ $restore_owned -eq 1 ]]; then
    sql "$source_db" -c "drop database $restore_db;" >"$scratch/output" 2>"$scratch/errors" \
      || { printf '%s\n' 'recovery_snapshot_assertion: restore_cleanup_failed' >&2; result=1; }
  fi
  if [[ $source_owned -eq 1 ]]; then
    sql "$source_db" -c "$drop_sql" >"$scratch/output" 2>"$scratch/errors" \
      || { printf '%s\n' 'recovery_snapshot_assertion: source_cleanup_failed' >&2; result=1; }
  fi
  if ! guard=$(sql "$source_db" -c "$guard_sql" 2>/dev/null) || [[ $guard != t ]]; then
    printf '%s\n' 'recovery_snapshot_assertion: final_empty_fixture_guard' >&2
    result=1
  fi
  rm -f -- "$scratch/input" "$scratch/snapshot" "$scratch/archive" \
    "$scratch/output" "$scratch/errors" "$scratch/exporter-errors" \
    "$scratch/recovery-history-integrity.sql" "$scratch/recovery-history-integrity-query.sql" \
    "$scratch/recovery-state-acceptance.sql" "$scratch/recovery-state-acceptance-query.sql" || result=1
  rmdir -- "$scratch" || result=1
  if [[ $result -eq 0 ]]; then
    printf '%s\n' 'Shared-snapshot restore matches the literal receipt; unbound dump mismatch detected; owned fixtures removed.'
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if ! sql "$source_db" >"$scratch/output" 2>"$scratch/errors" <<'SQL'; then
begin;
create schema recovery_snapshot_probe;
create table recovery_snapshot_probe.batches (id integer primary key, label text not null);
create table recovery_snapshot_probe.entries (
  id integer primary key,
  batch_id integer not null references recovery_snapshot_probe.batches,
  value integer not null
);
insert into recovery_snapshot_probe.batches values (1, 'before');
insert into recovery_snapshot_probe.entries values (10, 1, 10), (20, 1, 20);
commit;
SQL
  fail setup_uncertain_dispose_owned_fixture_server
fi
source_owned=1
sql "$source_db" -c "create database $restore_db template template0;" \
  >"$scratch/output" 2>"$scratch/errors" || fail restore_creation_failed
restore_owned=1

# Exact literal expectations are independent of the database query. These rows
# are invented test data; this full-row comparison is not a hosted receipt format.
before=$'batch|1|before\nentry|10|1|10\nentry|20|1|20'
after=$'batch|1|after\nentry|10|1|11\nentry|30|1|30'
receipt_sql="select 'batch|' || id || '|' || label from recovery_snapshot_probe.batches
union all select 'entry|' || id || '|' || batch_id || '|' || value
  from recovery_snapshot_probe.entries order by 1;"
initial=$(sql "$source_db" -c "$receipt_sql" 2>"$scratch/errors") || fail initial_read_failed
[[ $initial == "$before" ]] || fail initial_literal_mismatch

# Open both FIFO ends first so read -t bounds receipt delivery even if psql fails.
# Keep the exporting transaction alive until both receipt and dumps have imported.
mkfifo "$scratch/input" "$scratch/snapshot"
exec 3<>"$scratch/input"
exec 4<>"$scratch/snapshot"
sql "$source_db" <"$scratch/input" >"$scratch/snapshot" 2>"$scratch/exporter-errors" 3>&- 4>&- &
exporter_pid=$!
printf 'begin isolation level repeatable read read only;\nselect pg_export_snapshot();\n' >&3
IFS= read -r -t 10 snapshot <&4 || fail snapshot_not_exported
[[ $snapshot =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{8}-[0-9]+$ ]] || fail invalid_snapshot

# Synchronous commit establishes ordering: all later unbound readers see AFTER.
sql "$source_db" >"$scratch/output" 2>"$scratch/errors" <<'SQL' || fail concurrent_commit_failed
begin;
update recovery_snapshot_probe.batches set label = 'after' where id = 1;
update recovery_snapshot_probe.entries set value = 11 where id = 10;
delete from recovery_snapshot_probe.entries where id = 20;
insert into recovery_snapshot_probe.entries values (30, 1, 30);
commit;
SQL
current=$(sql "$source_db" -c "$receipt_sql" 2>"$scratch/errors") || fail committed_read_failed
[[ $current == "$after" ]] || fail committed_literal_mismatch
receipt=$(sql "$source_db" -c "begin isolation level repeatable read read only;
set transaction snapshot '$snapshot'; $receipt_sql rollback;" 2>"$scratch/errors") \
  || fail receipt_import_failed
[[ $receipt == "$before" ]] || fail receipt_literal_mismatch

# The actual wrappers, with only their relative query include substituted, must
# share the exporter's snapshot. This is wrapper behavior, not query correctness.
for wrapper in recovery-history-integrity recovery-state-acceptance; do
  cp "$script_dir/$wrapper.sql" "$scratch/$wrapper.sql"
  cmp -s "$script_dir/$wrapper.sql" "$scratch/$wrapper.sql" || fail wrapper_copy_mismatch
  printf '%s\n' "$receipt_sql" >"$scratch/$wrapper-query.sql"
  bound=$(wrapper_sql --set="recovery_snapshot=$snapshot" \
    --file="$scratch/$wrapper.sql" 2>"$scratch/errors") || fail bound_wrapper_failed
  [[ ! -s "$scratch/errors" ]] || fail "${wrapper}_bound_stderr"
  [[ $bound == "$before" ]] || fail "${wrapper}_bound_receipt_mismatch"
  unbound=$(wrapper_sql --file="$scratch/$wrapper.sql" 2>"$scratch/errors") \
    || fail unbound_wrapper_failed
  [[ ! -s "$scratch/errors" ]] || fail "${wrapper}_unbound_stderr"
  [[ $unbound == "$after" ]] || fail "${wrapper}_unbound_receipt_mismatch"
  printf 'Passed snapshot binding: %s\n' "$wrapper"
done

reject_snapshot() {
  local rejected=$1 expected_state=$2 wrapper result
  for wrapper in recovery-history-integrity recovery-state-acceptance; do
    result=0
    wrapper_sql --set="recovery_snapshot=$rejected" --file="$scratch/$wrapper.sql" \
      >"$scratch/output" 2>"$scratch/errors" || result=$?
    [[ $result == 3 ]] || fail "${wrapper}_${expected_state}_exit"
    [[ ! -s "$scratch/output" ]] || fail "${wrapper}_${expected_state}_stdout"
    awk -v code="$expected_state" '$0 !~ ("^psql:.*:[0-9]+: ERROR:[[:space:]]+" code "$") {bad=1}
      END {if (bad || NR!=1) exit 1}' "$scratch/errors" \
      || fail "${wrapper}_${expected_state}_error_privacy"
  done
}
reject_snapshot "invalid'; select 'synthetic_snapshot_canary'; --" 22023
reject_snapshot '' XX000
reject_snapshot '   ' 22023

for mode in snapshot current; do
  set --
  if [[ $mode == snapshot ]]; then
    set -- "--snapshot=$snapshot"
  fi
  native "$source_db" pg_dump --no-password --format=custom --strict-names \
    --schema=recovery_snapshot_probe --no-owner --no-privileges \
    --lock-wait-timeout=5s "$@" --file="$scratch/archive" \
    >"$scratch/output" 2>"$scratch/errors" || fail dump_failed
  native "$restore_db" pg_restore --no-password --exit-on-error --single-transaction \
    --no-owner --no-privileges --dbname="$restore_db" "$scratch/archive" \
    >"$scratch/output" 2>"$scratch/errors" || fail restore_failed
  restored=$(sql "$restore_db" -c "$receipt_sql" 2>"$scratch/errors") || fail restore_read_failed
  if [[ $mode == snapshot ]]; then
    [[ $restored == "$receipt" && $restored == "$before" ]] || fail snapshot_restore_receipt_mismatch
  else
    [[ $restored == "$after" && $restored != "$receipt" ]] || fail unbound_dump_not_detected
  fi
  sql "$restore_db" -c "$drop_sql" >"$scratch/output" 2>"$scratch/errors" || fail restore_reset_failed
done
stop_exporter || fail exporter_termination_failed
reject_snapshot "$snapshot" 42704
