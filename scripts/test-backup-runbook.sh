#!/usr/bin/env bash

# Static regression checks only. Never execute the documented SQL or shell.
set -euo pipefail
runbook_path="${1:-docs/runbooks/backup-restore.md}"

awk '
  function fail(reason) {
    print "backup_runbook_static: " reason > "/dev/stderr"
    failed = 1
  }
  function expected_assertion(kind, quote, error_name) {
    quote = sprintf("%c", 39)
    error_name = kind == "data" ? "data_dump_did_not_restore_origin" : "migration_history_did_not_restore_origin"
    return "begin\nif current_setting(" quote "session_replication_role" quote ") <> " quote "origin" quote " then\nraise exception " quote error_name quote ";\nend if;\nend\n"
  }
  /^~~~bash$/ {
    if (fence != "") { fail("nested_code_fence") }
    fence = "bash"; bash_source = ""; next
  }
  /^~~~sql$/ {
    if (fence != "") { fail("nested_code_fence") }
    fence = "sql"; next
  }
  /^~~~$/ {
    if (fence == "bash") { bash_blocks[++bash_count] = bash_source }
    if (fence == "sql" && receipt_open) { fail("receipt_transaction_not_closed") }
    fence = ""
    next
  }
  {
    if (fence == "bash") { bash_source = bash_source $0 "\n" }
    if ($0 ~ /pg_catalog\.[cC][oO][aA][lL][eE][sS][cC][eE][[:space:]]*\(/) {
      fail("coalesce_must_use_special_expression_syntax")
    }
    if (fence == "sql") {
      if ($0 ~ /^begin transaction/) {
        if (receipt_open) { fail("nested_receipt_transaction") }
        if ($0 != "begin transaction isolation level repeatable read read only;") {
          fail("receipt_requires_repeatable_read_read_only")
        }
        receipt_open = 1; receipt_transactions++; visibility_guards = 0; queried = 0
      }
      if ($0 == "set local row_security = off;") {
        if (!receipt_open || queried || visibility_guards != 0) {
          fail("receipt_visibility_guard_misplaced_or_duplicated")
        }
        visibility_guards++
      }
      if (receipt_open && $0 ~ /^(select|with|do)[[:space:]]/) {
        queried = 1
        if (visibility_guards != 1) { fail("receipt_query_missing_visibility_guard") }
      }
      if ($0 == "rollback;") {
        if (!receipt_open || visibility_guards != 1) { fail("receipt_guard_missing_at_rollback") }
        receipt_open = 0; completed_receipts++
      }
    }
    if (assertion_kind != "") {
      if ($0 == "$healthcomp_origin_after_" assertion_kind "$;") {
        if (assertion_body != expected_assertion(assertion_kind)) {
          fail("origin_assertion_body_does_not_match_reviewed_failure_check")
        } else { import_assertions[assertion_kind]++ }
        assertion_kind = ""
      } else {
        normalized = $0
        sub(/^[[:space:]]+/, "", normalized); sub(/[[:space:]]+$/, "", normalized)
        if (normalized != "") { assertion_body = assertion_body normalized "\n" }
      }
      next
    }
    if (pending_assertion != "" && $0 !~ /^[[:space:]]*$/) {
      if ($0 != "do $healthcomp_origin_after_" pending_assertion "$") {
        fail("dump_origin_assertion_must_immediately_follow_import")
      } else { assertion_kind = pending_assertion; assertion_body = "" }
      pending_assertion = ""
    }
    if (fence == "bash" && $0 == "\\i data.sql") {
      imports["data"]++; pending_assertion = "data"
    }
    if (fence == "bash" && $0 == "\\i migration-history.sql") {
      imports["history"]++; pending_assertion = "history"
    }
  }
  END {
    if (fence != "") { fail("unclosed_code_fence") }
    if (receipt_transactions != 2 || completed_receipts != 2 || receipt_open) {
      fail("both_receipt_transactions_required")
    }
    if (imports["data"] != 1 || imports["history"] != 1 ||
        import_assertions["data"] != 1 || import_assertions["history"] != 1 ||
        pending_assertion != "" || assertion_kind != "") {
      fail("each_distinct_import_requires_one_complete_origin_assertion")
    }
    if (bash_count == 0) { fail("no_bash_snippets_found") }
    if (failed) { exit 1 }
    for (block_number = 1; block_number <= bash_count; block_number++) {
      printf "%s%c", bash_blocks[block_number], 0
    }
  }
' "$runbook_path" | while IFS= read -r -d '' bash_snippet; do
  printf '%s' "$bash_snippet" | bash -n
done

printf '%s\n' 'Runbook snippet structure passed; no SQL or recovery executed.'
