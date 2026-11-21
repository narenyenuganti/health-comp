#!/usr/bin/env bash
set -euo pipefail

base="${1:?usage: scripts/verify-website.sh <base-url>}"
base="${base%/}"
token=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
code=AAAAAAAAAAAAAAAAAAAAAA
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
failures=0

expect() {
  local path="$1" status="$2" actual text passed=1
  shift 2
  actual="$(curl -sS -o "$scratch/body" -D "$scratch/headers" -w '%{http_code}' "$base$path")"
  if [[ "$actual" != "$status" ]]; then
    printf 'FAIL %s: HTTP %s, expected %s\n' "$path" "$actual" "$status" >&2
    passed=0
  fi
  for text in "$@"; do
    if ! grep -qaiF -- "$text" "$scratch/headers" "$scratch/body"; then
      printf 'FAIL %s: missing %s\n' "$path" "$text" >&2
      passed=0
    fi
  done
  if [[ "$path" == /support || "$path" == /privacy ]] &&
     ! python3 "$(dirname "${BASH_SOURCE[0]}")/verify-support-email.py" < "$scratch/body"; then
    printf 'FAIL %s: missing support email link\n' "$path" >&2
    passed=0
  fi
  if ((passed)); then
    printf 'ok   %s\n' "$path"
  else
    failures=$((failures + 1))
  fi
}

expect / 200 'Coming soon to iPhone'
expect /support 200 'HealthComp beta support' \
  'Naren Yenuganti' 'Do not send' 'Health screenshots'
expect /privacy 200 'HealthComp privacy' \
  'rounded Activity percentages' 'no fixed automatic deletion schedule' \
  'does not display advertising' 'Former competitor' 'image of a finished match' \
  'Show Me in Search' 'group match'
expect /no-such-page 404 'Page not found'
expect "/invite/$token" 200 'cache-control: no-store' 'referrer-policy: no-referrer' \
  'x-robots-tag: noindex' 'content="https://healthcomp.app/og.png"'
expect "/c/$code" 200 'cache-control: no-store' 'referrer-policy: no-referrer' \
  'x-robots-tag: noindex' 'Open in HealthComp to challenge them'
expect /.well-known/apple-app-site-association 200 'content-type: application/json' \
  '"23LUYD78QK.com.narenyenuganti.HealthComp"' '"23LUYD78QK.com.narenyenuganti.HealthComp.staging"' \
  '"/invite/*"' '"/c/*"'
expect /og.png 200 'content-type: image/png'
expect /apple-touch-icon.png 200 'content-type: image/png'

if [[ "$(curl -sS -o /dev/null -w '%{http_code}' -F email=not-an-email "$base/api/waitlist")" == 400 ]]; then
  printf 'ok   /api/waitlist\n'
else
  printf 'FAIL /api/waitlist: expected 400 for a bad address\n' >&2
  failures=$((failures + 1))
fi

if ((failures)); then
  printf '%d of 10 checks failed\n' "$failures" >&2
  exit 1
fi
