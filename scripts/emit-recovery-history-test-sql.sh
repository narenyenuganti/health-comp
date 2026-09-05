#!/usr/bin/env bash
# Emits synthetic test SQL; never opens a database or reads credentials.
set -euo pipefail

recovery_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
recovery_query="$recovery_root/scripts/recovery-history-integrity-query.sql"
if [[ ! -s "$recovery_query" ]]; then
  printf '%s\n' 'Recovery history query missing: expected RED before implementation.' >&2
  exit 1
fi
for recovery_fixture in recovery-history-fixtures.sql recovery-history-assertions.sql; do
  if [[ ! -s "$recovery_root/scripts/tests/$recovery_fixture" ]]; then
    printf '%s\n' 'Recovery history test fixture missing.' >&2
    exit 1
  fi
done

emit_recovery_function() {
  local recovery_name="$1" recovery_migration="$2" recovery_matches
  recovery_matches="$(rg -l -F "create or replace function private.$recovery_name(" \
    "$recovery_root/supabase/migrations")"
  if [[ "$recovery_matches" != "$recovery_root/supabase/migrations/$recovery_migration" ]]; then
    printf '%s\n' 'Canonical recovery helper definition missing or ambiguous.' >&2
    return 1
  fi
  awk -v declaration="create or replace function private.$recovery_name(" '
    $0 == declaration { found++; active = 1 }
    active { print }
    active && $0 == "$$;" { active = 0 }
    END { if (found != 1 || active) exit 1 }
  ' "$recovery_matches"
}

# This stream contains synthetic fixtures only; terse labels identify failed tests.
# The separate operator wrapper must use SQLSTATE-only errors for private data.
printf '%s\n' '\set ON_ERROR_STOP on' '\set VERBOSITY terse' '\set SHOW_CONTEXT never'
printf '%s\n' 'begin;' "set local statement_timeout = '30s';" "set local time zone 'UTC';"
printf '%s\n' 'do $fixture_guard$'
printf '%s\n' 'begin'
printf '%s\n' "  if current_database() <> 'healthcomp_recovery_fixture'"
printf '%s\n' "    or current_setting('server_version_num')::integer / 10000 <> 17"
printf '%s\n' '    or inet_server_addr() is not null'
printf '%s\n' "    or exists (select 1 from pg_catalog.pg_namespace where nspname in ('auth', 'private', 'extensions', 'supabase_migrations'))"
printf '%s\n' "    or exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public')"
printf '%s\n' "    or exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public')"
printf '%s\n' "  then raise exception 'isolated_empty_postgres17_fixture_required'; end if;"
printf '%s\n' 'end' '$fixture_guard$;'
printf '%s\n' 'create schema private;' 'create schema extensions;' 'create extension pgcrypto with schema extensions;'

emit_recovery_function tlv_v1 20260811000100_create_multi_user_competitions.sql
for recovery_helper in window_day_content_v1 is_valid_frozen_window_v2 result_immutable_hash_v1; do
  emit_recovery_function "$recovery_helper" 20260811000400_add_score_and_finalization_functions.sql
done
sed -n '1,$p' "$recovery_root/scripts/tests/recovery-history-fixtures.sql"
printf '%s\n' 'create temporary view recovery_history_receipt as'
sed -n '1,$p' "$recovery_query"
sed -n '1,$p' "$recovery_root/scripts/tests/recovery-history-assertions.sql"
printf '%s\n' 'rollback;'
