#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: $0 [--root <git-repository>]" >&2
}

repository_root=""
if [[ $# -eq 0 ]]; then
  repository_root="$(git rev-parse --show-toplevel)"
elif [[ $# -eq 2 && "$1" == "--root" ]]; then
  repository_root="$(git -C "$2" rev-parse --show-toplevel)"
else
  usage
  exit 2
fi

cd "$repository_root"
export LC_ALL=C

finding_count=0
report_finding() {
  local label="$1"
  local path="$2"
  echo "$label: $path" >&2
  finding_count=$((finding_count + 1))
}

restore_case_sensitive_matching=0
if ! shopt -q nocasematch; then
  shopt -s nocasematch
  restore_case_sensitive_matching=1
fi

while IFS= read -r -d '' tracked_path; do
  case "$tracked_path" in
    .env | */.env | .env.* | */.env.* | \
      *.p8 | *.p12 | *.pfx | *.mobileprovision | *.local.xcconfig | \
      .pgpass | */.pgpass | credentials.json | */credentials.json)
      report_finding tracked-sensitive-file "$tracked_path"
      ;;
  esac
done < <(git ls-files -z)

if [[ "$restore_case_sensitive_matching" -eq 1 ]]; then
  shopt -u nocasematch
fi

normalized_staged_blob() {
  local tracked_path="$1"

  git show ":$tracked_path" |
    tr -d '\000' |
    sed $'1s/^\xEF\xBB\xBF//;1s/^\xFF\xFE//;1s/^\xFE\xFF//'
}

scan_pattern() {
  local label="$1"
  local pattern="$2"
  local tracked_path

  while IFS= read -r -d '' tracked_path; do
    if normalized_staged_blob "$tracked_path" |
      grep -aE -- "$pattern" >/dev/null; then
      report_finding "$label" "$tracked_path"
    fi
  done < <(git ls-files -z)
}

# Match a complete PEM header line, including CRLF and indented block scalars,
# rather than source code that merely contains a PEM-validation expression.
scan_pattern private-key \
  '^[[:space:]]*-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----[[:space:]]*$'
scan_pattern aws-access-key '(AKIA|ASIA)[0-9A-Z]{16}'
scan_pattern github-token \
  '(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{20,})'
scan_pattern supabase-access-token 'sbp_[A-Za-z0-9]{20,}'
scan_pattern supabase-secret 'sb_secret_[A-Za-z0-9_-]{20,}'
scan_pattern stripe-secret 'sk_(live|test)_[A-Za-z0-9]{20,}'
scan_pattern literal-jwt \
  'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
scan_pattern database-password-assignment \
  '^[[:space:]]*(export[[:space:]]+)?(SUPABASE_DB_PASSWORD|PGPASSWORD)[[:space:]]*=[[:space:]]*[^[:space:]#]'
scan_pattern database-password-uri \
  'postgres(ql)?://[^[:space:]]*[?&]password=[^[:space:]&#]+'

while IFS= read -r -d '' database_path; do
  unsafe_database_uri=0
  while IFS= read -r database_uri; do
    case "$database_uri" in
      postgres://*:*@127.0.0.1:*/* | \
        postgres://*:*@localhost:*/* | \
        postgresql://*:*@127.0.0.1:*/* | \
        postgresql://*:*@localhost:*/*)
        ;;
      *)
        unsafe_database_uri=1
        ;;
    esac
  done < <(
    normalized_staged_blob "$database_path" |
      grep -aEo 'postgres(ql)?://[^[:space:]:]+:[^[:space:]@]+@[^[:space:]]+' || true
  )
  if [[ "$unsafe_database_uri" -eq 1 ]]; then
    report_finding database-password-uri "$database_path"
  fi
done < <(git ls-files -z)

while IFS= read -r -d '' configuration_path; do
  case "$configuration_path" in
    Configuration/*.xcconfig)
      if normalized_staged_blob "$configuration_path" |
        grep -Eq \
          '^[[:space:]]*(SUPABASE_URL|SUPABASE_PUBLISHABLE_KEY)[[:space:]]*=[[:space:]]*[^[:space:]#]'; then
        report_finding debug-supabase-configuration "$configuration_path"
      fi
      ;;
  esac
done < <(git ls-files -z)

if [[ "$finding_count" -ne 0 ]]; then
  echo "Tracked secret/configuration scan failed with $finding_count finding(s)." >&2
  exit 1
fi

echo "No tracked secrets or Debug credentials detected."
