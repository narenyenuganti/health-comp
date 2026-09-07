#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repository_root/scripts/verify-app-privacy-manifest.sh"
source_manifest="$repository_root/HealthComp/Resources/PrivacyInfo.xcprivacy"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-privacy-tests.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
checks=0
fail() { printf 'FAIL: privacy_control_%s\n' "$1" >&2; exit 1; }

expect_pass() {
  local receipt
  receipt="$(bash "$validator" "$@" 2>&1)" || fail unexpected_rejection
  [[ "$receipt" == 'PASS: app_required_reason_manifest external_effects=0' ]] \
    || fail unexpected_pass_receipt
  checks=$((checks + 1))
}
expect_fail() {
  local expected="$1" receipt
  shift
  if receipt="$(bash "$validator" "$@" 2>&1)"; then
    fail unexpected_acceptance
  fi
  [[ "$receipt" == "FAIL: $expected" ]] || fail unexpected_failure_receipt
  checks=$((checks + 1))
}
mutant() {
  plutil -convert json -o - "$source_manifest" | jq "$2" > "$fixture_root/$1.json"
  plutil -convert xml1 "$fixture_root/$1.json"
  expect_fail app_privacy_reasons_mismatch --manifest "$fixture_root/$1.json"
}

expect_pass
expect_fail app_privacy_manifest_missing --manifest "$fixture_root/absent.xcprivacy"
printf 'not a property list\n' > "$fixture_root/malformed.xcprivacy"
expect_fail app_privacy_manifest_malformed --manifest "$fixture_root/malformed.xcprivacy"
mutant missing_category 'del(.NSPrivacyAccessedAPITypes[0])'
mutant wrong_reason '.NSPrivacyAccessedAPITypes[0].NSPrivacyAccessedAPITypeReasons = ["DDA9.1"]'
mutant duplicate_category '.NSPrivacyAccessedAPITypes += [.NSPrivacyAccessedAPITypes[0]]'
mutant unknown_category '.NSPrivacyAccessedAPITypes[0].NSPrivacyAccessedAPIType = "Unknown"'
mutant empty_reasons '.NSPrivacyAccessedAPITypes[0].NSPrivacyAccessedAPITypeReasons = []'
mutant extra_reason '.NSPrivacyAccessedAPITypes[0].NSPrivacyAccessedAPITypeReasons += ["DDA9.1"]'
mutant extra_entry_key '.NSPrivacyAccessedAPITypes[0].unexpected = true'
mutant unreviewed_no_collection '.NSPrivacyCollectedDataTypes = []'

fixture_bundle="$fixture_root/HealthComp.app"
mkdir -p "$fixture_bundle/Dependency.bundle"
cp "$source_manifest" "$fixture_bundle/Dependency.bundle/PrivacyInfo.xcprivacy"
expect_fail app_privacy_manifest_missing --app-bundle "$fixture_bundle"
cp "$source_manifest" "$fixture_bundle/PrivacyInfo.xcprivacy"
expect_pass --app-bundle "$fixture_bundle"
cp "$fixture_root/wrong_reason.json" "$fixture_bundle/PrivacyInfo.xcprivacy"
expect_fail app_privacy_reasons_mismatch --app-bundle "$fixture_bundle"
expect_fail app_bundle_missing --app-bundle "$fixture_root/Missing.app"
expect_fail invalid_arguments --unknown value
printf 'PASS: app_privacy_manifest_controls=%s external_effects=0\n' "$checks"
