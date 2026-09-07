#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
contract_source="$repository_root/HealthComp/Services/StagingAppleWebAuthenticationConfiguration.swift"
contract_tests="$repository_root/scripts/tests/staging-apple-web-contract.swift"

if [[ ! -f "$contract_source" ]]; then
  printf 'FAIL: missing_staging_apple_web_contract\n' >&2
  exit 1
fi

contract_scratch="$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-apple-web-contract.XXXXXX")"
cleanup() {
  if [[ -d "$contract_scratch" && ! -L "$contract_scratch" &&
        "$(basename -- "$contract_scratch")" == healthcomp-apple-web-contract.* ]]; then
    rm -r -- "$contract_scratch"
  fi
}
trap cleanup EXIT

for mode in ordinary staging; do
  flags=(-swift-version 5)
  if [[ "$mode" == staging ]]; then flags+=(-D HEALTHCOMP_STAGING); fi
  xcrun swiftc "${flags[@]}" \
    "$contract_source" "$contract_tests" -o "$contract_scratch/$mode"
  "$contract_scratch/$mode"
done
