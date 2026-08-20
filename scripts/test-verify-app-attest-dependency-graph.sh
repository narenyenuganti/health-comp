#!/bin/sh
set -eu

repository_root=$(git rev-parse --show-toplevel)
verifier="$repository_root/scripts/verify-app-attest-dependency-graph.sh"
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-app-attest-graph.XXXXXX")

cleanup() {
  find "$fixture_dir" -type f -delete
  rmdir "$fixture_dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

expect_pass() {
  if ! sh "$verifier" "$1" >/dev/null; then
    echo "Safe App Attest dependency graph was rejected." >&2
    exit 1
  fi
}

expect_reject() {
  if sh "$verifier" "$1" >/dev/null 2>&1; then
    echo "Rejected App Attest dependency graph was accepted." >&2
    exit 1
  fi
}

printf '%s\n' \
  '{"npmPackages":{"asn1js@3.0.10":{},"cbor@10.0.12":{}},"modules":[{"specifier":"file:///work/bugfix-supabase-pkijs-attestation-runtime/app-attest.ts"},{"specifier":"npm:/asn1js@3.0.10"}]}' \
  >"$fixture_dir/safe.json"
printf '%s\n' \
  '{"npmPackages":{"pkijs@3.4.0":{}},"modules":[]}' \
  >"$fixture_dir/npm-pkijs.json"
printf '%s\n' \
  '{"npmPackages":{},"modules":[{"specifier":"https://esm.sh/pkijs@3.4.0?target=deno"}]}' \
  >"$fixture_dir/remote-pkijs.json"
printf '%s\n' \
  '{"npmPackages":{},"modules":[{"specifier":"https://esm.sh/node-app-attest@1.0.1/denonext/node-app-attest.mjs"}]}' \
  >"$fixture_dir/remote-node-app-attest.json"

expect_pass "$fixture_dir/safe.json"
expect_reject "$fixture_dir/npm-pkijs.json"
expect_reject "$fixture_dir/remote-pkijs.json"
expect_reject "$fixture_dir/remote-node-app-attest.json"

echo "App Attest dependency graph guard tests passed."
