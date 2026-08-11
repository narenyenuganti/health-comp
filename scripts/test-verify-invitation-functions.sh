#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERIFIER="$SCRIPT_DIR/verify-invitation-functions.sh"

grep -Fq 'if ! kill -0 "$FUNCTIONS_PID" 2>/dev/null; then' "$VERIFIER"
grep -Fq 'child_state=$(ps -o stat= -p "$FUNCTIONS_PID" 2>/dev/null || true)' "$VERIFIER"
grep -Fq '"" | *Z*) fail_functions_child ;;' "$VERIFIER"
grep -Fq 'cat "$FUNCTION_LOG" >&2' "$VERIFIER"
grep -Fq 'while kill -0 "$TEST_PID" 2>/dev/null; do' "$VERIFIER"

spawn_line=$(grep -nF 'FUNCTIONS_PID=$!' "$VERIFIER" | cut -d: -f1)
curl_line=$(grep -nF 'if curl --silent' "$VERIFIER" | cut -d: -f1)
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
[ "$first_check" -lt "$curl_line" ]
[ "$curl_line" -lt "$second_check" ]
[ "$third_check" -lt "$deno_line" ]
[ "$deno_line" -lt "$monitor_line" ]
[ "$monitor_line" -lt "$last_check" ]
