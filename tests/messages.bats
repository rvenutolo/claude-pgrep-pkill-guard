setup() {
  load 'test_helper/common'
  CASES="${REPO_DIR}/tests/cases/messages.tsv"
}

@test "messages: every recorded message assertion still holds" {
  local cmd_json command field mode needle_json needle
  local count=0 failures=0 json haystack ok
  while IFS=$'\t' read -r cmd_json field mode needle_json; do
    [ -z "${cmd_json}" ] && continue
    count=$((count + 1))
    command="$(jq --raw-output . <<< "${cmd_json}")"
    needle="$(jq --raw-output . <<< "${needle_json}")"
    json="$(run_hook "${command}")"

    # field selects which part of the response the assertion is about.
    case "${field}" in
      reason) haystack="$(reason_of "${json}")" ;;
      context) haystack="$(context_of "${json}")" ;;
      decision) haystack="$(decision_of "${json}")" ;;
      *)
        echo "unknown field: ${field}" >&2
        failures=$((failures + 1))
        continue
        ;;
    esac

    # mode selects the comparison. `lacks` asserts ABSENCE — getting this
    # backwards would silently invert 5 of the 27 rows.
    ok=1
    case "${mode}" in
      contains) [[ "${haystack}" == *"${needle}"* ]] || ok=0 ;;
      lacks) [[ "${haystack}" != *"${needle}"* ]] || ok=0 ;;
      equals) [[ "${haystack}" == "${needle}" ]] || ok=0 ;;
      *)
        echo "unknown mode: ${mode}" >&2
        ok=0
        ;;
    esac

    if ((ok == 0)); then
      echo "message case failed: ${command}" >&2
      echo "  field=${field} mode=${mode} needle=${needle}" >&2
      echo "  got: ${haystack:0:200}" >&2
      failures=$((failures + 1))
    fi
  done < "${CASES}"

  echo "checked ${count} message rows, ${failures} failures" >&3
  [ "${count}" -eq 27 ]
  [ "${failures}" -eq 0 ]
}
