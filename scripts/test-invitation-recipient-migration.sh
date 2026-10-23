#!/usr/bin/env bash
# Empty local pre-recipient schema only; never starts or resets a database.
set -euo pipefail
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
container_id=$(docker ps --filter 'label=com.supabase.cli.project=health-comp' \
  --filter 'name=supabase_db_' --format '{{.ID}}')
[[ "$container_id" =~ ^[0-9a-f]{12,64}$ ]] || { echo 'exact_local_database_required' >&2; exit 1; }
migration_sql=$(<"$script_dir/../supabase/migrations/20261019001800_bind_invitation_recipients.sql")
receipt=$(docker exec -i "$container_id" psql -XqAt --no-password \
  --username=postgres --dbname=postgres --set=ON_ERROR_STOP=1 \
  --set=recipient_migration="$migration_sql" < "$script_dir/tests/invitation-recipient-migration.sql")
[[ "$receipt" == 'local_recipient_migration_history_preserved_rolled_back' ]] \
  || { echo 'migration_rehearsal_receipt_mismatch' >&2; exit 1; }
printf '%s\n' "$receipt"
