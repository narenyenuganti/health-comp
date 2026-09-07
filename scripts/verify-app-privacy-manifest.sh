#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_manifest="$repository_root/HealthComp/Resources/PrivacyInfo.xcprivacy"
manifest_path="$source_manifest"
verify_bundle=false
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

case "$#" in
  0) ;;
  2)
    case "$1" in
      --manifest) manifest_path="$2" ;;
      --app-bundle)
        [[ -d "$2" ]] || fail app_bundle_missing
        manifest_path="$2/PrivacyInfo.xcprivacy"
        verify_bundle=true
        ;;
      *) fail invalid_arguments ;;
    esac
    ;;
  *) fail invalid_arguments ;;
esac

[[ -f "$manifest_path" ]] || fail app_privacy_manifest_missing
plutil -lint "$manifest_path" >/dev/null 2>&1 || fail app_privacy_manifest_malformed
manifest_json="$(plutil -convert json -o - "$manifest_path" 2>/dev/null)" \
  || fail app_privacy_manifest_malformed
jq -e '
  keys == ["NSPrivacyAccessedAPITypes"] and
  (.NSPrivacyAccessedAPITypes | sort_by(.NSPrivacyAccessedAPIType)) == [
    {"NSPrivacyAccessedAPIType":"NSPrivacyAccessedAPICategoryFileTimestamp", "NSPrivacyAccessedAPITypeReasons":["C617.1"]},
    {"NSPrivacyAccessedAPIType":"NSPrivacyAccessedAPICategorySystemBootTime", "NSPrivacyAccessedAPITypeReasons":["35F9.1"]},
    {"NSPrivacyAccessedAPIType":"NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPITypeReasons":["CA92.1"]}
  ]
' <<<"$manifest_json" >/dev/null 2>&1 || fail app_privacy_reasons_mismatch

if "$verify_bundle"; then
  [[ -f "$source_manifest" ]] || fail source_privacy_manifest_missing
  source_json="$(plutil -convert json -o - "$source_manifest" 2>/dev/null)" \
    || fail source_privacy_manifest_malformed
  [[ "$(jq -Sc . <<<"$manifest_json")" == "$(jq -Sc . <<<"$source_json")" ]] \
    || fail packaged_privacy_manifest_drift
fi
printf 'PASS: app_required_reason_manifest external_effects=0\n'
