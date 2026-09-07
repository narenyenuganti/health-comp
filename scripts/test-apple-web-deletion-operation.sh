#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
deletion_scratch="$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-web-deletion.XXXXXX")"
cleanup() {
  if [[ -d "$deletion_scratch" && ! -L "$deletion_scratch" &&
        "$(basename -- "$deletion_scratch")" == healthcomp-web-deletion.* ]]; then
    rm -r -- "$deletion_scratch"
  fi
}
trap cleanup EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors -D HEALTHCOMP_STAGING \
  "$repository_root/HealthComp/Services/StagingAppleWebAuthenticationConfiguration.swift" \
  "$repository_root/HealthComp/Services/AppleWebAuthenticationSessionClient.swift" \
  "$repository_root/HealthComp/Services/AppleWebAccountDeletionClient.swift" \
  "$repository_root/scripts/tests/apple-web-deletion-operation.swift" \
  -o "$deletion_scratch/operation"
"$deletion_scratch/operation"
