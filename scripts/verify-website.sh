#!/usr/bin/env bash
# Smoke-tests the static site in web/ on a running host: `npx wrangler pages
# dev web`, a Pages preview URL, or a live invite host. The invite token is
# fake; never pass or paste a real invite link.
set -euo pipefail

base="${1:?usage: scripts/verify-website.sh <base-url>}"
base="${base%/}"
token=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
failures=0

# expect PATH STATUS [TEXT...]: PATH answers STATUS without a redirect, and
# each TEXT appears (ignoring case) in the response headers or body.
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
  if ((passed)); then
    printf 'ok   %s\n' "$path"
  else
    failures=$((failures + 1))
  fi
}

expect / 200 'Coming soon to iPhone'
expect /support 200 'HealthComp beta support' 'mailto:yrnaren1@gmail.com' \
  'Naren Yenuganti' 'Do not send' 'Health screenshots'
# Without a top-level 404.html, Pages answers every unknown path with
# index.html and 200.
expect /no-such-page 404 'Page not found'
expect "/invite/$token" 200 'cache-control: no-store' 'referrer-policy: no-referrer' \
  'x-robots-tag: noindex' 'content="https://healthcomp.app/og.png"'
expect /.well-known/apple-app-site-association 200 'content-type: application/json' \
  '"23LUYD78QK.com.narenyenuganti.HealthComp"' '"23LUYD78QK.com.narenyenuganti.HealthComp.staging"'
expect /og.png 200 'content-type: image/png'
expect /apple-touch-icon.png 200 'content-type: image/png'

if ((failures)); then
  printf '%d of 7 checks failed\n' "$failures" >&2
  exit 1
fi
