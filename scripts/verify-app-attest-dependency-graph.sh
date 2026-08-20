#!/bin/sh
set -eu

repository_root=$(git rev-parse --show-toplevel)
temporary_graph=""

cleanup() {
  if [ -n "$temporary_graph" ] && [ -f "$temporary_graph" ]; then
    unlink "$temporary_graph"
  fi
}
trap cleanup EXIT INT TERM HUP

case $# in
  0)
    temporary_graph=$(mktemp \
      "${TMPDIR:-/tmp}/healthcomp-app-attest-graph.XXXXXX")
    NO_COLOR=1 deno info \
      --json \
      --config "$repository_root/supabase/functions/deno.json" \
      "$repository_root/supabase/functions/submit-score-revision/index.ts" \
      >"$temporary_graph"
    graph_file="$temporary_graph"
    ;;
  1)
    graph_file=$1
    ;;
  *)
    echo "usage: verify-app-attest-dependency-graph.sh [deno-info.json]" >&2
    exit 2
    ;;
esac

if ! jq --exit-status '
  def rejected:
    test("(^|[:/])(node-app-attest|pkijs)(@|/|[?#]|$)");
  [
    ((.npmPackages // {}) | keys[] | select(rejected)),
    ((.modules // [])[]?.specifier | strings | select(rejected))
  ] | length == 0
' "$graph_file" >/dev/null; then
  echo "Production App Attest graph reaches a rejected PKI dependency." >&2
  exit 1
fi

echo "Production App Attest dependency graph excludes rejected PKI packages."
