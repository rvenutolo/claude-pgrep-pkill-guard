function setup() {
  load 'test_helper/common'
  CASES="${REPO_DIR}/tests/cases/verdicts.tsv"
}

# @description Assert one row: run the command through the hook and check the
#              decision, plus the mitigation needle that identifies its kind.
# @arg $1 command the command string to classify
# @arg $2 expected the recorded verdict: allow, warn, or deny:<kind>
# @exitcode 0 the row still holds
# @exitcode 1 it does not
function assert_row() {
  local -r command="$1"
  local -r expected="$2"
  local json decision reason needle
  json="$(run_hook "${command}")"
  decision="$(decision_of "${json}")"
  reason="$(reason_of "${json}")"

  case "${expected}" in
    allow)
      [ "${decision}" = 'none' ] || {
        printf 'expected bare {} for: %s\n' "${command}" >&2
        printf 'got: %s\n' "${json}" >&2
        return 1
      }
      ;;
    warn)
      [ "${decision}" = 'allow' ] || {
        printf 'expected allow+context for: %s; got %s\n' "${command}" "${decision}" >&2
        return 1
      }
      [ -n "$(context_of "${json}")" ] || {
        printf 'expected non-empty additionalContext for: %s\n' "${command}" >&2
        return 1
      }
      ;;
    deny:*)
      [ "${decision}" = 'deny' ] || {
        printf 'expected deny for: %s; got %s\n' "${command}" "${decision}" >&2
        return 1
      }
      case "${expected#deny:}" in
        kill) needle='--ignore-ancestors' ;;
        loop) needle='kill -0' ;;
        task-poll) needle='TaskOutput' ;;
        *)
          printf 'unknown deny kind: %s\n' "${expected}" >&2
          return 1
          ;;
      esac
      [[ "${reason}" == *"${needle}"* ]] || {
        printf "deny reason for '%s' lacks '%s'\n" "${command}" "${needle}" >&2
        printf 'reason: %s\n' "${reason}" >&2
        return 1
      }
      ;;
    *)
      printf 'unknown expected verdict: %s\n' "${expected}" >&2
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

  printf 'checked %s rows, %s failures\n' "${count}" "${failures}" >&3
  [ "${count}" -eq 350 ]
  [ "${failures}" -eq 0 ]
}
