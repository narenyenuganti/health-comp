#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SQL="$SCRIPT_DIR/staging-adversarial-rollback.sql"

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

if has_forbidden_top_level_transaction_control "$SQL" 1; then
  echo "staging adversarial SQL contains forbidden transaction control" >&2
  exit 1
fi

begin_line=$(grep -Ein '^[[:space:]]*begin;[[:space:]]*$' "$SQL" | cut -d: -f1)
fixture_line=$(grep -nF "healthcomp-staging-adversarial-a@example.invalid" "$SQL" | head -n 1 | cut -d: -f1)
rollback_line=$(grep -Ein '^[[:space:]]*rollback;[[:space:]]*$' "$SQL" | cut -d: -f1)
read_only_line=$(grep -Ein '^[[:space:]]*set default_transaction_read_only = on;[[:space:]]*$' "$SQL" | cut -d: -f1)
zero_residue_line=$(grep -nF 'do $zero_residue$' "$SQL" | cut -d: -f1)
receipt_line=$(grep -nF "healthcomp_staging_adversarial_v2" "$SQL" | tail -n 1 | cut -d: -f1)

[ "$begin_line" -lt "$fixture_line" ]
[ "$fixture_line" -lt "$rollback_line" ]
[ "$rollback_line" -lt "$read_only_line" ]
[ "$read_only_line" -lt "$zero_residue_line" ]
[ "$zero_residue_line" -lt "$receipt_line" ]
