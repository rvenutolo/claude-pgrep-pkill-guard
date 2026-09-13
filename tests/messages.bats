function setup() {
  load 'test_helper/common'
  CASES="${REPO_DIR}/tests/cases/messages.tsv"
}

@test "messages: every recorded message assertion still holds" {
  local cmd_json command field mode needle_json needle
  local count=0 failures=0 json haystack ok
  while IFS=$'\t' read -r cmd_json field mode needle_json; do
    [[ -z "${cmd_json}" ]] && continue
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
        printf 'unknown field: %s\n' "${field}" >&2
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
        printf 'unknown mode: %s\n' "${mode}" >&2
        ok=0
        ;;
    esac

    if ((ok == 0)); then
      printf 'message case failed: %s\n' "${command}" >&2
      printf '  field=%s mode=%s needle=%s\n' "${field}" "${mode}" "${needle}" >&2
      printf '  got: %s\n' "${haystack:0:200}" >&2
      failures=$((failures + 1))
    fi
  done < "${CASES}"

  printf 'checked %s message rows, %s failures\n' "${count}" "${failures}" >&3
  [[ "${count}" -eq 27 ]]
  [[ "${failures}" -eq 0 ]]
}
