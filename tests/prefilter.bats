setup() {
  load 'test_helper/common'
  CASES="${REPO_DIR}/tests/cases/verdicts.tsv"
}

# The trigger tokens, stated here as the specification rather than read out of
# the hook. A test that extracted the list from hooks/pgrep-pkill-guard.sh
# would agree with the hook by construction and assert nothing.
#
# `pkill` is deliberately absent: it contains `kill`, so `kill` subsumes it.
# `.output` covers TASK_OUTPUT_PATH_RE, which requires that literal suffix.
#
# The single source of truth is the array: TRIGGER_RE is built by joining it,
# so the list is stated exactly once in this file.
#
# POSIX short flags on purpose -- see the header of tests/manifest.bats.
readonly -a TRIGGER_TOKENS=('pgrep' 'kill' '\.output')
TRIGGER_RE="$(IFS='|'; echo "${TRIGGER_TOKENS[*]}")"
readonly TRIGGER_RE

@test "prefilter: every non-allow row carries a trigger token" {
  local cmd_json expected command missing=0 checked=0
  while IFS=$'\t' read -r cmd_json expected; do
    [ -z "${cmd_json}" ] && continue
    [ "${expected}" = 'allow' ] && continue
    checked=$((checked + 1))
    command="$(jq --raw-output . <<< "${cmd_json}")"
    if ! printf '%s' "${command}" | grep -qE "${TRIGGER_RE}"; then
      echo "row would be dropped by the prefilter: ${command}" >&2
      echo "verdict: ${expected}" >&2
      missing=$((missing + 1))
    fi
  done < "${CASES}"

  echo "checked ${checked} non-allow rows, ${missing} uncovered" >&3
  [ "${checked}" -gt 0 ]
  [ "${missing}" -eq 0 ]
}

@test "prefilter: the token set is minimal" {
  # Each token must earn its place: dropping any one of the three must leave at
  # least one non-allow row uncovered. This is what stops the set from growing
  # into an always-true filter that quietly restores the old cost.
  local -ar tokens=("${TRIGGER_TOKENS[@]}")
  local i j reduced cmd_json expected command uncovered
  for i in "${!tokens[@]}"; do
    reduced=''
    for j in "${!tokens[@]}"; do
      [ "${i}" = "${j}" ] && continue
      reduced="${reduced:+${reduced}|}${tokens[${j}]}"
    done
    uncovered=0
    while IFS=$'\t' read -r cmd_json expected; do
      [ -z "${cmd_json}" ] && continue
      [ "${expected}" = 'allow' ] && continue
      command="$(jq --raw-output . <<< "${cmd_json}")"
      printf '%s' "${command}" | grep -qE "${reduced}" || uncovered=$((uncovered + 1))
    done < "${CASES}"
    echo "without '${tokens[${i}]}': ${uncovered} rows uncovered" >&3
    [ "${uncovered}" -gt 0 ] || {
      echo "token '${tokens[${i}]}' is redundant; drop it from the hook too" >&2
      return 1
    }
  done
}
