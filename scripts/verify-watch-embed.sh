#!/usr/bin/env bash
# Usage: verify-watch-embed.sh <HealthComp.app>
# Xcode's embed validation passes a wrong companion id, id prefix or version,
# and those only surface at upload.
set -euo pipefail
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
key() { plutil -extract "$2" raw -o - "$1/Info.plist" 2>/dev/null || fail "$3_$2_missing"; }

[[ "$#" == 1 ]] || fail invalid_arguments
app="$1"
watch="$app/Watch/HealthCompWatch.app"
widgets="$watch/PlugIns/HealthCompWatchWidgets.appex"
[[ -f "$app/Info.plist" ]] || fail app_missing
[[ -f "$watch/Info.plist" ]] || fail watch_app_missing
[[ -f "$widgets/Info.plist" ]] || fail watch_widgets_missing

app_id="$(key "$app" CFBundleIdentifier app)"
watch_id="$(key "$watch" CFBundleIdentifier watch)"
widgets_id="$(key "$widgets" CFBundleIdentifier widgets)"
companion_id="$(key "$watch" WKCompanionAppBundleIdentifier watch)"
[[ "$companion_id" == "$app_id" ]] || fail watch_companion_mismatch
[[ "$watch_id" == "$app_id."* ]] || fail watch_id_prefix_mismatch
[[ "$widgets_id" == "$watch_id."* ]] || fail widgets_id_prefix_mismatch

for version_key in CFBundleShortVersionString CFBundleVersion; do
  app_version="$(key "$app" "$version_key" app)"
  watch_version="$(key "$watch" "$version_key" watch)"
  widgets_version="$(key "$widgets" "$version_key" widgets)"
  [[ "$watch_version" == "$app_version" ]] || fail "watch_${version_key}_mismatch"
  [[ "$widgets_version" == "$app_version" ]] || fail "widgets_${version_key}_mismatch"
done
printf 'PASS: watch_embed external_effects=0\n'
