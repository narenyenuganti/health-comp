#!/usr/bin/env bash
# Synthetic FK component tests only; never a hosted recovery entry point.
set -euo pipefail
umask 077

recovery_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
recovery_audit="$recovery_script_dir/recovery-foreign-key-integrity.sql"
recovery_fail() {
  printf 'recovery_fk_assertion: %s\n' "$1" >&2
  exit 1
}

# This must precede connection checks, scratch files, and every fixture mutation.
[[ -s "$recovery_audit" ]] || recovery_fail missing_audit_expected_red

if [[ "${1:-}" == --static ]]; then
  [[ "$#" -le 2 ]] || recovery_fail static_arguments
  recovery_runbook="${2:-$recovery_script_dir/../docs/runbooks/backup-restore.md}"
  # Track every code fence so SQL-looking text inside another language remains
  # literal content. Buffer until EOF; ambiguous/unterminated fences never compare.
  if ! awk '
    {
      candidate = $0
      sub(/^ ? ? ?/, "", candidate)
      delimiter = ""; info = ""
      if (match(candidate, /^(```+|~~~+)/)) {
        delimiter = substr(candidate, 1, RLENGTH)
        info = substr(candidate, RLENGTH + 1)
        sub(/^[[:space:]]+/, "", info); sub(/[[:space:]]+$/, "", info)
      }
      if (fence == "" && delimiter != "") {
        fence = substr(delimiter, 1, 1); fence_length = length(delimiter)
        sql_fence = info == "sql"; block = ""; selected = 0; next
      }
      if (fence != "" && substr(delimiter, 1, 1) == fence &&
          length(delimiter) >= fence_length && info == "") {
        if (sql_fence && selected) { matches++; content = block }
        fence = ""; sql_fence = 0; next
      }
      if ($0 == "do $healthcomp_fk_audit$") {
        markers++; if (fence == "" || !sql_fence) bad = 1; selected = 1
      }
      if (fence != "" && sql_fence) block = block $0 ORS
    }
    END {
      if (bad || fence != "" || markers != 1 || matches != 1) exit 1
      printf "%s", content
    }
  ' "$recovery_runbook" | cmp -s "$recovery_audit" -; then
    recovery_fail documented_audit_drift
  fi
  printf '%s\n' 'FK audit documentation is byte-identical; no SQL executed.'
  exit 0
fi

# Default is the separately authorized runtime suite. Static drift is intentionally
# separate: an absent audit body must be observable as a real orphan-case RED.
[[ "$#" -eq 0 ]] || recovery_fail no_connection_arguments_allowed
[[ "${PGHOST:-}" == /* && -d "${PGHOST:-}" && "${PGHOST:-}" != *,* ]] \
  || recovery_fail explicit_single_socket_directory_required
[[ "${PGHOST:-}" != *$'\n'* && "${PGHOST:-}" != *$'\r'* ]] \
  || recovery_fail invalid_socket_directory
[[ "${PGUSER:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
  || recovery_fail explicit_fixture_superuser_required
[[ -s "$recovery_script_dir/tests/recovery-foreign-key-fixtures.sql" ]] \
  || recovery_fail fixture_file_required
command -v psql >/dev/null || recovery_fail psql_required
recovery_absent_password="$recovery_script_dir/.no-recovery-test-password"
[[ ! -e "$recovery_absent_password" && ! -L "$recovery_absent_password" ]] \
  || recovery_fail unexpected_test_password_path

recovery_psql() {
  # Fixed database/port, explicit socket host/user only, no password/config defaults.
  env -i PATH="$PATH" LC_ALL=C PGHOST="$PGHOST" PGUSER="$PGUSER" \
    PGPORT=5432 PGDATABASE=healthcomp_recovery_fixture PGCONNECT_TIMEOUT=5 \
    PGPASSFILE="$recovery_absent_password" PGSERVICEFILE=/dev/null \
    psql -XqAt --no-password "$@"
}

recovery_identity_sql="$(cat <<'SQL'
\set ON_ERROR_STOP on
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
begin read only;
set local statement_timeout = '5s';
do $fixture_identity$
begin
  if current_database() <> 'healthcomp_recovery_fixture'
    or current_setting('server_version_num')::integer / 10000 <> 17
    or inet_server_addr() is not null or pg_catalog.pg_is_in_recovery()
    or not exists (select 1 from pg_catalog.pg_roles where rolname = current_user and rolsuper)
    or not exists (select 1 from pg_catalog.pg_roles
      where rolname = 'pg_read_all_data' and not rolsuper and not rolbypassrls)
  then raise exception using errcode = 'P0001', message = 'isolated_fixture_required'; end if;
end
$fixture_identity$;
rollback;
SQL
)"
recovery_empty_sql="$recovery_identity_sql
$(cat <<'SQL'
begin read only;
set local statement_timeout = '5s';
do $fixture_empty$
begin
  if exists (select 1 from pg_catalog.pg_namespace
      where nspname !~ '^pg_' and nspname not in ('public', 'information_schema'))
    or exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n
      on n.oid = c.relnamespace where n.nspname = 'public')
    or exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n
      on n.oid = p.pronamespace where n.nspname = 'public')
    or exists (select 1 from pg_catalog.pg_type t join pg_catalog.pg_namespace n
      on n.oid = t.typnamespace where n.nspname = 'public')
    or exists (select 1 from pg_catalog.pg_extension where extname <> 'plpgsql')
  then raise exception using errcode = 'P0001', message = 'empty_fixture_required'; end if;
end
$fixture_empty$;
rollback;
SQL
)"
if ! recovery_guard_output="$(recovery_psql -f - <<<"$recovery_empty_sql" 2>&1)"; then
  recovery_fail isolated_empty_postgres17_guard
fi
[[ -z "$recovery_guard_output" ]] || recovery_fail unexpected_guard_output

# This exclusive fixture database must not be shared with another suite. Setup is
# atomic, but committed so every tested audit can use a new top-level connection.
# The exact inventory is five base tables, two inheritance children, a referencing
# partition parent/leaf, a referenced partition parent/two leaves, and two
# initially-absent schemas. All cleanup is RESTRICT.
recovery_tmp="$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-recovery-fk.XXXXXX")"
recovery_fixture_owned=0
recovery_cleanup() {
  local recovery_exit=$?
  trap - EXIT
  if [[ "$recovery_fixture_owned" -eq 1 ]]; then
    if ! {
      printf '%s\n' "$recovery_identity_sql" "begin;" "set local statement_timeout = '5s';" "set local lock_timeout = '5s';"
      cat <<'SQL'
drop table if exists public.recovery_fk_partition_leaf;
drop table if exists public.recovery_fk_partitioned;
drop table if exists public.recovery_fk_target_child;
drop table if exists public.recovery_fk_source_child;
drop table if exists private."recovery fk child";
drop table if exists public.recovery_fk_reverse;
drop table if exists public.recovery_fk_single;
drop table if exists public.recovery_fk_target_low;
drop table if exists public.recovery_fk_target_high;
drop table if exists public.recovery_fk_target_partitioned;
drop table if exists public."recovery fk parent";
drop table if exists recovery_fk_reference.recovery_fk_external;
drop schema if exists private;
drop schema if exists recovery_fk_reference;
commit;
SQL
    } | recovery_psql -f - >"$recovery_tmp/stdout" 2>"$recovery_tmp/stderr"; then
      printf '%s\n' 'recovery_fk_assertion: exact_fixture_cleanup_failed' >&2
      recovery_exit=1
    elif ! recovery_guard_output="$(recovery_psql -f - <<<"$recovery_empty_sql" 2>&1)" \
      || [[ -n "$recovery_guard_output" ]]; then
      printf '%s\n' 'recovery_fk_assertion: final_empty_fixture_guard' >&2
      recovery_exit=1
    fi
  fi
  rm -f -- "$recovery_tmp/session.sql" "$recovery_tmp/after.sql" \
    "$recovery_tmp/audit.sql" "$recovery_tmp/mutant.sql" "$recovery_tmp/settings.sql" \
    "$recovery_tmp/stdout" "$recovery_tmp/stderr"
  rmdir -- "$recovery_tmp"
  exit "$recovery_exit"
}
trap recovery_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

recovery_fixture_sql() {
  local recovery_label="$1"
  if ! {
    printf '%s\n' "$recovery_identity_sql" 'begin;' \
      "set local statement_timeout = '5s';" "set local lock_timeout = '5s';"
    cat
    printf '%s\n' 'commit;'
  } | recovery_psql -f - >"$recovery_tmp/stdout" 2>"$recovery_tmp/stderr"; then
    if [[ "$recovery_label" == base ]]; then
      printf '%s\n' 'Initial setup outcome is uncertain; no automatic database cleanup. Parent must dispose of the exact owned fixture server.' >&2
    fi
    recovery_fail "${recovery_label}_setup"
  fi
  if [[ -s "$recovery_tmp/stdout" || -s "$recovery_tmp/stderr" ]]; then
    if [[ "$recovery_label" == base ]]; then
      printf '%s\n' 'Initial setup output is unexpected; possible residue is not automatically deleted. Parent must inspect or dispose of the exact owned fixture server.' >&2
    fi
    recovery_fail "${recovery_label}_setup_output"
  fi
}

recovery_run() {
  local recovery_label="$1" recovery_expected_exit="$2" recovery_state="${3:-}"
  local recovery_session="${4:-}" recovery_candidate="${5:-$recovery_audit}" recovery_exit=0
  cat >"$recovery_tmp/session.sql" <<'SQL'
\set ON_ERROR_STOP on
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
set statement_timeout = '5s';
set lock_timeout = '5s';
set default_transaction_isolation = 'read committed';
set default_transaction_read_only = off;
set row_security = on;
SQL
  printf '%s\n' "$recovery_session" >>"$recovery_tmp/session.sql"
  cat >>"$recovery_tmp/session.sql" <<'SQL'
\set ON_ERROR_STOP off
\set VERBOSITY verbose
\set SHOW_CONTEXT always
SQL
  : >"$recovery_tmp/after.sql"
  if [[ "$recovery_expected_exit" -ne 0 ]]; then
    # Preserve every byte of the candidate, then append only a test continuation
    # sentinel. Both this and the next top-level source must remain unreachable.
    cp "$recovery_candidate" "$recovery_tmp/audit.sql"
    printf '\n%s\n' "select 'audit_continued';" >>"$recovery_tmp/audit.sql"
    recovery_candidate="$recovery_tmp/audit.sql"
    printf '%s\n' "select 'source_continued';" >"$recovery_tmp/after.sql"
  fi
  recovery_psql -f "$recovery_tmp/session.sql" -f "$recovery_candidate" \
    -f "$recovery_tmp/after.sql" >"$recovery_tmp/stdout" 2>"$recovery_tmp/stderr" || recovery_exit=$?
  [[ "$recovery_exit" -eq "$recovery_expected_exit" ]] || recovery_fail "${recovery_label}_exit"
  [[ ! -s "$recovery_tmp/stdout" ]] || recovery_fail "${recovery_label}_stdout"
  if [[ -z "$recovery_state" ]]; then
    [[ ! -s "$recovery_tmp/stderr" ]] || recovery_fail "${recovery_label}_stderr"
  else
    awk -v code="$recovery_state" '
      $0 !~ ("^psql:.*:[0-9]+: ERROR:[[:space:]]+" code "$") { bad = 1 }
      END { if (bad || NR != 1) exit 1 }
    ' "$recovery_tmp/stderr" || recovery_fail "${recovery_label}_sqlstate_only"
  fi
  printf 'Passed FK probe: %s\n' "$recovery_label"
}

recovery_run empty_audit 0
recovery_fixture_sql base <"$recovery_script_dir/tests/recovery-foreign-key-fixtures.sql"
# Only a confirmed successful atomic setup establishes ownership for cleanup.
recovery_fixture_owned=1
recovery_run native_keys_composites_nulls_ordering_and_external_reference 0

# NOT VALID describes validation history, not whether current rows are valid.
recovery_fixture_sql unvalidated_positive <<'SQL'
alter table public.recovery_fk_single drop constraint "shared fk";
alter table public.recovery_fk_single add constraint "shared fk"
  foreign key (profile_id) references public."recovery fk parent" (id) not valid;
SQL
recovery_run unvalidated_but_valid_rows 0

# Each negative starts from a successful real-FK fixture. Constraints are added
# AFTER the pre-existing synthetic orphan, never disabled on an application table.
recovery_fixture_sql uuid_orphan <<'SQL'
alter table public.recovery_fk_single drop constraint "shared fk";
insert into public.recovery_fk_single (profile_id) values ('00000000-0000-0000-0000-000000000099');
alter table public.recovery_fk_single add constraint "shared fk"
  foreign key (profile_id) references public."recovery fk parent" (id) not valid;
SQL
recovery_run uuid_orphan 3 23503
recovery_fixture_sql uuid_repair <<'SQL'
delete from public.recovery_fk_single where profile_id = '00000000-0000-0000-0000-000000000099';
alter table public.recovery_fk_single validate constraint "shared fk";
SQL
recovery_run uuid_repaired 0

recovery_fixture_sql bigint_orphan <<'SQL'
alter table public.recovery_fk_single drop constraint recovery_fk_sequence;
insert into public.recovery_fk_single (server_seq) values (999);
alter table public.recovery_fk_single add constraint recovery_fk_sequence
  foreign key (server_seq) references public."recovery fk parent" (server_seq) not valid;
SQL
recovery_run bigint_orphan 3 23503
recovery_fixture_sql bigint_repair <<'SQL'
delete from public.recovery_fk_single where server_seq = 999;
alter table public.recovery_fk_single validate constraint recovery_fk_sequence;
SQL
recovery_run bigint_repaired 0

recovery_fixture_sql composite_orphan <<'SQL'
alter table private."recovery fk child" drop constraint "shared fk";
insert into private."recovery fk child" values (44, 11);
alter table private."recovery fk child" add constraint "shared fk"
  foreign key ("first""key", "second key") references public."recovery fk parent" ("first key", "second key") not valid;
SQL
recovery_run private_cross_tuple_orphan 3 23503
recovery_fixture_sql composite_repair <<'SQL'
delete from private."recovery fk child" where "second key" = 44 and "first""key" = 11;
alter table private."recovery fk child" validate constraint "shared fk";
SQL
recovery_run private_repaired 0

recovery_fixture_sql reversed_orphan <<'SQL'
alter table public.recovery_fk_reverse drop constraint "shared fk";
insert into public.recovery_fk_reverse values (11, 22);
alter table public.recovery_fk_reverse add constraint "shared fk"
  foreign key (first_key, second_key) references public."recovery fk parent" ("second key", "first key") not valid;
SQL
recovery_run reversed_mapping_orphan 3 23503
recovery_fixture_sql reversed_repair <<'SQL'
delete from public.recovery_fk_reverse where first_key = 11 and second_key = 22;
alter table public.recovery_fk_reverse validate constraint "shared fk";
SQL
recovery_run reversed_repaired 0

# A valid outside-schema reference must pass; an orphan referencing it must fail.
recovery_fixture_sql external_orphan <<'SQL'
alter table public.recovery_fk_single drop constraint recovery_fk_external;
insert into public.recovery_fk_single (external_id) values ('00000000-0000-0000-0000-000000000099');
alter table public.recovery_fk_single add constraint recovery_fk_external
  foreign key (external_id) references recovery_fk_reference.recovery_fk_external (id) not valid;
SQL
recovery_run external_target_orphan 3 23503
recovery_fixture_sql external_repair <<'SQL'
delete from public.recovery_fk_single where external_id = '00000000-0000-0000-0000-000000000099';
alter table public.recovery_fk_single validate constraint recovery_fk_external;
SQL
recovery_run external_repaired 0

recovery_fixture_sql match_full <<'SQL'
alter table public.recovery_fk_single drop constraint "shared fk";
alter table public.recovery_fk_single add constraint "shared fk"
  foreign key (profile_id) references public."recovery fk parent" (id) match full;
SQL
recovery_run unsupported_match_full 3 0A000
recovery_fixture_sql match_simple <<'SQL'
alter table public.recovery_fk_single drop constraint "shared fk";
alter table public.recovery_fk_single add constraint "shared fk"
  foreign key (profile_id) references public."recovery fk parent" (id) match simple;
alter table public.recovery_fk_single add constraint recovery_fk_text
  foreign key (text_key) references recovery_fk_reference.recovery_fk_external (text_key);
SQL
recovery_run unsupported_valid_text_key 3 0A000
recovery_fixture_sql native_restore <<'SQL'
alter table public.recovery_fk_single drop constraint recovery_fk_text;
SQL
recovery_run native_restored 0

# Ordinary inheritance does not inherit FKs. Descendant-only source rows are not
# constrained by their parent's FK and must not be misclassified as its orphans.
recovery_fixture_sql source_inheritance <<'SQL'
create table public.recovery_fk_source_child () inherits (public.recovery_fk_single);
insert into public.recovery_fk_source_child (profile_id) values ('00000000-0000-0000-0000-000000000099');
SQL
recovery_run referencing_child_excluded 0
recovery_fixture_sql target_inheritance <<'SQL'
create table public.recovery_fk_target_child () inherits (public."recovery fk parent");
insert into public.recovery_fk_target_child (id) values ('00000000-0000-0000-0000-000000000099');
alter table public.recovery_fk_single drop constraint "shared fk";
-- INSERT already targets only the named relation, unlike SELECT/DELETE.
insert into public.recovery_fk_single (profile_id) values ('00000000-0000-0000-0000-000000000099');
alter table public.recovery_fk_single add constraint "shared fk"
  foreign key (profile_id) references public."recovery fk parent" (id) not valid;
SQL
recovery_run referenced_child_cannot_satisfy_fk 3 23503
recovery_fixture_sql inheritance_repair <<'SQL'
delete from only public.recovery_fk_single where profile_id = '00000000-0000-0000-0000-000000000099';
alter table public.recovery_fk_single validate constraint "shared fk";
drop table public.recovery_fk_target_child;
drop table public.recovery_fk_source_child;
SQL
recovery_run inheritance_repaired 0

recovery_fixture_sql partition_shape <<'SQL'
create table public.recovery_fk_partitioned (profile_id uuid,
  constraint recovery_fk_partition foreign key (profile_id) references public."recovery fk parent" (id)
) partition by hash (profile_id);
create table public.recovery_fk_partition_leaf partition of public.recovery_fk_partitioned
  for values with (modulus 1, remainder 0);
insert into public.recovery_fk_partitioned values ('00000000-0000-0000-0000-000000000001');
SQL
recovery_run unsupported_partition_and_clone 3 0A000
recovery_fixture_sql partition_cleanup <<'SQL'
drop table public.recovery_fk_partition_leaf;
drop table public.recovery_fk_partitioned;
SQL
recovery_run partition_removed 0

# Referenced partitions are a distinct unsupported shape from a partitioned
# referencing table. Both native bigint rows are valid under the real FK.
recovery_fixture_sql target_partition_shape <<'SQL'
create table public.recovery_fk_target_partitioned (server_seq bigint primary key)
  partition by range (server_seq);
create table public.recovery_fk_target_low partition of public.recovery_fk_target_partitioned
  for values from (minvalue) to (10);
create table public.recovery_fk_target_high partition of public.recovery_fk_target_partitioned
  for values from (10) to (maxvalue);
insert into public.recovery_fk_target_partitioned values (1), (9223372036854775806);
alter table public.recovery_fk_single drop constraint recovery_fk_sequence;
alter table public.recovery_fk_single add constraint recovery_fk_sequence
  foreign key (server_seq) references public.recovery_fk_target_partitioned (server_seq);
SQL
recovery_run unsupported_referenced_partition 3 0A000
recovery_fixture_sql target_partition_cleanup <<'SQL'
alter table public.recovery_fk_single drop constraint recovery_fk_sequence;
alter table public.recovery_fk_single add constraint recovery_fk_sequence
  foreign key (server_seq) references public."recovery fk parent" (server_seq);
drop table public.recovery_fk_target_low;
drop table public.recovery_fk_target_high;
drop table public.recovery_fk_target_partitioned;
SQL
recovery_run referenced_partition_removed 0

# SELECT as the existing non-bypass reader is proved before enabling each policy.
# No roles, memberships or grants are created or changed.
recovery_reader_control="$(cat <<'SQL'
set role pg_read_all_data;
do $reader_control$
begin
  if (select count(*) from private."recovery fk child") <> 5
    or (select count(*) from public."recovery fk parent") <> 2
  then raise exception 'reader_control'; end if;
end
$reader_control$;
SQL
)"
recovery_run reader_has_complete_select 0 '' "$recovery_reader_control"
recovery_fixture_sql source_rls <<'SQL'
alter table private."recovery fk child" enable row level security;
create policy recovery_fk_filter on private."recovery fk child" using (false);
SQL
recovery_run source_rls_owner_control 0
recovery_filtered_source="$(cat <<'SQL'
set role pg_read_all_data;
do $filtered_control$
begin
  if (select count(*) from private."recovery fk child") <> 0
    or (select count(*) from public."recovery fk parent") <> 2
  then raise exception 'filtered_control'; end if;
end
$filtered_control$;
SQL
)"
recovery_run source_filtered_visibility 3 42501 "$recovery_filtered_source"
recovery_fixture_sql target_rls <<'SQL'
drop policy recovery_fk_filter on private."recovery fk child";
alter table private."recovery fk child" disable row level security;
alter table public."recovery fk parent" enable row level security;
create policy recovery_fk_filter on public."recovery fk parent" using (false);
SQL
recovery_run target_rls_owner_control 0
recovery_filtered_target="$(cat <<'SQL'
set role pg_read_all_data;
do $filtered_control$
begin
  if (select count(*) from private."recovery fk child") <> 5
    or (select count(*) from public."recovery fk parent") <> 0
  then raise exception 'filtered_control'; end if;
end
$filtered_control$;
SQL
)"
recovery_run target_filtered_visibility 3 42501 "$recovery_filtered_target"
recovery_fixture_sql rls_restore <<'SQL'
drop policy recovery_fk_filter on public."recovery fk parent";
alter table public."recovery fk parent" disable row level security;
SQL
recovery_run visibility_restored 0

# Explicit origin/mode guards: mutate only temporary copies and use fresh files.
recovery_run replica_origin_rejected 3 P0001 'set session_replication_role = replica;'
for recovery_mode in 'repeatable read read write' 'read committed read only'; do
  awk -v mode="$recovery_mode" '
    $0 == "begin transaction isolation level repeatable read read only;" {
      replacements++; print "begin transaction isolation level " mode ";"; next
    }
    { print }
    END { if (replacements != 1) exit 1 }
  ' "$recovery_audit" >"$recovery_tmp/mutant.sql" || recovery_fail mode_mutation_shape
  recovery_run "mode_guard_$recovery_mode" 3 P0001 '' "$recovery_tmp/mutant.sql"
done

# Read the actual effective timeout immediately before the real audit body. This
# instrumented copy is not credited as the unchanged-file algorithm test above.
awk '
  $0 == "do $healthcomp_fk_audit$" {
    matches++
    print "do $timeout_probe$ begin"
    print "if current_setting('\''statement_timeout'\'') <> '\''30s'\'' then"
    print "raise exception using errcode = '\''P0001'\'', message = '\''timeout_probe'\'';"
    print "end if; end $timeout_probe$;"
  }
  { print }
  END { if (matches != 1) exit 1 }
' "$recovery_audit" >"$recovery_tmp/settings.sql" || recovery_fail timeout_probe_shape
recovery_run effective_timeout 0 '' '' "$recovery_tmp/settings.sql"
awk '
  $0 == "set local statement_timeout = '\''30s'\'';" {
    replacements++; print "set local statement_timeout = '\''1s'\'';"; next
  }
  { print }
  END { if (replacements != 1) exit 1 }
' "$recovery_tmp/settings.sql" >"$recovery_tmp/mutant.sql" || recovery_fail timeout_mutation_shape
recovery_run incorrect_timeout_rejected 3 P0001 '' "$recovery_tmp/mutant.sql"

# Error-control instrumentation has an explicit synthetic canary, never real rows.
# Start from the actual wrapper prefix/body; error and continuation checks remain
# exact. Removing either psql privacy control would expose non-allowlisted lines.
awk '
  $0 == "do $healthcomp_fk_audit$" {
    matches++
    print "do $privacy_probe$ begin"
    print "raise exception using errcode = '\''P0001'\'', message = '\''synthetic_message'\'',"
    print "detail = '\''synthetic_detail'\'', hint = '\''synthetic_hint'\'';"
    print "end $privacy_probe$;"
  }
  { print }
  END { if (matches != 1) exit 1 }
' "$recovery_audit" >"$recovery_tmp/mutant.sql" || recovery_fail privacy_probe_shape
recovery_run privacy_and_stop_controls 3 P0001 '' "$recovery_tmp/mutant.sql"

# Prove the output/continuation checks reject broken controls. These copies are
# deliberately expected to violate the operator contract, never credited as passes.
cp "$recovery_tmp/mutant.sql" "$recovery_tmp/settings.sql"
awk '
  $0 == "\\set ON_ERROR_STOP on" { replacements++; print "\\set ON_ERROR_STOP off"; next }
  { print }
  END { if (replacements != 1) exit 1 }
' "$recovery_tmp/settings.sql" >"$recovery_tmp/mutant.sql" || recovery_fail stop_mutation_shape
printf '\n%s\n' "select 'audit_continued';" >>"$recovery_tmp/mutant.sql"
recovery_exit=0
recovery_psql -f "$recovery_tmp/session.sql" -f "$recovery_tmp/mutant.sql" \
  -f "$recovery_tmp/after.sql" >"$recovery_tmp/stdout" 2>"$recovery_tmp/stderr" || recovery_exit=$?
[[ "$recovery_exit" -eq 0 && "$(<"$recovery_tmp/stdout")" == $'audit_continued\nsource_continued' ]] \
  || recovery_fail disabled_stop_control_not_observed
printf '%s\n' 'Rejected FK control mutation: stop_disabled'

awk '
  $0 == "\\set VERBOSITY sqlstate" { replacements++; print "\\set VERBOSITY verbose"; next }
  { print }
  END { if (replacements != 1) exit 1 }
' "$recovery_tmp/settings.sql" >"$recovery_tmp/mutant.sql" || recovery_fail verbosity_mutation_shape
recovery_exit=0
recovery_psql -f "$recovery_tmp/session.sql" -f "$recovery_tmp/mutant.sql" \
  -f "$recovery_tmp/after.sql" >"$recovery_tmp/stdout" 2>"$recovery_tmp/stderr" || recovery_exit=$?
[[ "$recovery_exit" -eq 3 && ! -s "$recovery_tmp/stdout" ]] \
  || recovery_fail verbose_control_exit
for recovery_canary in synthetic_message synthetic_detail synthetic_hint; do
  grep -Fq "$recovery_canary" "$recovery_tmp/stderr" || recovery_fail verbose_control_not_observed
done
printf '%s\n' 'Rejected FK control mutation: verbose_errors'

# Cleanup is also performed on failure; success is reported only after its final
# empty-catalog check. These results never qualify hosted/history/deletion gates.
printf '%s\n' 'Synthetic FK assertions finished; exact fixture cleanup follows.'
