#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
debugger_scratch="$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-operator-debugger.XXXXXX")"
cleanup() {
  if [[ -d "$debugger_scratch" && ! -L "$debugger_scratch" &&
        "$(basename -- "$debugger_scratch")" == healthcomp-operator-debugger.* ]]; then
    rm -r -- "$debugger_scratch"
  fi
}
trap cleanup EXIT

for optimization in -Onone -O; do
  xcrun swiftc -swift-version 6 -warnings-as-errors -g "$optimization" -D HEALTHCOMP_STAGING \
    "$repository_root/HealthComp/Services/StagingScoringOperatorControls.swift" \
    "$repository_root/scripts/tests/staging-capture-debugger-fixture.swift" \
    -o "$debugger_scratch/fixture"
  PYTHONDONTWRITEBYTECODE=1 perl -e 'alarm 40; exec @ARGV' xcrun lldb --no-lldbinit --batch \
    -o "command script import '$repository_root/scripts/tests/staging_capture_debugger_reader.py'" \
    -o "healthcomp-capture-check $debugger_scratch/fixture"
done
