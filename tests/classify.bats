# The recorded verdicts: every row of tests/cases/verdicts.tsv is run through
# the hook as a subprocess (invariant 3), and the response is graded against
# the verdict the row records.
#
# With CLASSIFY_SLICE set to `<index>/<count>`, the verdict case grades only
# that contiguous slice of the table, in one shard: `run-tests --coverage` sets
# it to spread the table across parallel kcov processes, each with its own
# trace pipe. tests/classify-slice.bats pins the contract.
#
# setup sets CASES, the path of that table.

function setup() {
  load 'test_helper/common'
  CASES="${REPO_DIR}/tests/cases/verdicts.tsv"
}

# @description Assert one row: run the command through the hook and check the
#              decision, plus the mitigation needle that identifies its kind.
# @arg $1 command the command string to classify
# @arg $2 expected the recorded verdict: allow, warn, or deny:<kind>
# @stderr the expected-versus-got diagnostic, on a row that no longer holds
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
    'allow')
      [[ "${decision}" == 'none' ]] || {
        printf 'expected bare {} for: %s\n' "${command}" >&2
        printf 'got: %s\n' "${json}" >&2
        return 1
      }
      ;;
    'warn')
      [[ "${decision}" == 'allow' ]] || {
        printf 'expected allow+context for: %s; got %s\n' "${command}" "${decision}" >&2
        return 1
      }
      [[ -n "$(context_of "${json}")" ]] || {
        printf 'expected non-empty additionalContext for: %s\n' "${command}" >&2
        return 1
      }
      ;;
    deny:*)
      [[ "${decision}" == 'deny' ]] || {
        printf 'expected deny for: %s; got %s\n' "${command}" "${decision}" >&2
        return 1
      }
      case "${expected#deny:}" in
        'kill') needle='--ignore-ancestors' ;;
        'loop') needle='kill -0' ;;
        'task-poll') needle='TaskOutput' ;;
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

# @description Print how many shards to grade the rows in: the CPU count, or one
#              under COVERAGE (`run-tests --coverage` sets CLASSIFY_SLICE
#              instead, and never asks). kcov reads every child bash's
#              xtrace from one shared pipe and tracks quote state across its
#              lines, so concurrent hooks interleaving their traces would lose
#              coverage at random. `nproc` is GNU (the devShell and ambient
#              Linux); stock macOS has `getconf` and `sysctl` instead. One shard
#              is always correct, only slower, so it is the last resort rather
#              than a failure.
# @noargs
# @stdout the shard count
function shard_count() {
  if [[ -n "${COVERAGE:-}" ]]; then
    printf '1\n'
    return 0
  fi
  nproc 2> /dev/null \
    || getconf _NPROCESSORS_ONLN 2> /dev/null \
    || sysctl -n hw.ncpu 2> /dev/null \
    || printf '1\n'
}

# @description Grade one contiguous slice of the table's non-empty rows, writing
#              its diagnostics to <dir>/<shard>.log and `<rows> <failures>` to
#              <dir>/<shard>.verdict. The verdict is written last, so a shard
#              that dies early leaves none and the caller can tell.
# @arg $1 shard this shard's index, from 0
# @arg $2 shards the number of shards
# @arg $3 total the number of non-empty rows in the table
# @arg $4 dir the directory to write the log and verdict into
function grade_shard() {
  local -r shard="$1"
  local -r shards="$2"
  local -r total="$3"
  local -r dir="$4"
  local -r first="$((shard * total / shards))"
  local -r last="$(((shard + 1) * total / shards))"
  local cmd_json command expected row=0 count=0 failures=0
  while IFS=$'\t' read -r cmd_json expected; do
    [[ -z "${cmd_json}" ]] && continue
    row="$((row + 1))"
    ((row > first && row <= last)) || continue
    count="$((count + 1))"
    command="$(jq --raw-output '.' <<< "${cmd_json}")"
    if ! assert_row "${command}" "${expected}" 2>> "${dir}/${shard}.log"; then
      failures="$((failures + 1))"
    fi
  done < "${CASES}"
  printf '%s %s\n' "${count}" "${failures}" > "${dir}/${shard}.verdict"
}

# Each row is a whole hook subprocess, so the rows are graded in parallel shards.
# The shards are contiguous slices, and their logs are printed in shard order, so
# failures come out in table order whatever the CPU count. Under CLASSIFY_SLICE
# the one shard graded is that slice, out of as many shards as the value names.
@test "classify: every recorded verdict still holds" {
  local -r dir="${BATS_TEST_TMPDIR}/shards"
  local shards first_shard end_shard total shard verdict rows bad count=0 failures=0 expected label
  total="$(grep --count --invert-match '^$' "${CASES}")"
  # Checked whether or not a slice is set: a slice's own count is derived from
  # the table, so only this line notices rows going missing from it.
  [[ "${total}" -eq 2480 ]]
  if [[ -n "${CLASSIFY_SLICE:-}" ]]; then
    if [[ ! "${CLASSIFY_SLICE}" =~ ^(0|[1-9][0-9]*)/([1-9][0-9]*)$ ]] \
      || ((BASH_REMATCH[1] >= BASH_REMATCH[2])); then
      printf "CLASSIFY_SLICE must be <index>/<count>, got '%s'\n" "${CLASSIFY_SLICE}" >&2
      return 1
    fi
    first_shard="${BASH_REMATCH[1]}"
    shards="${BASH_REMATCH[2]}"
    end_shard="$((first_shard + 1))"
    expected="$(((first_shard + 1) * total / shards - first_shard * total / shards))"
    label="slice ${CLASSIFY_SLICE}"
  else
    shards="$(shard_count)"
    first_shard=0
    end_shard="${shards}"
    expected="${total}"
    label="${shards} shards"
  fi
  mkdir "${dir}"
  for ((shard = first_shard; shard < end_shard; shard++)); do
    # fd 3 closed: bats waits on it, and a job holding it open hangs the run.
    grade_shard "${shard}" "${shards}" "${total}" "${dir}" 3>&- &
  done
  wait

  for ((shard = first_shard; shard < end_shard; shard++)); do
    if [[ -s "${dir}/${shard}.log" ]]; then
      cat -- "${dir}/${shard}.log" >&2
    fi
    verdict=''
    if [[ -f "${dir}/${shard}.verdict" ]]; then
      read -r verdict < "${dir}/${shard}.verdict" || true # a verdict with no newline still reads
    fi
    if [[ ! "${verdict}" =~ ^[0-9]+\ [0-9]+$ ]]; then
      # The shard died before it could say. Never a silent pass.
      printf 'shard %s of %s left no verdict\n' "${shard}" "${shards}" >&2
      failures="$((failures + 1))"
      continue
    fi
    read -r rows bad <<< "${verdict}"
    count="$((count + rows))"
    failures="$((failures + bad))"
  done

  printf 'checked %s rows in %s, %s failures\n' "${count}" "${label}" "${failures}" >&3
  [[ "${count}" -eq "${expected}" ]]
  [[ "${failures}" -eq 0 ]]
}
