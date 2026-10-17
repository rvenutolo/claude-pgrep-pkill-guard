# The CLASSIFY_SLICE contract of tests/classify.bats: with the variable set to
# `<index>/<count>`, the verdict case grades only that contiguous slice of the
# table, and a value it cannot honour fails the case rather than grading nothing.
# `run-tests --coverage` relies on it to spread the table across parallel kcov
# processes. The suite is driven as a bats subprocess, like any other caller.
#
# setup sets CLASSIFY, the path of the suite under test, and CASES, the table it
# grades.

function setup() {
  load 'test_helper/common'
  CLASSIFY="${REPO_DIR}/tests/classify.bats"
  CASES="${REPO_DIR}/tests/cases/verdicts.tsv"
}

@test "classify slice: a slice grades exactly its share of the rows" {
  local total
  total="$(grep --count --invert-match '^$' "${CASES}")"
  # Slice 0 of 40 is rows 1 through total/40, by the same integer split the
  # sharded run uses, and small enough to keep this case quick.
  CLASSIFY_SLICE='0/40' run bats "${CLASSIFY}"
  assert_success
  assert_output --partial "checked $((total / 40)) rows in slice 0/40, 0 failures"
}

@test "classify slice: the last slice ends at the last row" {
  local total
  total="$(grep --count --invert-match '^$' "${CASES}")"
  CLASSIFY_SLICE='39/40' run bats "${CLASSIFY}"
  assert_success
  assert_output --partial "checked $((total - 39 * total / 40)) rows in slice 39/40, 0 failures"
}

@test "classify slice: a malformed value fails rather than grading nothing" {
  CLASSIFY_SLICE='half' run bats "${CLASSIFY}"
  assert_failure
  assert_output --partial "CLASSIFY_SLICE must be <index>/<count>, got 'half'"
}

@test "classify slice: an index past the last slice fails" {
  CLASSIFY_SLICE='4/4' run bats "${CLASSIFY}"
  assert_failure
  assert_output --partial "CLASSIFY_SLICE must be <index>/<count>, got '4/4'"
}

@test "classify slice: a zero count fails" {
  CLASSIFY_SLICE='0/0' run bats "${CLASSIFY}"
  assert_failure
  assert_output --partial "CLASSIFY_SLICE must be <index>/<count>, got '0/0'"
}
