#!/usr/bin/env bash

# In-memory documentation mutations; never execute SQL or runbook commands.
set -euo pipefail
runbook_path="${1:-docs/runbooks/backup-restore.md}"
checker_path="$(dirname "$0")/test-backup-runbook.sh"
bash "$checker_path" "$runbook_path"
failures=0

for mutation in empty_assertions moved_guard duplicate_import cross_fence_bash; do
  candidate="$(awk -v mutation="$mutation" '
    mutation == "empty_assertions" && /^do \$healthcomp_origin_after_(data|history)\$$/ {
      print; skipping = 1; changed++; next
    }
    skipping {
      if ($0 ~ /^\$healthcomp_origin_after_(data|history)\$;$/) {
        print "begin\nnull;\nend"; print; skipping = 0
      }
      next
    }
    mutation == "moved_guard" && $0 == "set local row_security = off;" {
      guards++
      if (guards == 1) { changed++; next }
      print
    }
    mutation == "duplicate_import" {
      if ($0 == "\\i migration-history.sql") { $0 = "\\i data.sql"; changed++ }
      gsub(/healthcomp_origin_after_history/, "healthcomp_origin_after_data")
      gsub(/migration_history_did_not_restore_origin/, "data_dump_did_not_restore_origin")
    }
    mutation == "cross_fence_bash" && /^~~~bash$/ {
      fences++; print
      if (fences == 1) { print "if true; then"; changed++ }
      if (fences == 2) { print "fi"; changed++ }
      next
    }
    { print }
    END {
      expected = (mutation == "empty_assertions" || mutation == "cross_fence_bash") ? 2 : 1
      if (changed != expected || skipping) { exit 2 }
    }
  ' "$runbook_path")"
  if printf '%s\n' "$candidate" | bash "$checker_path" - >/dev/null 2>&1; then
    printf 'backup_runbook_check_regression: accepted_%s\n' "$mutation" >&2
    failures=$((failures + 1))
  else
    printf 'Rejected documentation mutation: %s\n' "$mutation"
  fi
done

[[ "$failures" -eq 0 ]]
printf '%s\n' 'All four static-check negative controls passed; no recovery executed.'
