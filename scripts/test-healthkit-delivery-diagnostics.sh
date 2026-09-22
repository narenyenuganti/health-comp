#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
diagnostic_scratch="$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-delivery-diagnostics.XXXXXX")"
cleanup() {
  if [[ -d "$diagnostic_scratch" && ! -L "$diagnostic_scratch" &&
        "$(basename -- "$diagnostic_scratch")" == healthcomp-delivery-diagnostics.* ]]; then
    rm -r -- "$diagnostic_scratch"
  fi
}
trap cleanup EXIT

for mode in debug release staging; do
  flags=(-swift-version 5 -warnings-as-errors)
  case "$mode" in
    debug) flags+=(-D DEBUG) ;;
    release) flags+=(-O) ;;
    staging) flags+=(-O -D HEALTHCOMP_STAGING) ;;
  esac
  xcrun swiftc "${flags[@]}" \
    "$repository_root/HealthComp/Services/HealthKitDeliveryDiagnostic.swift" \
    "$repository_root/scripts/tests/healthkit-delivery-diagnostics.swift" \
    -o "$diagnostic_scratch/$mode"
  "$diagnostic_scratch/$mode"
done
