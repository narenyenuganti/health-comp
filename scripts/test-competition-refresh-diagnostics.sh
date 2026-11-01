#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
diagnostic_scratch="$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-refresh-diagnostics.XXXXXX")"
cleanup() {
  if [[ -d "$diagnostic_scratch" && ! -L "$diagnostic_scratch" &&
        "$(basename -- "$diagnostic_scratch")" == healthcomp-refresh-diagnostics.* ]]; then
    rm -r -- "$diagnostic_scratch"
  fi
}
trap cleanup EXIT

# Local only: the macOS log store is admin-only, so a standard account (the Mac mini's
# `agent`) can set this to a booted simulator's UDID and run the same harness there,
# where it can read its own log. CI leaves it unset and runs on the host.
simulator="${HEALTHCOMP_DIAGNOSTICS_SIMULATOR:-}"
if [[ -n "$simulator" ]]; then
  export SDKROOT=iphonesimulator
fi

for mode in debug release staging; do
  flags=(-swift-version 5 -warnings-as-errors)
  case "$mode" in
    debug) flags+=(-D DEBUG) ;;
    release) flags+=(-O) ;;
    staging) flags+=(-O -D HEALTHCOMP_STAGING) ;;
  esac
  if [[ -n "$simulator" ]]; then
    flags+=(-target "$(uname -m)-apple-ios17.0-simulator")
  fi
  xcrun swiftc "${flags[@]}" \
    "$repository_root/HealthComp/Services/RemoteCompetitionRuntimeFailure.swift" \
    "$repository_root/scripts/tests/competition-refresh-diagnostics.swift" \
    -o "$diagnostic_scratch/$mode"
  if [[ -n "$simulator" ]]; then
    xcrun simctl spawn "$simulator" "$diagnostic_scratch/$mode"
  else
    "$diagnostic_scratch/$mode"
  fi
done
