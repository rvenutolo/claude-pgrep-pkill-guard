setup() {
  load 'test_helper/common'
  CASES="${REPO_DIR}/tests/cases/verdicts.tsv"
}

@test "deny-sweep: every deny reason names its own kind's mitigation" {
  local cmd_json command expected needle json reason count=0 failures=0
  while IFS=$'\t' read -r cmd_json expected; do
    [ -z "${cmd_json}" ] && continue
    case "${expected}" in deny:*) ;; *) continue ;; esac
    command="$(jq --raw-output . <<< "${cmd_json}")"
    json="$(run_hook "${command}")"
    # Under an awk that mishandles RS="\0" (one-true-awk on macOS), the
    # scanner's integrity trailer correctly flips the guard to INACTIVE for
    # input that RS="" reshapes — a blank line, or a heredoc body whose
    # trailing newline it strips — so there is no deny reason to sweep.
    # classify.bats owns the INACTIVE assertions for those rows; skipping them
    # here keeps the macOS compat leg honest rather than permanently red. On
    # gawk and mawk this never fires and the sweep stays complete.
    if awk_is_paragraph_mode && [[ "${json}" == *'INACTIVE'* ]]; then
      continue
    fi
    count=$((count + 1))
    case "${expected#deny:}" in
      kill) needle='--ignore-ancestors' ;;
      loop) needle='kill -0' ;;
      task-poll) needle='TaskOutput' ;;
      *)
        # Without this arm an unknown kind leaves needle empty, and
        # [[ "$reason" != *""* ]] can never fire — a silent pass.
        echo "unknown deny kind: ${expected}" >&2
        failures=$((failures + 1))
        continue
        ;;
    esac
    reason="$(reason_of "${json}")"
    if [[ "${reason}" != *"${needle}"* ]]; then
      echo "FAIL: '${command}' (${expected}) reason lacks '${needle}'" >&2
      failures=$((failures + 1))
    fi
  done < "${CASES}"

  echo "swept ${count} deny rows, ${failures} failures" >&3
  # A sweep that finds no deny rows is a broken sweep, not a clean pass.
  [ "${count}" -gt 0 ]
  [ "${failures}" -eq 0 ]
}
