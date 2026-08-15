#!/usr/bin/env bash

set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"

if git ls-files --error-unmatch 'Supabase/migrations/*.sql' >/dev/null 2>&1; then
  echo "Historical migrations are still executable under Supabase/. Move them to SupabaseLegacy/." >&2
  exit 1
fi

if [[ ! -d SupabaseLegacy ]]; then
  echo "SupabaseLegacy/ is missing." >&2
  exit 1
fi

if [[ ! -f supabase/config.toml ]]; then
  echo "supabase/config.toml is missing." >&2
  exit 1
fi

if grep -Eq 'SupabaseLegacy|(^|[/"])Supabase/' supabase/config.toml; then
  echo "supabase/config.toml must not reference the historical backend." >&2
  exit 1
fi

if ! grep -Eiq \
  '^[[:space:]]*create[[:space:]]+extension[[:space:]]+if[[:space:]]+not[[:space:]]+exists[[:space:]]+pg_net[[:space:]]+with[[:space:]]+schema[[:space:]]+extensions[[:space:]]*;[[:space:]]*$' \
  supabase/migrations/*.sql; then
  echo "The executable migration chain must enable pg_net in schema extensions." >&2
  exit 1
fi

if ! grep -Eiq \
  '^[[:space:]]*create[[:space:]]+extension[[:space:]]+if[[:space:]]+not[[:space:]]+exists[[:space:]]+pg_cron[[:space:]]*;[[:space:]]*$' \
  supabase/migrations/*.sql; then
  echo "The executable migration chain must enable pg_cron for hosted schedules." >&2
  exit 1
fi

echo "Supabase layout is isolated from the historical backend."
