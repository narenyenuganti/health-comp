#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERIFIER="$SCRIPT_DIR/verify-invitation-functions.sh"

grep -Fq 'if ! kill -0 "$FUNCTIONS_PID" 2>/dev/null; then' "$VERIFIER"
grep -Fq 'child_state=$(ps -o stat= -p "$FUNCTIONS_PID" 2>/dev/null || true)' "$VERIFIER"
grep -Fq '"" | *Z*) fail_functions_child ;;' "$VERIFIER"
grep -Fq 'cat "$FUNCTION_LOG" >&2' "$VERIFIER"
grep -Fq 'while kill -0 "$TEST_PID" 2>/dev/null; do' "$VERIFIER"
grep -Fq 'NO_COLOR=1 deno test --config' "$VERIFIER"
grep -Fq 'READINESS_OUTPUT=$(mktemp' "$VERIFIER"
grep -Fq "FUNCTIONS_READY_PATTERN='Serving functions on http://(127[.]0[.]0[.]1|localhost):[0-9]+/functions/v1/<function-name>$'" "$VERIFIER"
grep -Fq 'grep -Eq "$FUNCTIONS_READY_PATTERN" "$FUNCTION_LOG"' "$VERIFIER"
grep -Fq 'readiness_status=$(' "$VERIFIER"
grep -Fq -- '--output "$READINESS_OUTPUT"' "$VERIFIER"
grep -Fq -- "--write-out '%{http_code}'" "$VERIFIER"
grep -Fq -- '--connect-timeout 2' "$VERIFIER"
grep -Fq -- '--max-time 5' "$VERIFIER"
grep -Fq -- '--request POST' "$VERIFIER"
grep -Fq 'authorization: Bearer $ANON_KEY' "$VERIFIER"
grep -Fq -- \
  '--data '\''{"timeZoneIdentifier":"UTC","idempotencyKey":"84000000-0000-4000-8000-000000000001"}'\''' \
  "$VERIFIER"
grep -Fq 'if [ "$readiness_status" = "401" ] &&' "$VERIFIER"
grep -Fq '"code":"unauthorized"' "$VERIFIER"
grep -Fq '"message":"Authentication required"' "$VERIFIER"
if grep -Fq 'if curl --silent --output /dev/null' "$VERIFIER"; then
  echo "readiness probe still accepts any HTTP response" >&2
  exit 1
fi

spawn_line=$(grep -nF 'FUNCTIONS_PID=$!' "$VERIFIER" | cut -d: -f1)
marker_line=$(grep -nF 'grep -Eq "$FUNCTIONS_READY_PATTERN" "$FUNCTION_LOG"' "$VERIFIER" | cut -d: -f1)
curl_line=$(grep -nF 'readiness_status=$(' "$VERIFIER" | cut -d: -f1)
deno_line=$(grep -nF 'deno test --config' "$VERIFIER" | cut -d: -f1)
monitor_line=$(grep -nF 'while kill -0 "$TEST_PID" 2>/dev/null; do' "$VERIFIER" | cut -d: -f1)
check_lines=$(grep -nF 'assert_functions_child_alive' "$VERIFIER" | grep -v '()' | cut -d: -f1)
check_count=$(printf '%s\n' "$check_lines" | grep -c .)

[ "$check_count" -ge 3 ]
first_check=$(printf '%s\n' "$check_lines" | sed -n '1p')
second_check=$(printf '%s\n' "$check_lines" | sed -n '2p')
third_check=$(printf '%s\n' "$check_lines" | sed -n '3p')
last_check=$(printf '%s\n' "$check_lines" | tail -n 1)

[ "$spawn_line" -lt "$first_check" ]
[ "$first_check" -lt "$marker_line" ]
[ "$marker_line" -lt "$curl_line" ]
[ "$curl_line" -lt "$second_check" ]
[ "$third_check" -lt "$deno_line" ]
[ "$deno_line" -lt "$monitor_line" ]
[ "$monitor_line" -lt "$last_check" ]
