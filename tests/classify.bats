setup() {
  load 'test_helper/common'
  CASES="${REPO_DIR}/tests/cases/verdicts.tsv"
}

# @description Assert one row: run the command through the hook and check the
#              decision, plus the mitigation needle that identifies its kind.
# @arg $1 command the command string to classify
# @arg $2 expected the recorded verdict: allow, warn, or deny:<kind>
# @exitcode 0 the row still holds
# @exitcode 1 it does not
assert_row() {
  local -r command="$1"
  local -r expected="$2"
  local json decision reason needle
  json="$(run_hook "${command}")"

  # On an awk that mishandles RS="\0" (one-true-awk on macOS), any command
  # containing a blank line is tokenized incorrectly, and the scanner's
  # integrity trailer correctly flips the guard to INACTIVE. That is the CORRECT
  # behaviour there, so assert it rather than the normal verdict — otherwise
  # the macOS compat leg is permanently red for a handful of rows.
  if awk_is_paragraph_mode && has_blank_line "${command}"; then
    [[ "${json}" == *'INACTIVE'* ]] || {
      echo "expected INACTIVE under paragraph-mode awk for: ${command}" >&2
      echo "got: ${json}" >&2
      return 1
    }
    return 0
  fi
  decision="$(decision_of "${json}")"
  reason="$(reason_of "${json}")"

  case "${expected}" in
    allow)
      [ "${decision}" = 'none' ] || {
        echo "expected bare {} for: ${command}" >&2
        echo "got: ${json}" >&2
        return 1
      }
      ;;
    warn)
      [ "${decision}" = 'allow' ] || {
        echo "expected allow+context for: ${command}; got ${decision}" >&2
        return 1
      }
      [ -n "$(context_of "${json}")" ] || {
        echo "expected non-empty additionalContext for: ${command}" >&2
        return 1
      }
      ;;
    deny:*)
      [ "${decision}" = 'deny' ] || {
        echo "expected deny for: ${command}; got ${decision}" >&2
        return 1
      }
      case "${expected#deny:}" in
        kill) needle='--ignore-ancestors' ;;
        loop) needle='kill -0' ;;
        task-poll) needle='TaskOutput' ;;
        *)
          echo "unknown deny kind: ${expected}" >&2
          return 1
          ;;
      esac
      [[ "${reason}" == *"${needle}"* ]] || {
        echo "deny reason for '${command}' lacks '${needle}'" >&2
        echo "reason: ${reason}" >&2
        return 1
      }
      ;;
    *)
      echo "unknown expected verdict: ${expected}" >&2
      return 1
      ;;
  esac
}

@test "classify: every recorded verdict still holds" {
  local cmd_json command expected failures=0 count=0
  while IFS=$'\t' read -r cmd_json expected; do
    [ -z "${cmd_json}" ] && continue
    count=$((count + 1))
    command="$(jq --raw-output . <<< "${cmd_json}")"
    if ! assert_row "${command}" "${expected}"; then
      failures=$((failures + 1))
    fi
  done < "${CASES}"

  echo "checked ${count} rows, ${failures} failures" >&3
  [ "${count}" -eq 302 ]
  [ "${failures}" -eq 0 ]
}
