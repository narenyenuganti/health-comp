#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
capture_scratch="$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-scoring-capture.XXXXXX")"
cleanup() {
  if [[ -d "$capture_scratch" && ! -L "$capture_scratch" &&
        "$(basename -- "$capture_scratch")" == healthcomp-scoring-capture.* ]]; then
    rm -r -- "$capture_scratch"
  fi
}
trap cleanup EXIT

for mode in debug release staging; do
  flags=(-swift-version 6 -warnings-as-errors)
  case "$mode" in
    debug) flags+=(-D DEBUG) ;;
    release) flags+=(-O) ;;
    staging) flags+=(-O -D HEALTHCOMP_STAGING) ;;
  esac
  xcrun swiftc "${flags[@]}" \
    "$repository_root/HealthComp/Services/StagingScoringResponseCapture.swift" \
    "$repository_root/HealthComp/Services/StagingScoringOperatorControls.swift" \
    "$repository_root/scripts/tests/staging-scoring-response-capture.swift" \
    -o "$capture_scratch/$mode"
  perl -e 'alarm 20; exec @ARGV' "$capture_scratch/$mode" > "$capture_scratch/output"
  if ! awk '/^PASS [a-z_]+$/ { next } { exit 1 }' "$capture_scratch/output"; then
    printf 'FAIL non_allowlisted_capture_output\n' >&2
    exit 1
  fi
  sed -n '/^PASS /p' "$capture_scratch/output"
done

if xcrun swiftc -swift-version 6 -D HEALTHCOMP_CAPTURE_ABSENCE_TEST -typecheck \
  "$repository_root/HealthComp/Services/StagingScoringResponseCapture.swift" \
  "$repository_root/HealthComp/Services/StagingScoringOperatorControls.swift" \
  "$repository_root/scripts/tests/staging-scoring-response-capture.swift" > "$capture_scratch/absence" 2>&1; then
  printf 'FAIL capture_available_outside_staging\n' >&2
  exit 1
fi
rg -Fq "cannot find type 'StagingScoringResponseCapture' in scope" "$capture_scratch/absence"
rg -Fq "cannot find type 'StagingScoringOperatorControls' in scope" "$capture_scratch/absence"
printf 'PASS non_staging_type_absence_guard\n'
