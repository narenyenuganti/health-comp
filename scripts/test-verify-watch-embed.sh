#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repository_root/scripts/verify-watch-embed.sh"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-watch-embed-tests.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
app="$fixture_root/HealthComp.app"
watch="$app/Watch/HealthCompWatch.app"
widgets="$watch/PlugIns/HealthCompWatchWidgets.appex"
checks=0
fail() { printf 'FAIL: watch_embed_control_%s\n' "$1" >&2; exit 1; }

info() {
  printf '{"CFBundleIdentifier":"%s","CFBundleShortVersionString":"1.0","CFBundleVersion":"1"}' "$2" \
    | plutil -convert xml1 -o "$1/Info.plist" -
}
fresh() {
  rm -rf "$app"
  mkdir -p "$widgets"
  info "$app" com.example.App
  info "$watch" com.example.App.watchkitapp
  info "$widgets" com.example.App.watchkitapp.widgets
  plutil -insert WKCompanionAppBundleIdentifier -string com.example.App "$watch/Info.plist"
}
expect_fail() {
  local receipt
  if receipt="$(bash "$validator" "$app" 2>&1)"; then
    fail unexpected_acceptance
  fi
  [[ "$receipt" == "FAIL: $1" ]] || fail unexpected_failure_receipt
  checks=$((checks + 1))
  fresh
}

fresh
[[ "$(bash "$validator" "$app" 2>&1)" == 'PASS: watch_embed external_effects=0' ]] \
  || fail unexpected_rejection
checks=$((checks + 1))

plutil -replace WKCompanionAppBundleIdentifier -string com.example.Other "$watch/Info.plist"
expect_fail watch_companion_mismatch
plutil -remove WKCompanionAppBundleIdentifier "$watch/Info.plist"
expect_fail watch_WKCompanionAppBundleIdentifier_missing
plutil -replace CFBundleIdentifier -string com.example.Other.watchkitapp "$watch/Info.plist"
expect_fail watch_id_prefix_mismatch
plutil -replace CFBundleIdentifier -string com.example.Appended "$watch/Info.plist"
expect_fail watch_id_prefix_mismatch
plutil -replace CFBundleIdentifier -string com.example.App.widgets "$widgets/Info.plist"
expect_fail widgets_id_prefix_mismatch
plutil -replace CFBundleVersion -string 2 "$watch/Info.plist"
expect_fail watch_CFBundleVersion_mismatch
plutil -replace CFBundleShortVersionString -string 1.1 "$watch/Info.plist"
expect_fail watch_CFBundleShortVersionString_mismatch
plutil -replace CFBundleVersion -string 2 "$widgets/Info.plist"
expect_fail widgets_CFBundleVersion_mismatch
plutil -replace CFBundleShortVersionString -string 1.1 "$widgets/Info.plist"
expect_fail widgets_CFBundleShortVersionString_mismatch
rm -rf "$widgets"
expect_fail watch_widgets_missing
rm -rf "$watch"
expect_fail watch_app_missing
printf 'PASS: watch_embed_controls checks=%s external_effects=0\n' "$checks"
