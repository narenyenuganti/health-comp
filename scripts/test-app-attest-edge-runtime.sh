#!/bin/sh
set -eu

repository_root=$(git rev-parse --show-toplevel)
runtime_image="public.ecr.aws/supabase/edge-runtime:v1.74.3"
container_name="healthcomp-app-attest-edge-$$"
result_dir=$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-app-attest-edge.XXXXXX")
fixture_dir="$result_dir/function"
response_file="$result_dir/response.json"
container_started=false

cleanup() {
  if [ "$container_started" = true ]; then
    docker stop --time 1 "$container_name" >/dev/null 2>&1 || true
  fi
  find "$result_dir" -type f -delete
  rmdir "$fixture_dir" 2>/dev/null || true
  rmdir "$result_dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

mkdir "$fixture_dir"
cp "$repository_root/supabase/functions/_shared/app-attest.ts" \
  "$fixture_dir/app-attest.ts"
cp "$repository_root/supabase/functions/deno.json" \
  "$fixture_dir/deno.json"
cp "$repository_root/supabase/functions/deno.lock" \
  "$fixture_dir/deno.lock"
cp "$repository_root/supabase/tests/edge-runtime/function/index.ts" \
  "$fixture_dir/index.ts"

sh "$repository_root/scripts/verify-app-attest-dependency-graph.sh" >/dev/null

docker image inspect "$runtime_image" >/dev/null
docker run --detach --rm \
  --name "$container_name" \
  --publish 127.0.0.1::9000 \
  --volume "$repository_root:/workspace:ro" \
  --volume "$fixture_dir:/fixture:ro" \
  "$runtime_image" \
  start \
  --main-service /workspace/supabase/tests/edge-runtime/main \
  --port 9000 \
  --policy oneshot \
  --disable-module-cache \
  --request-wait-timeout 10000 \
  --user-worker-request-idle-timeout 10000 >/dev/null
container_started=true

host_port=$(docker port "$container_name" 9000/tcp | sed -n 's/.*://p')
if [ -z "$host_port" ]; then
  echo "App Attest Edge Runtime probe did not receive a loopback port." >&2
  exit 1
fi

ready=false
attempt=0
while [ "$attempt" -lt 20 ]; do
  attempt=$((attempt + 1))
  if curl --fail --silent --show-error --max-time 2 \
    "http://127.0.0.1:$host_port/health" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [ "$ready" != true ]; then
  echo "App Attest Edge Runtime probe did not become ready." >&2
  exit 1
fi

status=$(curl --silent --show-error --max-time 15 \
  --output "$response_file" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'content-type: application/json' \
  --data-binary \
  "@$repository_root/supabase/tests/fixtures/app-attest-official-2026.json" \
  "http://127.0.0.1:$host_port/verify")

if [ "$status" != 200 ] ||
  ! jq --exit-status '. == {"ok": true}' "$response_file" >/dev/null; then
  echo "Real App Attest verification failed in the pinned Edge Runtime user worker." >&2
  jq --compact-output \
    '{category: (.category // "unknown"), code: (.code // "unknown"), causeCategory: (.causeCategory // "unknown"), causeCode: (.causeCode // "unknown")}' \
    "$response_file" >&2 || true
  exit 1
fi

echo "Real App Attest verification passed in the pinned Edge Runtime user worker."
