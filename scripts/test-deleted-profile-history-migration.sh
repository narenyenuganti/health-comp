#!/usr/bin/env bash
# Empty local pre-redaction schema only; no runtime startup or database reset.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
container_id=$(docker ps --filter 'label=com.supabase.cli.project=health-comp' \
  --filter 'name=supabase_db_' --format '{{.ID}}')
[[ "$container_id" =~ ^[0-9a-f]{12,64}$ ]] || { echo 'exact_local_database_required' >&2; exit 1; }
migration_sql=$(<"$script_dir/../supabase/migrations/20260913001400_redact_deleted_profile_history.sql")
receipt=$(docker exec -i "$container_id" psql -XqAt --no-password \
  --username=postgres --dbname=postgres --set=ON_ERROR_STOP=1 \
  --set=history_migration="$migration_sql" < "$script_dir/tests/deleted-profile-history-migration.sql")
[[ "$receipt" == 'local_history_redaction_preservation_and_idempotence_passed_rolled_back' ]] \
  || { echo 'migration_rehearsal_receipt_mismatch' >&2; exit 1; }
printf '%s\n' "$receipt"
