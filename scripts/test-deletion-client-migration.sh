#!/usr/bin/env bash
# Requires an empty local HealthComp DB reset to 20260822001000. Never connects
# to a hosted database and never resets a database or starts a runtime itself.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
container_id=$(docker ps --filter 'label=com.supabase.cli.project=health-comp' \
  --filter 'name=supabase_db_' --format '{{.ID}}')
[[ "$container_id" =~ ^[0-9a-f]{12,64}$ ]] || { echo 'exact_local_database_required' >&2; exit 1; }
migration_path="$script_dir/../supabase/migrations/20260906001100_bind_deletion_apple_client.sql"
migration_sql=$(<"$migration_path")
receipt=$(docker exec -i "$container_id" psql -XqAt --no-password \
  --username=postgres --dbname=postgres --set=ON_ERROR_STOP=1 \
  --set=binding_migration="$migration_sql" < "$script_dir/tests/deletion-client-migration.sql")
[[ "$receipt" == 'local_legacy_token_refusal_and_later_phase_migration_passed_rolled_back' ]] \
  || { echo 'migration_rehearsal_receipt_mismatch' >&2; exit 1; }
printf '%s\n' "$receipt"
