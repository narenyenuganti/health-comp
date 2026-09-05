#!/usr/bin/env bash
# Static parser regression tests only. Read synthetic Markdown streams; never
# execute SQL, invoke the runtime harness path, connect, or create scratch files.
set -euo pipefail

recovery_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
recovery_audit="$recovery_script_dir/recovery-foreign-key-integrity.sql"
recovery_checker="$recovery_script_dir/test-recovery-foreign-key-integrity.sh"
[[ -s "$recovery_audit" && -s "$recovery_checker" ]] || {
  printf '%s\n' 'recovery_fk_static_assertion: required_source_missing' >&2
  exit 1
}
[[ "$#" -eq 0 ]] || exit 1

recovery_emit_document() {
  local recovery_case="$1"
  case "$recovery_case" in
    standalone_tilde)
      printf '%s\n' '~~~sql'; cat "$recovery_audit"; printf '%s\n' '~~~' ;;
    standalone_backtick)
      printf '%s\n' '```sql'; cat "$recovery_audit"; printf '%s\n' '```' ;;
    surrounding_other_fences)
      printf '%s\n' '~~~bash' 'echo synthetic' '~~~' '~~~sql'
      cat "$recovery_audit"
      printf '%s\n' '~~~' '```text' 'synthetic' '```' ;;
    longer_indented_fence)
      printf '%s\n' '   ~~~~sql'; cat "$recovery_audit"; printf '%s\n' '   ~~~~~' ;;
    byte_mismatch)
      printf '%s\n' '~~~sql'; cat "$recovery_audit"
      printf '%s\n' '-- synthetic byte mismatch' '~~~' ;;
    duplicate)
      recovery_emit_document standalone_tilde
      recovery_emit_document standalone_backtick ;;
    unterminated)
      printf '%s\n' '~~~sql'; cat "$recovery_audit" ;;
    nested_other_fence)
      printf '%s\n' '~~~bash' '~~~sql'; cat "$recovery_audit"
      printf '%s\n' '~~~' '~~~' ;;
    nested_longer_other_fence)
      printf '%s\n' '~~~~bash' '~~~sql'; cat "$recovery_audit"
      printf '%s\n' '~~~' '~~~~' ;;
    nested_other_delimiter)
      printf '%s\n' '```bash' '~~~sql'; cat "$recovery_audit"
      printf '%s\n' '~~~' '```' ;;
    wrong_closing_delimiter)
      printf '%s\n' '~~~sql'; cat "$recovery_audit"; printf '%s\n' '```' ;;
    *) return 1 ;;
  esac
}

recovery_check_document() {
  local recovery_case="$1" recovery_expected_exit="$2" recovery_exit=0 recovery_output
  recovery_output="$(recovery_emit_document "$recovery_case" | \
    bash "$recovery_checker" --static - 2>&1)" || recovery_exit=$?
  [[ "$recovery_exit" -eq "$recovery_expected_exit" ]] || {
    printf 'recovery_fk_static_assertion: %s_exit\n' "$recovery_case" >&2
    exit 1
  }
  if [[ "$recovery_expected_exit" -eq 0 ]]; then
    [[ "$recovery_output" == 'FK audit documentation is byte-identical; no SQL executed.' ]] || exit 1
  else
    [[ "$recovery_output" == 'recovery_fk_assertion: documented_audit_drift' ]] || exit 1
  fi
  printf 'Passed static FK parser control: %s\n' "$recovery_case"
}

# Run the original nested-fence regression before extending accepted fence shapes.
recovery_check_document standalone_tilde 0
recovery_check_document byte_mismatch 1
recovery_check_document duplicate 1
recovery_check_document unterminated 1
recovery_check_document nested_other_fence 1
recovery_check_document standalone_backtick 0
recovery_check_document surrounding_other_fences 0
recovery_check_document longer_indented_fence 0
recovery_check_document nested_longer_other_fence 1
recovery_check_document nested_other_delimiter 1
recovery_check_document wrong_closing_delimiter 1
printf '%s\n' 'All 11 static FK parser controls passed; no SQL or database runtime executed.'
