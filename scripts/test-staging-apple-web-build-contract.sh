#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

rg -Fxq 'SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) HEALTHCOMP_STAGING' Configuration/Staging.xcconfig || fail staging_compilation_condition_missing
if rg -q HEALTHCOMP_STAGING Configuration/Base.xcconfig Configuration/Development.xcconfig Configuration/Production.xcconfig; then
  fail ordinary_configuration_enables_staging_code
fi
rg -Fxq 'HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN = NO' Configuration/Base.xcconfig || fail browser_opt_in_not_default_off
rg -Fxq 'HEALTHCOMP_APPLE_WEB_CLIENT_ID =' Configuration/Base.xcconfig || fail services_id_not_unconfigured
rg -Fq 'INFOPLIST_FILE: Configuration/Staging-Info.plist' project.yml || fail staging_plist_not_selected
plutil -lint Configuration/Staging-Info.plist >/dev/null || fail invalid_staging_plist
plutil -convert json -o - Configuration/Staging-Info.plist | jq -e '
  .CFBundleURLTypes[1].CFBundleURLSchemes == ["healthcomp-staging-auth"] and
  .HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN == "$(HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN)" and
  .HEALTHCOMP_APPLE_WEB_CLIENT_ID == "$(HEALTHCOMP_APPLE_WEB_CLIENT_ID)"
' >/dev/null || fail staging_callback_or_opt_in_metadata_invalid
cmp -s \
  <(plutil -convert json -o - HealthComp/Resources/Info.plist | jq -Sc .) \
  <(plutil -convert json -o - Configuration/Staging-Info.plist | jq -Sc 'del(.CFBundleURLTypes[1], .HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN, .HEALTHCOMP_APPLE_WEB_CLIENT_ID)') \
  || fail staging_base_plist_drift
printf 'PASS: staging_browser_build_boundary external_effects=0\n'
