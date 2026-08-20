#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SQL="$SCRIPT_DIR/staging-adversarial-rollback.sql"
WORKFLOW="$SCRIPT_DIR/../.github/workflows/backend.yml"
RUNBOOK="$SCRIPT_DIR/../docs/runbooks/supabase-environments.md"

if [ ! -f "$SQL" ]; then
  echo "staging adversarial SQL is missing" >&2
  exit 1
fi

grep -Eiq '^[[:space:]]*begin;[[:space:]]*$' "$SQL"
grep -Fq "set local statement_timeout = '30s';" "$SQL"
grep -Fq "set local lock_timeout = '5s';" "$SQL"
grep -Fq "set local idle_in_transaction_session_timeout = '30s';" "$SQL"
grep -Fq "set local search_path = pg_catalog, public;" "$SQL"
grep -Fq "set default_transaction_read_only = on;" "$SQL"
grep -Fq "set statement_timeout = '30s';" "$SQL"
grep -Fq "set lock_timeout = '5s';" "$SQL"
grep -Fq "set idle_in_transaction_session_timeout = '30s';" "$SQL"

has_psql_meta_command() {
  grep -Fq '\' "$1"
}

if has_psql_meta_command "$SQL"; then
  echo "staging adversarial SQL must not contain backslashes or psql meta-commands" >&2
  exit 1
fi

grep -Fq "'anonymous_cross_account_reads'" "$SQL"
grep -Fq "'participant_scope_isolation'" "$SQL"
grep -Fq "'outsider_scope_isolation'" "$SQL"
grep -Fq "'stale_deleted_profile_isolation'" "$SQL"
grep -Fq "'raw_secret_table_denial'" "$SQL"
grep -Fq "'direct_mutation_denial'" "$SQL"
grep -Fq "'same_claimant_replay_is_idempotent'" "$SQL"
grep -Fq "'different_claimant_replay_is_denied'" "$SQL"
grep -Fq "'modified_score_without_grant_is_denied'" "$SQL"
grep -Fq "'bound_app_attest_score_tampering_is_denied'" "$SQL"
grep -Fq "'divergent_duplicate_is_rejected'" "$SQL"
grep -Fq "'revision_regression_is_rejected'" "$SQL"
grep -Fq "'cross_table_authenticated_isolation'" "$SQL"
grep -Fq "'result_rewrite_is_denied'" "$SQL"
grep -Fq "'unregistered_installation_is_denied'" "$SQL"

grep -Fq "invite_unavailable" "$SQL"
grep -Fq "app_attest_grant_unavailable" "$SQL"
grep -Fq "wire_digest_mismatch" "$SQL"
grep -Fq "divergent_duplicate" "$SQL"
grep -Fq "revision_regression" "$SQL"
grep -Fq "insufficient_privilege" "$SQL"
grep -Fq "competition_invites" "$SQL"
grep -Fq "competition_change_log" "$SQL"
grep -Fq "support_events" "$SQL"
grep -Fq "apns_token" "$SQL"
grep -Fq "auth_user_id" "$SQL"
grep -Fq "private.app_attest_keys" "$SQL"
grep -Fq "private.app_attest_challenges" "$SQL"
grep -Fq "private.app_attest_submission_grants" "$SQL"
grep -Fq "consumed_at is null" "$SQL"

has_forbidden_top_level_transaction_control() {
  awk -v require_boundaries="${2:-0}" '
    function append_space() {
      if (outside_sql == "" || substr(outside_sql, length(outside_sql), 1) != " ") {
        outside_sql = outside_sql " "
      }
    }

    function dollar_delimiter_at(value, position, remainder) {
      remainder = substr(value, position)
      if (substr(remainder, 1, 2) == "$$") {
        return "$$"
      }
      if (match(remainder, /^\$[A-Za-z_][A-Za-z0-9_]*\$/)) {
        return substr(remainder, RSTART, RLENGTH)
      }
      return ""
    }

    BEGIN {
      lexical_state = "normal"
      single_quote_character = sprintf("%c", 39)
    }

    {
      line = $0
      position = 1

      while (position <= length(line)) {
        character = substr(line, position, 1)
        pair = substr(line, position, 2)

        if (lexical_state == "block_comment") {
          if (pair == "/*") {
            block_comment_depth++
            position += 2
          } else if (pair == "*/") {
            block_comment_depth--
            position += 2
            if (block_comment_depth == 0) {
              lexical_state = "normal"
              append_space()
            }
          } else {
            position++
          }
          continue
        }

        if (lexical_state == "single_quote") {
          if (single_quote_backslash_escapes && character == "\\") {
            position += 2
          } else if (pair == single_quote_character single_quote_character) {
            position += 2
          } else if (character == single_quote_character) {
            lexical_state = "normal"
            single_quote_backslash_escapes = 0
            append_space()
            position++
          } else {
            position++
          }
          continue
        }

        if (lexical_state == "double_quote") {
          if (pair == "\"\"") {
            position += 2
          } else if (character == "\"") {
            lexical_state = "normal"
            append_space()
            position++
          } else {
            position++
          }
          continue
        }

        if (lexical_state == "dollar_quote") {
          if (substr(line, position, length(dollar_delimiter)) == dollar_delimiter) {
            lexical_state = "normal"
            append_space()
            position += length(dollar_delimiter)
          } else {
            position++
          }
          continue
        }

        if (pair == "--") {
          append_space()
          break
        }
        if (pair == "/*") {
          lexical_state = "block_comment"
          block_comment_depth = 1
          append_space()
          position += 2
          continue
        }
        if ((character == "E" || character == "e") && substr(line, position + 1, 1) == single_quote_character) {
          found = 1
          lexical_state = "single_quote"
          single_quote_backslash_escapes = 1
          append_space()
          position += 2
          continue
        }
        if (character == single_quote_character) {
          lexical_state = "single_quote"
          single_quote_backslash_escapes = 0
          append_space()
          position++
          continue
        }
        if (character == "\"") {
          lexical_state = "double_quote"
          append_space()
          position++
          continue
        }
        if (character == "$") {
          dollar_delimiter = dollar_delimiter_at(line, position)
          if (dollar_delimiter != "") {
            lexical_state = "dollar_quote"
            append_space()
            position += length(dollar_delimiter)
            continue
          }
        }

        outside_sql = outside_sql character
        position++
      }

      if (lexical_state == "normal") {
        append_space()
      }
    }

    END {
      if (lexical_state != "normal") {
        found = 1
      }

      statement_count = split(outside_sql, statements, ";")
      for (statement_index = 1; statement_index <= statement_count; statement_index++) {
        candidate = tolower(statements[statement_index])
        gsub(/[[:space:]]+/, " ", candidate)
        sub(/^ /, "", candidate)
        sub(/ $/, "", candidate)
        if (candidate != "") {
          nonempty_statement_count++
          if (nonempty_statement_count == 1) {
            first_statement = candidate
          }
        }
        if (candidate == "begin") {
          exact_begin_count++
        } else if (candidate == "rollback") {
          exact_rollback_count++
        }
        forbidden = candidate ~ /^(commit|end|abort)( |$)/ || (candidate ~ /^rollback( |$)/ && candidate != "rollback") || (candidate ~ /^begin( |$)/ && candidate != "begin") || candidate ~ /^(start|prepare) transaction( |$)/ || candidate ~ /^(discard all|reset all)$/ || candidate ~ /transaction read write/
        if (forbidden) {
          found = 1
        }
      }
      if (require_boundaries && (exact_begin_count != 1 || exact_rollback_count != 1 || first_statement != "begin")) {
        found = 1
      }
      exit found ? 0 : 1
    }
  ' "$1"
}

for transaction_end in \
  'COMMIT;' 'commit work;' 'COMMIT TRANSACTION;' \
  'END;' 'end work;' 'END TRANSACTION;' \
  'COMMIT; -- comment' 'select 1; COMMIT;' \
  'COMMIT WORK AND CHAIN;' 'END TRANSACTION AND NO CHAIN;' \
  'COMMIT/*comment*/WORK;' 'ROLLBACK WORK;' 'ROLLBACK PREPARED x;' \
  'ABORT;' 'BEGIN WORK;' 'START TRANSACTION;' 'PREPARE TRANSACTION x;'
do
  if ! printf '%s\n' "$transaction_end" \
    | has_forbidden_top_level_transaction_control -
  then
    echo "staging adversarial transaction guard missed: $transaction_end" >&2
    exit 1
  fi
done

if ! printf '%s\n' '-- $probe$' 'COMMIT;' \
  | has_forbidden_top_level_transaction_control -
then
  echo "staging adversarial transaction guard trusted a dollar tag in a comment" >&2
  exit 1
fi

if ! printf '%s\n' 'select 1; COMMIT' 'WORK AND NO CHAIN;' \
  | has_forbidden_top_level_transaction_control -
then
  echo "staging adversarial transaction guard missed multiline COMMIT" >&2
  exit 1
fi

if printf '%s\n' 'do $probe$' 'begin' 'end;' '$probe$;' 'rollback;' \
  | has_forbidden_top_level_transaction_control -
then
  echo "staging adversarial transaction guard rejected a procedural END" >&2
  exit 1
fi

if ! printf '%s\n' 'begin;' 'select 1; ROLLBACK;' 'rollback;' \
  | has_forbidden_top_level_transaction_control - 1
then
  echo "staging adversarial transaction guard missed an inline exact ROLLBACK" >&2
  exit 1
fi

if ! printf '%s\n' 'select 1;' 'begin;' 'rollback;' \
  | has_forbidden_top_level_transaction_control - 1
then
  echo "staging adversarial transaction guard allowed work before BEGIN" >&2
  exit 1
fi

if ! printf '%s\n' "select E'foo\\'bar'; COMMIT; -- '" \
  | has_forbidden_top_level_transaction_control -
then
  echo "staging adversarial transaction guard was desynchronized by an E string" >&2
  exit 1
fi

if ! printf '%s\n' "SELECT 'COMMIT;' \\gexec" \
  | has_psql_meta_command -
then
  echo "staging adversarial psql guard missed an inline meta-command" >&2
  exit 1
fi

if has_forbidden_top_level_transaction_control "$SQL" 1; then
  echo "staging adversarial SQL contains forbidden transaction control" >&2
  exit 1
fi

rollback_count=$(grep -Eic '^[[:space:]]*rollback;[[:space:]]*$' "$SQL")
[ "$rollback_count" -eq 1 ]

begin_count=$(grep -Eic '^[[:space:]]*begin;[[:space:]]*$' "$SQL")
[ "$begin_count" -eq 1 ]

read_only_setting_count=$(grep -Fic 'default_transaction_read_only' "$SQL")
[ "$read_only_setting_count" -eq 1 ]

statement_timeout_count=$(grep -Fc 'statement_timeout' "$SQL")
[ "$statement_timeout_count" -eq 2 ]

lock_timeout_count=$(grep -Fc 'lock_timeout' "$SQL")
[ "$lock_timeout_count" -eq 2 ]

idle_timeout_count=$(grep -Fc 'idle_in_transaction_session_timeout' "$SQL")
[ "$idle_timeout_count" -eq 2 ]

begin_line=$(grep -Ein '^[[:space:]]*begin;[[:space:]]*$' "$SQL" | cut -d: -f1)
fixture_line=$(grep -nF "healthcomp-staging-adversarial-a@example.invalid" "$SQL" | head -n 1 | cut -d: -f1)
rollback_line=$(grep -Ein '^[[:space:]]*rollback;[[:space:]]*$' "$SQL" | cut -d: -f1)
read_only_line=$(grep -Ein '^[[:space:]]*set default_transaction_read_only = on;[[:space:]]*$' "$SQL" | cut -d: -f1)
post_rollback_statement_timeout_line=$(grep -Ein "^[[:space:]]*set statement_timeout = '30s';[[:space:]]*$" "$SQL" | cut -d: -f1)
post_rollback_lock_timeout_line=$(grep -Ein "^[[:space:]]*set lock_timeout = '5s';[[:space:]]*$" "$SQL" | cut -d: -f1)
post_rollback_idle_timeout_line=$(grep -Ein "^[[:space:]]*set idle_in_transaction_session_timeout = '30s';[[:space:]]*$" "$SQL" | cut -d: -f1)
zero_residue_line=$(grep -nF 'do $zero_residue$' "$SQL" | cut -d: -f1)
receipt_line=$(grep -nF "healthcomp_staging_adversarial_v1" "$SQL" | tail -n 1 | cut -d: -f1)
last_nonblank_line=$(awk 'NF { value = $0 } END { print value }' "$SQL")

[ "$begin_line" -lt "$fixture_line" ]
[ "$fixture_line" -lt "$rollback_line" ]
[ "$read_only_line" -eq "$((rollback_line + 2))" ]
[ "$post_rollback_statement_timeout_line" -eq "$((read_only_line + 1))" ]
[ "$post_rollback_lock_timeout_line" -eq "$((post_rollback_statement_timeout_line + 1))" ]
[ "$post_rollback_idle_timeout_line" -eq "$((post_rollback_lock_timeout_line + 1))" ]
[ "$zero_residue_line" -eq "$((post_rollback_idle_timeout_line + 2))" ]
[ "$rollback_line" -lt "$receipt_line" ]
[ "$last_nonblank_line" = ') as healthcomp_staging_adversarial_receipt;' ]

grep -Fq "'syntheticRowsRemaining', 0" "$SQL"
grep -Fq "'privateValuesReturned', false" "$SQL"
grep -Fq "'transactionOutcome', 'rolled_back'" "$SQL"
grep -Fq "'assertionsPassed', 15" "$SQL"

grep -Fq 'sh scripts/test-staging-adversarial-sql.sh' "$WORKFLOW"
grep -Fq '< scripts/staging-adversarial-rollback.sql' "$WORKFLOW"
grep -Fq -- '--password \' "$RUNBOOK"
grep -Fq -- '--set=ON_ERROR_STOP=1 \' "$RUNBOOK"
grep -Fq 'PGSSLMODE=verify-full \' "$RUNBOOK"
grep -Fq 'PGSSLROOTCERT=' "$RUNBOOK"
grep -Fq 'SSL-enforcement' "$RUNBOOK"
grep -Fq '15 passed assertions' "$RUNBOOK"
grep -Fq 'A local or CI receipt does not count as hosted staging' "$RUNBOOK"
