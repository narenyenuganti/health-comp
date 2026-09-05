#!/usr/bin/env bash
# Synthetic component qualification only; never a restore or hosted-state receipt.
set -euo pipefail
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
operator="$script_dir/recovery-state-acceptance.sql"
query="$script_dir/recovery-state-acceptance-query.sql"
fixture="$script_dir/tests/recovery-state-fixtures.sql"
policy_source="$script_dir/../supabase/migrations/20260811000200_add_competition_rls.sql"

fail() { printf '%s\n' "$1" >&2; exit 1; }

# Deliberately precedes every connection, temporary directory, and fixture write.
[[ -s "$operator" ]] || fail missing_operator_expected_red
[[ -s "$query" ]] || fail missing_query_expected_red
[[ -s "$fixture" && -s "$policy_source" ]] || fail fixture_source_required

source_policies() {
  awk '
    /^create policy / { if (inside) bad=1; inside=1; count++ }
    inside { print; if (/;$/) inside=0 }
    END { if (bad || inside || count != 8) exit 1 }
  ' "$policy_source"
}

# The operator contract is intentionally a flat number-only object. A strict,
# dependency-free parser rejects leaked strings, duplicate/unknown/missing keys,
# negative/fractional values, additional output, and false zero-count candidates.
receipt_keys='receipt_version application_tables_checked application_tables_missing_or_unsupported application_tables_unexpected rls_flag_mismatches table_privilege_mismatches column_privilege_mismatches policy_mismatches profiles_checked profiles_invalid_shape profiles_anonymized deletion_records_checked deletion_records_invalid_shape deletion_phase_profile_mismatches deletions_prepared deletions_token_ready deletions_apple_revoked deletions_auth_delete_pending deletions_completed anonymized_profiles_without_completed_deletion deactivated_profiles_with_active_installations deactivated_profiles_with_live_notification_work deactivated_profiles_with_mute_links deactivated_profiles_with_app_attest_rows revoked_installations_with_app_attest_rows anonymized_profiles_with_nonanonymized_participants deactivated_profiles_with_unfinished_competitions deactivated_profiles_with_unconsumed_cancelled_invites completed_deletions_with_bad_completion_event_count completion_events_without_completed_deletion anonymized_profiles_in_results'
empty_expected='receipt_version=1,application_tables_checked=17'
seed_expected="$empty_expected,profiles_checked=7,profiles_anonymized=2,deletion_records_checked=5,deletions_prepared=1,deletions_token_ready=1,deletions_apple_revoked=1,deletions_auth_delete_pending=1,deletions_completed=1,anonymized_profiles_without_completed_deletion=1,anonymized_profiles_in_results=2"
receipt_matches() {
  awk -v keys="$receipt_keys" -v expected="$1" -v unsupported="${2:-0}" '
    BEGIN {
      n=split(keys, names, " "); if (n != 31) exit 1
      for (i=1; i<=n; i++) { allowed[names[i]]=1; wanted[names[i]]="0" }
      m=split(expected, pairs, ",")
      for (i=1; i<=m; i++) {
        if (split(pairs[i], pair, "=") != 2 || !(pair[1] in allowed) ||
            pair[2] !~ /^(0|[1-9][0-9]*)$/) exit 1
        wanted[pair[1]]=pair[2]
      }
    }
    {
      line=$0; sub(/^[[:space:]]*/, "", line); sub(/[[:space:]]*$/, "", line)
      if (NR != 1 || line !~ /^\{.*\}$/) { bad=1; next }
      line=substr(line,2,length(line)-2); m=split(line, entries, ",")
      if (m != n) { bad=1; next }
      for (i=1; i<=m; i++) {
        entry=entries[i]
        if (entry !~ /^[[:space:]]*"[a-z_]+"[[:space:]]*:[[:space:]]*(0|[1-9][0-9]*)[[:space:]]*$/) { bad=1; continue }
        split(entry, pair, ":"); key=pair[1]; value=pair[2]
        gsub(/[[:space:]"]/, "", key); gsub(/[[:space:]]/, "", value)
        if (!(key in allowed) || seen[key]++) bad=1
        actual[key]=value
        if (!unsupported && "x" value != "x" wanted[key]) bad=1
      }
    }
    END {
      if (NR != 1 || bad) exit 1
      for (key in allowed) if (!(key in seen)) exit 1
      if (unsupported && (actual["receipt_version"] != 1 ||
          actual["application_tables_missing_or_unsupported"] < 1)) exit 1
    }
  '
}
expected_rows() {
  printf '%s' "$seed_expected"
  [[ -z "$1" ]] || printf ',%s' "$1"
}
static_receipt_controls() {
  local good bad
  good="$(awk -v keys="$receipt_keys" -v expected="$seed_expected" 'BEGIN {
    n=split(keys,names," "); m=split(expected,pairs,",")
    for(i=1;i<=m;i++) {split(pairs[i],p,"="); values[p[1]]=p[2]}
    printf "{"; for(i=1;i<=n;i++) printf "%s\"%s\":%s",(i==1?"":","),names[i],((names[i] in values)?values[names[i]]:0)
    print "}"
  }')"
  receipt_matches "$(expected_rows '')" <<<"$good" || fail static_no_override_receipt
  bad="${good/\"profiles_invalid_shape\":0/\"profiles_invalid_shape\":1}"
  receipt_matches "$(expected_rows profiles_invalid_shape=1)" <<<"$bad" || fail static_override_receipt
  if receipt_matches "$(expected_rows profiles_invalid_shape=1)" <<<"$good"; then fail static_false_zero_accepted; fi
  for bad in \
    "${good/\"receipt_version\":1/\"receipt_version\":1,\"receipt_version\":1}" \
    "${good/\"receipt_version\":1/\"unexpected_key\":1}" \
    "${good/\"receipt_version\":1/\"receipt_version\":\"1\"}" \
    "${good/\"receipt_version\":1/\"receipt_version\":null}" \
    "${good/\"receipt_version\":1/\"receipt_version\":-1}" \
    "${good/\"receipt_version\":1/\"receipt_version\":1.5}" \
    "${good/\"receipt_version\":1/\"receipt_version\":1e0}" \
    "$good"$'\n'"$good"; do
    if receipt_matches "$seed_expected" <<<"$bad"; then fail static_invalid_receipt_accepted; fi
  done
}

if [[ ${1:-} == --static && $# == 1 ]]; then
  bash -n "$0"
  source_policies >/dev/null || fail source_policy_inventory
  static_receipt_controls
  printf '%s\n' recovery_state_static_ok
  exit 0
fi
if [[ ${1:-} == --check-empty-receipt && $# == 1 ]]; then
  receipt_matches "$empty_expected" || fail migrated_empty_receipt
  exit 0
fi
[[ $# == 0 ]] || fail unexpected_arguments
[[ ${PGHOST:-} == /* && -d ${PGHOST:-} && ${PGHOST:-} != *,* ]] \
  || fail explicit_single_socket_directory_required
[[ ${PGHOST:-} != *$'\n'* && ${PGHOST:-} != *$'\r'* ]] || fail invalid_socket_directory
[[ ${PGUSER:-} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail explicit_fixture_superuser_required
command -v psql >/dev/null || fail psql_required
absent_password="$script_dir/.no-recovery-test-password"
[[ ! -e "$absent_password" && ! -L "$absent_password" ]] || fail unexpected_test_password_path
fixture_psql() {
  env -i PATH="$PATH" LC_ALL=C PGHOST="$PGHOST" PGUSER="$PGUSER" \
    PGPORT=5432 PGDATABASE=healthcomp_recovery_fixture PGCONNECT_TIMEOUT=5 \
    PGPASSFILE="$absent_password" PGSERVICEFILE=/dev/null \
    psql -XqAt --no-password "$@"
}
identity_sql="$(cat <<'SQL'
\set ON_ERROR_STOP on
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
begin read only;
set local statement_timeout = '5s';
do $identity$
begin
  if current_database() <> 'healthcomp_recovery_fixture'
    or current_setting('server_version_num')::integer / 10000 <> 17
    or inet_server_addr() is not null or pg_catalog.pg_is_in_recovery()
    or not exists (select 1 from pg_catalog.pg_roles where rolname=current_user and rolsuper)
    or not exists (select 1 from pg_catalog.pg_roles
      where rolname='pg_read_all_data' and not rolsuper and not rolbypassrls)
  then raise exception using errcode='P0001', message='isolated_fixture_required'; end if;
end $identity$;
rollback;
SQL
)"
empty_sql="$identity_sql
$(cat <<'SQL'
begin read only;
set local statement_timeout = '5s';
do $empty$
begin
  if exists (select 1 from pg_catalog.pg_namespace where nspname !~ '^pg_'
      and nspname not in ('public','information_schema'))
    or exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n
      on n.oid=c.relnamespace where n.nspname='public')
    or exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n
      on n.oid=p.pronamespace where n.nspname='public')
    or exists (select 1 from pg_catalog.pg_type t join pg_catalog.pg_namespace n
      on n.oid=t.typnamespace where n.nspname='public')
    or exists (select 1 from pg_catalog.pg_extension where extname <> 'plpgsql')
    or exists (select 1 from pg_catalog.pg_roles where rolname='healthcomp_recovery_state_inherited')
  then raise exception using errcode='P0001', message='empty_fixture_required'; end if;
end $empty$;
rollback;
SQL
)"
if ! guard_output="$(fixture_psql -f - <<<"$empty_sql" 2>&1)"; then
  fail isolated_empty_postgres17_guard
fi
[[ -z "$guard_output" ]] || fail unexpected_guard_output

# Cluster roles may predate this fixture. Snapshot attributes and memberships
# without passwords, and create/drop only roles confirmed absent beforehand.
role_snapshot_sql="select jsonb_build_object(
 'roles',(select coalesce(jsonb_agg(to_jsonb(r)-'rolpassword' order by rolname),'[]')
   from pg_catalog.pg_roles r where rolname in ('anon','authenticated','service_role')),
 'memberships',(select coalesce(jsonb_agg(to_jsonb(m) order by roleid,member,grantor),'[]')
   from pg_catalog.pg_auth_members m where roleid in
     (select oid from pg_catalog.pg_roles where rolname in ('anon','authenticated','service_role'))
   or member in (select oid from pg_catalog.pg_roles where rolname in ('anon','authenticated','service_role'))));"
if ! roles_before="$(fixture_psql -v ON_ERROR_STOP=1 -c "$role_snapshot_sql" 2>/dev/null)"; then
  fail role_snapshot_before
fi
if ! created_roles="$(fixture_psql -v ON_ERROR_STOP=1 -c "select name from
 (values ('anon'),('authenticated'),('service_role')) wanted(name)
 where not exists(select 1 from pg_catalog.pg_roles where rolname=name) order by name;" 2>/dev/null)"; then
  fail absent_role_inventory
fi
tmp="$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-recovery-state.XXXXXX")"
owned=0
cleanup() {
  local result=$? role_name
  trap - EXIT
  if [[ $owned == 1 ]]; then
    if ! {
      printf '%s\n' "$identity_sql" 'begin;' "set local statement_timeout='5s';" "set local lock_timeout='5s';"
      cat <<'SQL'
drop table if exists public.recovery_state_child;
drop view if exists public.recovery_state_view;
drop table if exists public.recovery_state_extra;
drop table if exists public.recovery_state_saved;
drop table if exists public.profiles, public.competitions, public.competition_participants,
 public.competition_invites, public.competition_change_log, public.daily_score_revisions,
 public.participant_finalization_attestations, public.competition_results,
 public.competition_awards, public.device_installations, public.support_events,
 private.competition_notification_mutes, private.competition_notification_work,
 private.account_deletions, private.app_attest_keys, private.app_attest_challenges,
 private.app_attest_submission_grants;
drop function private.current_profile_id(), private.can_view_profile(uuid), private.is_competition_participant(uuid);
drop schema private;
drop role healthcomp_recovery_state_inherited;
SQL
      while IFS= read -r role_name; do
        [[ -n $role_name ]] || continue
        case "$role_name" in anon|authenticated|service_role) printf 'drop role %s;\n' "$role_name";; *) exit 1;; esac
      done <<<"$created_roles"
      printf '%s\n' 'commit;'
    } | fixture_psql -f - >"$tmp/stdout" 2>"$tmp/stderr"; then
      printf '%s\n' exact_fixture_cleanup_failed >&2; result=1
    elif ! guard_output="$(fixture_psql -f - <<<"$empty_sql" 2>&1)" || [[ -n "$guard_output" ]]; then
      printf '%s\n' final_empty_fixture_guard >&2; result=1
    elif ! roles_after="$(fixture_psql -v ON_ERROR_STOP=1 -c "$role_snapshot_sql" 2>/dev/null)" \
      || [[ "$roles_after" != "$roles_before" ]]; then
      printf '%s\n' preexisting_roles_or_memberships_changed >&2; result=1
    fi
  fi
  rm -f -- "$tmp/driver.sql" "$tmp/after.sql" "$tmp/stdout" "$tmp/stderr" \
    "$tmp/recovery-state-acceptance.sql" "$tmp/recovery-state-acceptance-query.sql"
  rmdir -- "$tmp"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mutate() {
  local label="$1"
  if ! {
    printf '%s\n' "$identity_sql" 'begin;' "set local statement_timeout='5s';" "set local lock_timeout='5s';"
    cat
    printf '%s\n' 'commit;'
  } | fixture_psql -f - >"$tmp/stdout" 2>"$tmp/stderr"; then
    [[ "$label" != base ]] || printf '%s\n' 'Setup ownership uncertain: parent must dispose of the exact owned fixture server; no automatic database cleanup.' >&2
    fail "${label}_setup"
  fi
  if [[ -s "$tmp/stdout" || -s "$tmp/stderr" ]]; then
    [[ "$label" != base ]] || printf '%s\n' 'Setup ownership uncertain: parent must dispose of the exact owned fixture server; no automatic database cleanup.' >&2
    fail "${label}_setup_output"
  fi
}
seed() {
  { printf '%s\n' '\set build_schema false' '\set seed_rows true'; cat "$fixture"; } | mutate reseed
}
driver() {
  printf '%s\n' "$identity_sql" >"$tmp/driver.sql"
  cat >>"$tmp/driver.sql" <<'SQL'
set statement_timeout='5s';
set lock_timeout='5s';
set default_transaction_isolation='read committed';
set default_transaction_read_only=off;
set session_replication_role=origin;
set row_security=on;
set time zone 'Pacific/Honolulu';
set search_path=public;
SQL
  : >"$tmp/after.sql"
}
adverse_psql() {
  cat >>"$tmp/driver.sql" <<'SQL'
\set ON_ERROR_STOP off
\set ON_ERROR_ROLLBACK on
\set VERBOSITY verbose
\set SHOW_CONTEXT always
SQL
}
run_receipt() {
  local label="$1" expected="$2" candidate="${3:-$operator}" session="${4:-}" result=0
  driver
  printf '%s\n' "$session" >>"$tmp/driver.sql"
  adverse_psql
  fixture_psql -f "$tmp/driver.sql" -f "$candidate" >"$tmp/stdout" 2>"$tmp/stderr" || result=$?
  [[ $result == 0 ]] || fail "${label}_exit"
  [[ ! -s "$tmp/stderr" ]] || fail "${label}_stderr"
  receipt_matches "$expected" <"$tmp/stdout" || fail "${label}_receipt"
  printf 'Passed state probe: %s\n' "$label"
}
case_rows() {
  local label="$1" expected="$2"
  seed
  mutate "$label"
  run_receipt "$label" "$(expected_rows "$expected")"
}
case_metadata() {
  local label="$1" expected="$2" change="$3" undo="$4"
  mutate "$label" <<<"$change"
  run_receipt "$label" "$seed_expected,$expected"
  mutate "${label}_undo" <<<"$undo"
  run_receipt "${label}_restored" "$seed_expected"
}

{
  # No ALTER ROLE or modification of existing membership/role attributes.
  while IFS= read -r role_name; do
    [[ -n $role_name ]] || continue
    case "$role_name" in anon|authenticated|service_role) printf 'create role %s nologin;\n' "$role_name";; *) exit 1;; esac
  done <<<"$created_roles"
  printf '%s\n' 'create role healthcomp_recovery_state_inherited nologin;' \
    '\set build_schema true' '\set seed_rows false'
  cat "$fixture"
  source_policies
} | mutate base
owned=1
run_receipt clean_empty "$empty_expected"
mutate malformed_canary <<'SQL'
insert into public.profiles values (md5('canary')::uuid, md5('canary-auth')::uuid,
 'Former competitor', 'active', null, '2026-09-01+00', '2026-09-01+00');
SQL
run_receipt malformed_profile_canary "$empty_expected,profiles_checked=1,profiles_invalid_shape=1"
seed
run_receipt every_phase_and_unaffected_controls "$seed_expected"

# Each expected vector starts with the complete baseline, then overrides explicit
# affected counters. Every unrelated field must remain unchanged, not merely >=0.
case_rows reserved_active_name profiles_invalid_shape=1 <<'SQL'
update public.profiles set display_name='Former competitor' where id=md5('profile-6')::uuid;
SQL
for assignment in "display_name=null" "display_name='   '" "state=null" "state='unknown'" "auth_user_id=null" "anonymized_at='2026-09-01+00'" "id=null"; do
  case_rows "active_shape_$assignment" profiles_invalid_shape=1 <<<"update public.profiles set $assignment where id=md5('profile-6')::uuid;"
done
for assignment in "display_name=null" "display_name='Synthetic retained name'" "auth_user_id=md5('unexpected-auth')::uuid" "anonymized_at=null"; do
  case_rows "anonymous_shape_$assignment" profiles_invalid_shape=1 <<<"update public.profiles set $assignment where id=md5('profile-5')::uuid;"
done
for assignment in "apple_provider_id=null" "apple_provider_id=' '" "apple_provider_id=E'bad\\nidentity'" "apple_provider_id=repeat('x',256)" "completed_at='2026-09-01+00'" "started_at=null" "updated_at=null" "updated_at=started_at-interval '1 second'"; do
  case_rows "pending_deletion_shape_$assignment" deletion_records_invalid_shape=1 <<<"update private.account_deletions set $assignment where profile_id=md5('profile-4')::uuid;"
done
case_rows pending_private_auth_missing deletion_records_invalid_shape=1 <<'SQL'
update private.account_deletions set auth_user_id=null where profile_id=md5('profile-4')::uuid;
SQL
for assignment in "auth_user_id=md5('unexpected-auth')::uuid" "apple_provider_id='synthetic-leftover'" "completed_at=null" "completed_at=started_at-interval '1 second'"; do
  case_rows "completed_deletion_shape_$assignment" deletion_records_invalid_shape=1 <<<"update private.account_deletions set $assignment where profile_id=md5('profile-5')::uuid;"
done
case_rows prepared_auth_link_mismatch deletion_phase_profile_mismatches=1 <<'SQL'
update private.account_deletions set auth_user_id=md5('different-auth')::uuid where profile_id=md5('profile-1')::uuid;
SQL
case_rows token_auth_link_mismatch deletion_phase_profile_mismatches=1 <<'SQL'
update private.account_deletions set auth_user_id=md5('different-auth')::uuid where profile_id=md5('profile-2')::uuid;
SQL
case_rows apple_auth_link_mismatch deletion_phase_profile_mismatches=1 <<'SQL'
update private.account_deletions set auth_user_id=md5('different-auth')::uuid where profile_id=md5('profile-3')::uuid;
SQL
case_rows token_profile_still_active deletion_phase_profile_mismatches=1 <<'SQL'
update public.profiles set state='active' where id=md5('profile-2')::uuid;
SQL
for phase_value in null "'unknown'"; do
  case_rows "invalid_phase_$phase_value" 'deletions_token_ready=0,deletion_records_invalid_shape=1,deletion_phase_profile_mismatches=1' \
    <<<"update private.account_deletions set phase=$phase_value where profile_id=md5('profile-2')::uuid;"
done
case_rows missing_profile 'profiles_checked=6,deletion_phase_profile_mismatches=1' <<'SQL'
delete from public.profiles where id=md5('profile-2')::uuid;
SQL
case_rows missing_deleting_deletion 'deletion_records_checked=4,deletions_token_ready=0,deletion_phase_profile_mismatches=1' <<'SQL'
delete from private.account_deletions where profile_id=md5('profile-2')::uuid;
SQL
case_rows anonymous_without_completed_row 'deletion_records_checked=4,deletions_completed=0,deletion_phase_profile_mismatches=1,anonymized_profiles_without_completed_deletion=2,completion_events_without_completed_deletion=1' <<'SQL'
delete from private.account_deletions where profile_id=md5('profile-5')::uuid;
SQL
case_rows prepared_is_not_completed 'deletions_prepared=2,deletions_token_ready=0,deletion_phase_profile_mismatches=1' <<'SQL'
update private.account_deletions set phase='prepared' where profile_id=md5('profile-2')::uuid;
SQL
case_rows pending_is_not_completed deletion_records_invalid_shape=1 <<'SQL'
update private.account_deletions set auth_user_id=null, apple_provider_id=null,
 completed_at='2026-09-01+00' where profile_id=md5('profile-4')::uuid;
SQL
case_rows active_installations_distinct_profile deactivated_profiles_with_active_installations=1 <<'SQL'
update public.device_installations set state='active' where profile_id=md5('profile-2')::uuid;
insert into public.device_installations values (md5('second-device')::uuid,md5('profile-2')::uuid,md5('second-installation')::uuid,'active');
SQL
for direction in recipient_profile_id source_profile_id; do
  for assignment in "state='pending'" "state='leased'" "lease_token=md5('lease')::uuid" "lease_expires_at='2026-09-01+00'" "leased_apns_token_sha256=decode(repeat('ab',32),'hex')"; do
    case_rows "work_${direction}_$assignment" deactivated_profiles_with_live_notification_work=1 <<SQL
insert into private.competition_notification_work (id,recipient_profile_id,source_profile_id,state)
values (md5('bad-work')::uuid,md5('profile-6')::uuid,md5('profile-7')::uuid,'superseded'),
 (md5('bad-work-duplicate')::uuid,md5('profile-6')::uuid,md5('profile-7')::uuid,'superseded');
update private.competition_notification_work set $direction=md5('profile-2')::uuid, $assignment
where id in (md5('bad-work')::uuid,md5('bad-work-duplicate')::uuid);
SQL
  done
done
for terminal in sent suppressed superseded discarded; do
  case_rows "clean_terminal_work_$terminal" '' <<<"update private.competition_notification_work set state='$terminal' where recipient_profile_id=md5('profile-2')::uuid;"
done
for direction in profile_id opponent_profile_id; do
  case_rows "mute_$direction" deactivated_profiles_with_mute_links=1 <<SQL
insert into private.competition_notification_mutes values (md5('profile-6')::uuid,md5('profile-7')::uuid);
update private.competition_notification_mutes set $direction=md5('profile-2')::uuid
where profile_id=md5('profile-6')::uuid;
SQL
done
for attest_table in app_attest_keys app_attest_challenges app_attest_submission_grants; do
  case_rows "deactivated_$attest_table" 'deactivated_profiles_with_app_attest_rows=1,revoked_installations_with_app_attest_rows=1' <<SQL
insert into private.$attest_table (profile_id,installation_id)
values (md5('profile-2')::uuid,md5('installation-2')::uuid),
 (md5('profile-2')::uuid,md5('installation-2')::uuid);
SQL
  case_rows "active_profile_revoked_installation_$attest_table" revoked_installations_with_app_attest_rows=1 <<SQL
insert into public.device_installations values (md5('revoked-6')::uuid,md5('profile-6')::uuid,md5('revoked-installation-6')::uuid,'revoked');
insert into private.$attest_table (profile_id,installation_id)
values (md5('profile-6')::uuid,md5('revoked-installation-6')::uuid);
SQL
done
case_rows anonymous_memberships_distinct_profile anonymized_profiles_with_nonanonymized_participants=1 <<'SQL'
update public.competition_participants set state='accepted' where profile_id=md5('profile-5')::uuid;
SQL
case_rows anonymous_null_membership anonymized_profiles_with_nonanonymized_participants=1 <<'SQL'
update public.competition_participants set state=null where profile_id=md5('profile-5')::uuid;
SQL
for lifecycle in pending scheduled active ends_today tallying; do
  case_rows "unfinished_$lifecycle" deactivated_profiles_with_unfinished_competitions=1 <<<"update public.competitions set lifecycle='$lifecycle' where id=md5('competition-103')::uuid;"
done
case_rows cancelled_unconsumed_invites_distinct_profile deactivated_profiles_with_unconsumed_cancelled_invites=1 <<'SQL'
update public.competition_invites set consumed_at=null where competition_id=md5('competition-103')::uuid;
insert into public.competition_invites values (md5('second-invite')::uuid,md5('competition-103')::uuid,null);
SQL
case_rows zero_completion_event completed_deletions_with_bad_completion_event_count=1 <<'SQL'
delete from public.support_events where profile_id=md5('profile-5')::uuid;
SQL
case_rows duplicate_completion_events completed_deletions_with_bad_completion_event_count=1 <<'SQL'
insert into public.support_events values (md5('duplicate-completion')::uuid,md5('profile-5')::uuid,'account_deletion','completed');
SQL
case_rows wrong_completion_kind completed_deletions_with_bad_completion_event_count=1 <<'SQL'
update public.support_events set kind='other_kind' where profile_id=md5('profile-5')::uuid;
SQL
case_rows orphan_completion_events completion_events_without_completed_deletion=3 <<'SQL'
insert into public.support_events values
 (md5('orphan-1')::uuid,md5('profile-4')::uuid,'account_deletion','completed'),
 (md5('orphan-2')::uuid,md5('profile-6')::uuid,'account_deletion','completed'),
 (md5('orphan-3')::uuid,null,'account_deletion','completed');
SQL
case_rows no_retained_results anonymized_profiles_in_results=0 <<'SQL'
truncate public.competition_results;
SQL
case_rows retained_results_deduplicate_profiles '' <<'SQL'
insert into public.competition_results values (md5('another-result')::uuid,md5('profile-5')::uuid,md5('profile-4')::uuid);
SQL
seed

# Catalog authorization. Whole-table permissions also affect effective column
# permissions; these independent expected counts deliberately include both.
for privilege in SELECT INSERT UPDATE REFERENCES DELETE TRUNCATE TRIGGER MAINTAIN; do
  case "$privilege" in SELECT|INSERT|UPDATE|REFERENCES) column_count=2;; *) column_count=0;; esac
  case_metadata "anon_table_$privilege" "table_privilege_mismatches=1,column_privilege_mismatches=$column_count" \
    "grant $privilege on private.competition_notification_mutes to anon;" \
    "revoke $privilege on private.competition_notification_mutes from anon;"
done
for privilege in SELECT INSERT UPDATE REFERENCES; do
  case_metadata "denied_column_$privilege" column_privilege_mismatches=1 \
    "grant $privilege(auth_user_id) on public.profiles to authenticated;" \
    "revoke $privilege(auth_user_id) on public.profiles from authenticated;"
done
case_metadata missing_positive_table_read 'table_privilege_mismatches=1,column_privilege_mismatches=3' \
  'revoke select on public.competitions from authenticated;' 'grant select on public.competitions to authenticated;'
case_metadata missing_positive_profile_column column_privilege_mismatches=1 \
  'revoke select(display_name) on public.profiles from authenticated;' 'grant select(display_name) on public.profiles to authenticated;'
case_metadata stale_device_select 'table_privilege_mismatches=1,column_privilege_mismatches=4' \
  'grant select on public.device_installations to authenticated;' 'revoke select on public.device_installations from authenticated;'
case_metadata whole_profile_select 'table_privilege_mismatches=1,column_privilege_mismatches=5' \
  'grant select on public.profiles to authenticated;' \
  'revoke select on public.profiles from authenticated; grant select(id,display_name) on public.profiles to authenticated;'
case_metadata table_grant_option 'table_privilege_mismatches=1,column_privilege_mismatches=3' \
  'grant select on public.competitions to authenticated with grant option;' 'revoke grant option for select on public.competitions from authenticated;'
case_metadata column_grant_option column_privilege_mismatches=1 \
  'grant select(id) on public.profiles to authenticated with grant option;' 'revoke grant option for select(id) on public.profiles from authenticated;'
case_metadata public_grant 'table_privilege_mismatches=4,column_privilege_mismatches=8' \
  'grant select on private.competition_notification_mutes to public;' 'revoke select on private.competition_notification_mutes from public;'
case_metadata inherited_grant 'table_privilege_mismatches=1,column_privilege_mismatches=2' \
  'grant healthcomp_recovery_state_inherited to authenticated with inherit true; grant select on private.competition_notification_mutes to healthcomp_recovery_state_inherited;' \
  'revoke select on private.competition_notification_mutes from healthcomp_recovery_state_inherited; revoke healthcomp_recovery_state_inherited from authenticated;'
case_metadata service_role_raw_access table_privilege_mismatches=1 \
  'grant delete on private.account_deletions to service_role;' 'revoke delete on private.account_deletions from service_role;'
case_metadata public_rls_disabled rls_flag_mismatches=1 \
  'alter table public.profiles disable row level security;' 'alter table public.profiles enable row level security;'
case_metadata public_force_added rls_flag_mismatches=1 \
  'alter table public.profiles force row level security;' 'alter table public.profiles no force row level security;'
case_metadata private_force_removed rls_flag_mismatches=1 \
  'alter table private.account_deletions no force row level security;' 'alter table private.account_deletions force row level security;'
case_metadata both_rls_flags_one_table rls_flag_mismatches=1 \
  'alter table private.account_deletions disable row level security; alter table private.account_deletions no force row level security;' \
  'alter table private.account_deletions enable row level security; alter table private.account_deletions force row level security;'
case_metadata mute_rls_added rls_flag_mismatches=1 \
  'alter table private.competition_notification_mutes enable row level security;' 'alter table private.competition_notification_mutes disable row level security;'
case_metadata policy_name policy_mismatches=2 \
  'alter policy profiles_participant_read on public.profiles rename to recovery_wrong_name;' 'alter policy recovery_wrong_name on public.profiles rename to profiles_participant_read;'
case_metadata policy_roles policy_mismatches=1 \
  'alter policy profiles_participant_read on public.profiles to authenticated,anon;' 'alter policy profiles_participant_read on public.profiles to authenticated;'
case_metadata policy_expression policy_mismatches=1 \
  'alter policy profiles_participant_read on public.profiles using (true);' 'alter policy profiles_participant_read on public.profiles using ((select private.can_view_profile(profiles.id)));'
case_metadata extra_policy policy_mismatches=1 \
  'create policy recovery_extra on public.profiles for select to authenticated using (false);' 'drop policy recovery_extra on public.profiles;'
for policy_clause in 'as restrictive for select' 'for all' 'for all'; do
  policy_check=''
  [[ "$policy_clause" != 'for all' || ${tested_all:-0} == 0 ]] || policy_check='with check (true)'
  [[ "$policy_clause" != 'for all' ]] || tested_all=1
  case_metadata "policy_${policy_clause}_${policy_check}" policy_mismatches=1 \
    "drop policy profiles_participant_read on public.profiles; create policy profiles_participant_read on public.profiles $policy_clause to authenticated using ((select private.can_view_profile(profiles.id))) $policy_check;" \
    'drop policy profiles_participant_read on public.profiles; create policy profiles_participant_read on public.profiles for select to authenticated using ((select private.can_view_profile(profiles.id)));'
done
case_metadata unexpected_table application_tables_unexpected=1 \
  'create table public.recovery_state_extra(id uuid);' 'drop table public.recovery_state_extra;'
case_metadata unexpected_view application_tables_unexpected=1 \
  'create view public.recovery_state_view as select id from public.profiles;' 'drop view public.recovery_state_view;'

unsupported_case() {
  local label="$1" change="$2" undo="$3" result=0
  mutate "$label" <<<"$change"
  driver; adverse_psql
  fixture_psql -f "$tmp/driver.sql" -f "$operator" >"$tmp/stdout" 2>"$tmp/stderr" || result=$?
  if [[ $result == 0 ]]; then
    [[ ! -s "$tmp/stderr" ]] || fail "${label}_stderr"
    receipt_matches "$seed_expected" 1 <"$tmp/stdout" || fail "${label}_explicit_unsupported_required"
  else
    [[ $result == 3 && ! -s "$tmp/stdout" ]] || fail "${label}_no_partial_receipt"
    awk '$0 !~ /^psql:.*:[0-9]+: ERROR:[[:space:]]+[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]$/ {bad=1} END {if(bad || NR!=1) exit 1}' \
      "$tmp/stderr" || fail "${label}_sqlstate_only"
  fi
  mutate "${label}_undo" <<<"$undo"
  run_receipt "${label}_restored" "$seed_expected"
  printf 'Passed state probe: %s\n' "$label"
}
unsupported_case missing_table \
  'alter table public.competition_awards rename to recovery_state_saved;' \
  'alter table public.recovery_state_saved rename to competition_awards;'
unsupported_case inheritance \
  'create table public.recovery_state_child() inherits(public.competition_awards);' \
  'drop table public.recovery_state_child;'
unsupported_case unsupported_column_type \
  'alter table public.profiles alter column auth_user_id type text using auth_user_id::text;' \
  'alter table public.profiles alter column auth_user_id type uuid using auth_user_id::uuid;'

# The built-in non-superuser reader must successfully see the real seeded rows
# with RLS disabled, before the same role is used for the filtered rejection.
# No role attribute is changed; only these exact fixture-owned table flags move.
set_fixture_rls() {
  local action="$1" relation
  for relation in public.profiles public.competitions public.competition_participants \
    public.competition_invites public.competition_change_log public.daily_score_revisions \
    public.participant_finalization_attestations public.competition_results \
    public.competition_awards public.device_installations public.support_events \
    private.account_deletions private.competition_notification_work private.app_attest_keys \
    private.app_attest_challenges private.app_attest_submission_grants; do
    printf 'alter table %s %s row level security;\n' "$relation" "$action"
  done
}
set_fixture_rls disable | mutate unfiltered_visibility_setup
run_receipt actual_query_full_visibility "$seed_expected,rls_flag_mismatches=16" "$operator" 'set role pg_read_all_data;'
set_fixture_rls enable | mutate unfiltered_visibility_restore
run_receipt visibility_flags_restored "$seed_expected"

# Wrapper controls use a byte-identical temporary wrapper with only its relative
# query include substituted. Actual-query tests above always use the real paths.
# No source files are changed, and these probes do not count as query correctness.
copy_wrapper() {
  cp "$operator" "$tmp/recovery-state-acceptance.sql"
  cmp -s "$operator" "$tmp/recovery-state-acceptance.sql" || fail wrapper_copy_mismatch
}
probe() {
  local label="$1" expected_exit="$2" expected_output="$3" expected_state="${4:-}" result=0
  fixture_psql -f "$tmp/driver.sql" -f "$tmp/recovery-state-acceptance.sql" \
    -f "$tmp/after.sql" >"$tmp/stdout" 2>"$tmp/stderr" || result=$?
  [[ $result == "$expected_exit" ]] || fail "${label}_exit"
  [[ "$(<"$tmp/stdout")" == "$expected_output" ]] || fail "${label}_stdout"
  if [[ -z "$expected_state" ]]; then
    [[ ! -s "$tmp/stderr" ]] || fail "${label}_stderr"
  else
    awk -v code="$expected_state" '
      $0 !~ ("^psql:.*:[0-9]+: ERROR:[[:space:]]+" code "$") {bad=1}
      END {if(bad || NR!=1) exit 1}
    ' "$tmp/stderr" || fail "${label}_sqlstate_only"
  fi
  printf 'Passed state wrapper probe: %s\n' "$label"
}
stop_sentinels() {
  printf '\n%s\n' "select 'wrapper_continued';" >>"$tmp/recovery-state-acceptance.sql"
  printf '%s\n' "select 'next_source_continued';" >"$tmp/after.sql"
}
copy_wrapper; driver
cat >>"$tmp/driver.sql" <<'SQL'
create temporary table recovery_state_rollback_probe(value integer);
SQL
cat >"$tmp/recovery-state-acceptance-query.sql" <<'SQL'
\if :ON_ERROR_ROLLBACK
do $rollback_mode$ begin
  raise exception using errcode='P0001', message='psql_error_rollback_must_be_off';
end $rollback_mode$;
\endif
do $settings$
begin
  if (current_setting('transaction_isolation')='repeatable read'
    and current_setting('transaction_read_only')='on'
    and current_setting('row_security')='off'
    and current_setting('session_replication_role')='origin'
    and current_setting('TimeZone')='UTC'
    and current_setting('statement_timeout')='30s'
    and current_setting('search_path')='pg_catalog') is not true
  then raise exception using errcode='P0001', message='settings_required'; end if;
end $settings$;
insert into pg_temp.recovery_state_rollback_probe values(1);
select 'settings_inside';
SQL
adverse_psql
cat >"$tmp/after.sql" <<'SQL'
\set ON_ERROR_STOP on
do $rollback$
begin
  if (current_setting('transaction_isolation')='read committed'
    and current_setting('transaction_read_only')='off'
    and current_setting('row_security')='on'
    and current_setting('TimeZone')='Pacific/Honolulu'
    and current_setting('statement_timeout')='5s'
    and current_setting('search_path')='public'
    and (select count(*) from pg_temp.recovery_state_rollback_probe)=0) is not true
  then raise exception using errcode='P0001', message='rollback_required'; end if;
end $rollback$;
select 'rollback_outside';
SQL
probe settings_and_rollback 0 $'settings_inside\nrollback_outside'

copy_wrapper; driver; adverse_psql
cat >"$tmp/recovery-state-acceptance-query.sql" <<'SQL'
do $write$
begin
  create table public.recovery_state_write_probe(value integer);
  -- If read-only is broken, abort this atomic statement anyway: never persist DDL.
  raise exception using errcode='P0002', message='write_was_allowed';
end $write$;
select 'query_continued';
SQL
stop_sentinels
probe permanent_write_rejected 3 '' 25006

# Positive SELECT permission and a real filtered read, followed by the actual
# query under row_security=off. This is not just a missing-grant 42501.
copy_wrapper
cp "$query" "$tmp/recovery-state-acceptance-query.sql"
driver
cat >>"$tmp/driver.sql" <<'SQL'
set role pg_read_all_data;
do $visibility$
begin
  if (current_user='pg_read_all_data'
    and has_table_privilege(current_user,'public.profiles','SELECT')
    and (select count(*) from public.profiles)=0) is not true
  then raise exception using errcode='P0001', message='positive_visibility_control'; end if;
end $visibility$;
select 'filtered_with_read_permission';
SQL
adverse_psql; stop_sentinels
probe actual_query_filtered_visibility_rejected 3 filtered_with_read_permission 42501

copy_wrapper; driver; adverse_psql
cat >"$tmp/recovery-state-acceptance-query.sql" <<'SQL'
do $synthetic_context_canary$
begin
  raise exception using errcode='P0001', message='synthetic_message_canary',
    detail='synthetic_detail_canary', hint='synthetic_hint_canary';
end $synthetic_context_canary$;
select 'query_continued';
SQL
stop_sentinels
probe sqlstate_privacy_and_stop 3 '' P0001

for mode in 'repeatable read read write' 'read committed read only'; do
  awk -v mode="$mode" '
    $0=="begin transaction isolation level repeatable read read only;" {
      replacements++; print "begin transaction isolation level " mode ";"; next
    }
    {print} END {if(replacements!=1) exit 1}
  ' "$operator" >"$tmp/recovery-state-acceptance.sql" || fail mode_mutation_requires_one_begin
  driver; adverse_psql
  printf '%s\n' "select 'query_reached_invalid_mode';" >"$tmp/recovery-state-acceptance-query.sql"
  stop_sentinels
  probe "mode_guard_$mode" 3 '' P0001
done

copy_wrapper; driver
printf '%s\n' 'set session_replication_role=replica;' >>"$tmp/driver.sql"
adverse_psql
printf '%s\n' "select 'query_reached_replica_origin';" >"$tmp/recovery-state-acceptance-query.sql"
stop_sentinels
probe replica_origin_rejected 3 '' P0001

# A bounded timeout transport control changes only the temporary wrapper timeout;
# the actual 30s setting is independently asserted above, without a 30s sleep.
awk '
  $0=="set local statement_timeout = '\''30s'\'';" {
    replacements++; print "set local statement_timeout = '\''20ms'\'';"; next
  }
  {print} END {if(replacements!=1) exit 1}
' "$operator" >"$tmp/recovery-state-acceptance.sql" || fail timeout_mutation_requires_one_setting
driver; adverse_psql
printf '%s\n' 'select pg_catalog.pg_sleep(0.2);' "select 'query_continued';" >"$tmp/recovery-state-acceptance-query.sql"
stop_sentinels
probe timeout_sqlstate_and_stop 3 '' 57014

run_receipt final_unmodified_baseline "$seed_expected"
printf '%s\n' 'Synthetic state/query and wrapper assertions finished; exact cleanup and role preservation checks follow. This is not restore, Auth/session/Vault, or genuine deletion/history evidence.'
