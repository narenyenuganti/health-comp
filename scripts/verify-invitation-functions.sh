#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
STATUS_ENV=$(mktemp "${TMPDIR:-/tmp}/healthcomp-invite-status.XXXXXX")
TEST_OUTPUT=$(mktemp "${TMPDIR:-/tmp}/healthcomp-invite-tests.XXXXXX")
FUNCTION_LOG=$(mktemp "${TMPDIR:-/tmp}/healthcomp-invite-functions.XXXXXX")
FUNCTION_ENV=$(mktemp "${TMPDIR:-/tmp}/healthcomp-invite-env.XXXXXX")
FUNCTIONS_PID=""
TEST_PID=""

cleanup() {
  result=$?
  trap - EXIT INT TERM
  if [ -n "$FUNCTIONS_PID" ]; then
    kill "$FUNCTIONS_PID" 2>/dev/null || true
    wait "$FUNCTIONS_PID" 2>/dev/null || true
  fi
  if [ -n "$TEST_PID" ]; then
    kill "$TEST_PID" 2>/dev/null || true
    wait "$TEST_PID" 2>/dev/null || true
  fi
  cd "$REPO_ROOT"
  if ! supabase db reset >/dev/null 2>&1; then
    echo "post-run local database reset failed" >&2
    result=1
  fi
  rm -f "$STATUS_ENV" "$TEST_OUTPUT" "$FUNCTION_LOG" "$FUNCTION_ENV"
  exit "$result"
}
trap cleanup EXIT INT TERM

assert_functions_child_alive() {
  if ! kill -0 "$FUNCTIONS_PID" 2>/dev/null; then
    fail_functions_child
  fi
  child_state=$(ps -o stat= -p "$FUNCTIONS_PID" 2>/dev/null || true)
  case "$child_state" in
    "" | *Z*) fail_functions_child ;;
  esac
}

fail_functions_child() {
  wait "$FUNCTIONS_PID" 2>/dev/null || true
  FUNCTIONS_PID=""
  echo "spawned Edge Functions process exited before readiness" >&2
  cat "$FUNCTION_LOG" >&2
  exit 1
}

cd "$REPO_ROOT"
unset FUNCTIONS_URL
supabase status -o env >"$STATUS_ENV"
set -a
. "$STATUS_ENV"
set +a

case "$API_URL" in
  http://127.0.0.1:* | http://localhost:*) ;;
  *)
    echo "integration test requires a localhost Supabase API" >&2
    exit 1
    ;;
esac
case "$DB_URL" in
  postgresql://*@127.0.0.1:*/* | postgresql://*@localhost:*/*) ;;
  *)
    echo "integration test requires a disposable localhost database" >&2
    exit 1
    ;;
esac

FUNCTIONS_URL="${API_URL%/}/functions/v1"
export SUPABASE_URL="$API_URL"
export SUPABASE_ANON_KEY="$ANON_KEY"
export SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY"
export HEALTHCOMP_TEST_DATABASE_URL="$DB_URL"
export HEALTHCOMP_RUN_INVITE_INTEGRATION=1
printf '%s\n' \
  'INVITE_TOKEN_DERIVATION_KEY_V1=healthcomp-local-invite-derivation-v1-only' \
  >"$FUNCTION_ENV"

attempt=0
while [ "$attempt" -lt 30 ]; do
  schema_state=$(psql "$DB_URL" -Atqc \
    "select to_regclass('auth.identities'), to_regclass('public.profiles')" \
    2>/dev/null || true)
  if [ "$schema_state" = "auth.identities|profiles" ] && \
    curl --fail --silent --output /dev/null "${API_URL}/auth/v1/health"; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done
if [ "$attempt" -eq 30 ]; then
  echo "local Auth/database did not become ready" >&2
  exit 1
fi

supabase functions serve --env-file "$FUNCTION_ENV" >"$FUNCTION_LOG" 2>&1 &
FUNCTIONS_PID=$!

attempt=0
while [ "$attempt" -lt 30 ]; do
  assert_functions_child_alive
  if curl --silent --output /dev/null \
    "${FUNCTIONS_URL}/create-competition-invite"; then
    assert_functions_child_alive
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done
if [ "$attempt" -eq 30 ]; then
  echo "local Edge Functions did not become ready" >&2
  exit 1
fi
assert_functions_child_alive

deno test --config supabase/functions/deno.json --allow-env --allow-net \
  supabase/functions/create-competition-invite \
  supabase/functions/claim-competition-invite >"$TEST_OUTPUT" 2>&1 &
TEST_PID=$!
while kill -0 "$TEST_PID" 2>/dev/null; do
  assert_functions_child_alive
  sleep 0.1
done
if wait "$TEST_PID"; then
  test_status=0
else
  test_status=$?
fi
TEST_PID=""
if [ "$test_status" -ne 0 ]; then
  cat "$TEST_OUTPUT"
  echo "Edge Functions child log:" >&2
  cat "$FUNCTION_LOG" >&2
  exit 1
fi
cat "$TEST_OUTPUT"

if ! grep -q "local JWT integration recovers concurrent create and permits exactly one concurrent claimant .* ok" "$TEST_OUTPUT"; then
  echo "real-JWT create-recovery and claim concurrency test did not run to completion" >&2
  exit 1
fi
if grep -q "ignored" "$TEST_OUTPUT"; then
  echo "an invitation test was skipped" >&2
  exit 1
fi

kill "$FUNCTIONS_PID" 2>/dev/null || true
wait "$FUNCTIONS_PID" 2>/dev/null || true
FUNCTIONS_PID=""

supabase db reset
supabase test db
