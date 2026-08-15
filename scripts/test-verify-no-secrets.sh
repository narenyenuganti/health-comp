#!/usr/bin/env bash

set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
scanner="$script_dir/verify-no-secrets.sh"

if [[ ! -f "$scanner" ]]; then
  echo "missing scanner: $scanner" >&2
  exit 1
fi

scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/healthcomp-secret-scan-tests.XXXXXX")"
cleanup() {
  find "$scratch_root" -depth -delete
}
trap cleanup EXIT INT TERM

new_fixture() {
  local name="$1"
  local fixture="$scratch_root/$name"

  if [[ -e "$fixture" ]]; then
    echo "fixture path collision: $name" >&2
    return 1
  fi
  mkdir -p "$fixture/Configuration" "$fixture/Tests"
  git -C "$fixture" init --quiet
  git -C "$fixture" config user.email "healthcomp-ci@example.invalid"
  git -C "$fixture" config user.name "HealthComp CI"

  cat >"$fixture/Configuration/Base.xcconfig" <<'EOF'
SUPABASE_URL =
SUPABASE_PUBLISHABLE_KEY =
EOF
  cat >"$fixture/Configuration/Development.xcconfig" <<'EOF'
#include "Base.xcconfig"
#include? "Development.local.xcconfig"
EOF
  cat >"$fixture/Tests/local_database.txt" <<'EOF'
postgresql://postgres:postgres@127.0.0.1:54322/postgres
EOF
  git -C "$fixture" add Configuration Tests
  git -C "$fixture" commit --quiet -m "test fixture" >/dev/null

  printf '%s\n' "$fixture"
}

run_scan() {
  local fixture="$1"
  local output="$2"
  bash "$scanner" --root "$fixture" >"$output" 2>&1
}

expect_clean() {
  local fixture="$1"
  local output="$scratch_root/clean-output.txt"

  if ! run_scan "$fixture" "$output"; then
    echo "clean fixture was rejected" >&2
    sed -n '1,120p' "$output" >&2
    exit 1
  fi
  if ! grep -q '^No tracked secrets or Debug credentials detected[.]$' "$output"; then
    echo "clean scan did not emit its success marker" >&2
    exit 1
  fi
}

expect_rejected() {
  local fixture="$1"
  local expected_label="$2"
  local expected_path="$3"
  local forbidden_output="$4"
  local output="$scratch_root/rejected-output.txt"

  if run_scan "$fixture" "$output"; then
    echo "unsafe fixture unexpectedly passed: $expected_label" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_label" "$output"; then
    echo "missing finding label: $expected_label" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_path" "$output"; then
    echo "missing finding path: $expected_path" >&2
    exit 1
  fi
  if grep -Fq "$forbidden_output" "$output"; then
    echo "scanner leaked matched credential content" >&2
    exit 1
  fi
}

add_and_commit() {
  local fixture="$1"
  local path="$2"

  case "$fixture" in
    "$scratch_root"/*)
      ;;
    *)
      echo "fixture escaped scratch root" >&2
      exit 1
      ;;
  esac
  if [[ ! -d "$fixture/.git" ]]; then
    echo "fixture is not an isolated Git repository" >&2
    exit 1
  fi
  git -C "$fixture" add -- "$path"
  git -C "$fixture" commit --quiet -m "add unsafe fixture" >/dev/null
}

clean_fixture="$(new_fixture clean)"
expect_clean "$clean_fixture"

filename_cases=(
  ".env|tracked-sensitive-file"
  "Secrets/AuthKey_TEST.p8|tracked-sensitive-file"
  "Secrets/distribution.p12|tracked-sensitive-file"
  "Secrets/distribution.P12|tracked-sensitive-file"
  "Secrets/profile.mobileprovision|tracked-sensitive-file"
  "Configuration/Development.local.xcconfig|tracked-sensitive-file"
)
filename_case_index=0
for entry in "${filename_cases[@]}"; do
  filename_case_index=$((filename_case_index + 1))
  path="${entry%%|*}"
  label="${entry##*|}"
  fixture="$(new_fixture \
    "filename-$filename_case_index-${path//\//-}")"
  mkdir -p "$(dirname "$fixture/$path")"
  printf '%s\n' 'synthetic-sensitive-file-content' >"$fixture/$path"
  add_and_commit "$fixture" "$path"
  expect_rejected "$fixture" "$label" "$path" \
    'synthetic-sensitive-file-content'
done

fixture="$(new_fixture pem)"
pem_header='-----BEGIN '
pem_header+='PRIVATE KEY-----'
pem_body='c3ludGhldGljLW5vdC1hLXJlYWwta2V5'
pem_footer='-----END PRIVATE KEY-----'
printf '%s\n%s\n%s\n' \
  "$pem_header" "$pem_body" "$pem_footer" >"$fixture/Secrets.txt"
add_and_commit "$fixture" Secrets.txt
expect_rejected "$fixture" private-key Secrets.txt "$pem_body"

fixture="$(new_fixture pem-crlf)"
printf '%s\r\n%s\r\n%s\r\n' \
  "$pem_header" "$pem_body" "$pem_footer" >"$fixture/Secrets.pem"
add_and_commit "$fixture" Secrets.pem
expect_rejected "$fixture" private-key Secrets.pem "$pem_body"

fixture="$(new_fixture pem-indented)"
printf '  %s\n  %s\n  %s\n' \
  "$pem_header" "$pem_body" "$pem_footer" >"$fixture/Secrets.yaml"
add_and_commit "$fixture" Secrets.yaml
expect_rejected "$fixture" private-key Secrets.yaml "$pem_body"

fixture="$(new_fixture pem-utf16-bom)"
printf '\377\376' >"$fixture/Secrets.txt"
printf '%s\n%s\n%s\n' \
  "$pem_header" "$pem_body" "$pem_footer" |
  iconv -f UTF-8 -t UTF-16LE >>"$fixture/Secrets.txt"
add_and_commit "$fixture" Secrets.txt
expect_rejected "$fixture" private-key Secrets.txt "$pem_body"

supabase_secret_fixture='sb'
supabase_secret_fixture+='_secret_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
github_token_fixture='gh'
github_token_fixture+='p_abcdefghijklmnopqrstuvwxyz0123456789ABCD'
github_fine_grained_token_fixture='github'
github_fine_grained_token_fixture+='_pat_abcdefghijklmnopqrstuvwxyz_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
aws_access_key_fixture='AK'
aws_access_key_fixture+='IAABCDEFGHIJKLMNOP'
aws_temporary_access_key_fixture='AS'
aws_temporary_access_key_fixture+='IAABCDEFGHIJKLMNOP'
jwt_fixture='ey'
jwt_fixture+='JAAAAAAAAAAAA.eyJBBBBBBBBBBBB.eyJCCCCCCCCCCCC'
database_uri_fixture='postgres'
database_uri_fixture+='ql://healthcomp:do-not-print-this@db.example.com:5432/postgres'
database_query_uri_fixture='postgres'
database_query_uri_fixture+='ql://db.example.com:5432/postgres?password=do-not-print-this'
database_password_assignment_fixture='SUPABASE'
database_password_assignment_fixture+='_DB_PASSWORD=do-not-print-this'

pattern_cases=(
  "supabase-secret|$supabase_secret_fixture"
  "github-token|$github_token_fixture"
  "github-token|$github_fine_grained_token_fixture"
  "aws-access-key|$aws_access_key_fixture"
  "aws-access-key|$aws_temporary_access_key_fixture"
  "literal-jwt|$jwt_fixture"
  "database-password-uri|$database_uri_fixture"
  "database-password-uri|$database_query_uri_fixture"
  "database-password-assignment|$database_password_assignment_fixture"
)
pattern_case_index=0
for entry in "${pattern_cases[@]}"; do
  pattern_case_index=$((pattern_case_index + 1))
  label="${entry%%|*}"
  value="${entry#*|}"
  fixture="$(new_fixture "pattern-$label-$pattern_case_index")"
  printf '%s\n' "$value" >"$fixture/unsafe.txt"
  add_and_commit "$fixture" unsafe.txt
  expect_rejected "$fixture" "$label" unsafe.txt "$value"
done

fixture="$(new_fixture binary-secret)"
printf '\0%s\n' "$supabase_secret_fixture" >"$fixture/unsafe.bin"
add_and_commit "$fixture" unsafe.bin
expect_rejected "$fixture" supabase-secret unsafe.bin \
  "$supabase_secret_fixture"

fixture="$(new_fixture utf16-secret)"
printf '\377\376' >"$fixture/unsafe.txt"
printf '%s\n' "$github_token_fixture" |
  iconv -f UTF-8 -t UTF-16LE >>"$fixture/unsafe.txt"
add_and_commit "$fixture" unsafe.txt
expect_rejected "$fixture" github-token unsafe.txt \
  "$github_token_fixture"

fixture="$(new_fixture utf16-database-assignment)"
printf '\377\376' >"$fixture/unsafe.txt"
printf '%s\n' "$database_password_assignment_fixture" |
  iconv -f UTF-8 -t UTF-16LE >>"$fixture/unsafe.txt"
add_and_commit "$fixture" unsafe.txt
expect_rejected "$fixture" database-password-assignment unsafe.txt \
  "$database_password_assignment_fixture"

fixture="$(new_fixture debug-url)"
cat >"$fixture/Configuration/Base.xcconfig" <<'EOF'
SUPABASE_URL = https://production-ref.supabase.co
SUPABASE_PUBLISHABLE_KEY =
EOF
add_and_commit "$fixture" Configuration/Base.xcconfig
expect_rejected "$fixture" debug-supabase-configuration \
  Configuration/Base.xcconfig https://production-ref.supabase.co

fixture="$(new_fixture debug-key)"
cat >"$fixture/Configuration/Development.xcconfig" <<'EOF'
#include "Base.xcconfig"
SUPABASE_PUBLISHABLE_KEY = sb_publishable_not-for-source-control
EOF
add_and_commit "$fixture" Configuration/Development.xcconfig
expect_rejected "$fixture" debug-supabase-configuration \
  Configuration/Development.xcconfig sb_publishable_not-for-source-control

fixture="$(new_fixture debug-included-config)"
cat >"$fixture/Configuration/Hosted.xcconfig" <<'EOF'
SUPABASE_URL = https://hosted-ref.supabase.co
SUPABASE_PUBLISHABLE_KEY = sb_publishable_not-for-source-control
EOF
cat >"$fixture/Configuration/Development.xcconfig" <<'EOF'
#include "Base.xcconfig"
#include "Hosted.xcconfig"
EOF
add_and_commit "$fixture" Configuration
expect_rejected "$fixture" debug-supabase-configuration \
  Configuration/Hosted.xcconfig https://hosted-ref.supabase.co

fixture="$(new_fixture debug-utf8-bom)"
printf '\357\273\277%s\n' \
  'SUPABASE_URL = https://bom-ref.supabase.co' \
  >"$fixture/Configuration/BOM.xcconfig"
add_and_commit "$fixture" Configuration/BOM.xcconfig
expect_rejected "$fixture" debug-supabase-configuration \
  Configuration/BOM.xcconfig https://bom-ref.supabase.co

echo "Secret/configuration guard tests passed."
