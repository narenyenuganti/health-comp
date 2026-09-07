#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lifetime_source="$repository_root/HealthComp/Services/AppleWebAuthenticationSessionClient.swift"
lifetime_tests="$repository_root/scripts/tests/apple-web-session-lifetime.swift"
lifetime_scratch="$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-apple-web-lifetime.XXXXXX")"
cleanup() {
  if [[ -d "$lifetime_scratch" && ! -L "$lifetime_scratch" &&
        "$(basename -- "$lifetime_scratch")" == healthcomp-apple-web-lifetime.* ]]; then
    rm -r -- "$lifetime_scratch"
  fi
}
trap cleanup EXIT

xcrun swiftc -swift-version 5 -warnings-as-errors \
  "$lifetime_source" "$lifetime_tests" -o "$lifetime_scratch/lifetime"
"$lifetime_scratch/lifetime"
