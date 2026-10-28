#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
check_scratch="$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-local-date-formatting.XXXXXX")"
cleanup() {
  if [[ -d "$check_scratch" && ! -L "$check_scratch" &&
        "$(basename -- "$check_scratch")" == healthcomp-local-date-formatting.* ]]; then
    rm -r -- "$check_scratch"
  fi
}
trap cleanup EXIT

xcrun swiftc -swift-version 5 -warnings-as-errors \
  "$repository_root/HealthComp/Features/Competition/CompetitionDateFormatting.swift" \
  "$repository_root/scripts/tests/competition-local-date-formatting.swift" \
  -o "$check_scratch/check"
"$check_scratch/check"
