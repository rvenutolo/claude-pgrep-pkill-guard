setup() {
  load 'test_helper/common'
  RUN_TESTS="${REPO_DIR}/run-tests"
}

# @description Write a trivial always-passing bats file into the fixture dir, so
#              these cases grade run-tests' ARGUMENT HANDLING rather than the
#              real suite. Running the real suite from inside itself would be
#              slow, recursive and would double every fixture-escape check.
#              POSIX short flags on purpose -- see the header of
#              tests/manifest.bats.
# @arg $1 path the .bats file to write
function make_trivial_suite() {
  local -r path="$1"
  mkdir -p "$(dirname "${path}")"
  cat > "${path}" << 'BATS'
@test "trivial fixture case" {
  [ 1 -eq 1 ]
}
BATS
}

# @description Skip a case that drives `run-tests --awk=bwk`. That path needs
#              nawk on PATH and it builds its shim directory with GNU
#              `mktemp --directory`, `ln --symbolic` and `head --lines=1`, so it
#              is devShell-only by construction. The two ambient compat legs run
#              this suite against whatever the runner ships, and macOS ships
#              BSD coreutils. Skipping there is honest: the hermetic gate leg is
#              the one that grades the flag, and a test that quietly rewrote the
#              invocation to something BSD accepts would be grading a command
#              run-tests never runs.
# @noargs
function require_bwk_awk() {
  if ! command -v nawk > /dev/null 2>&1; then
    skip 'nawk is not on PATH; --awk=bwk is graded by the hermetic gate leg'
  fi
  local probe=''
  if ! probe="$(mktemp --directory 2> /dev/null)"; then
    skip 'mktemp has no --directory (BSD coreutils); --awk=bwk is graded by the hermetic gate leg'
  fi
  rm -rf "${probe}"
}

@test "run-tests: --report writes a JUnit file and keeps terminal output" {
  local -r suite="${BATS_TEST_TMPDIR}/suite/ok.bats"
  local -r out="${BATS_TEST_TMPDIR}/report"
  make_trivial_suite "${suite}"
  run "${RUN_TESTS}" --report "${out}" "${suite}"
  assert_success
  assert_output --partial 'trivial fixture case'
  [ -d "${out}" ]
  [ -n "$(find "${out}" -name '*.xml' -print -quit)" ]
}

@test "run-tests: --report creates a directory that does not exist yet" {
  local -r suite="${BATS_TEST_TMPDIR}/suite2/ok.bats"
  local -r out="${BATS_TEST_TMPDIR}/nested/deeper/report"
  make_trivial_suite "${suite}"
  run "${RUN_TESTS}" --report "${out}" "${suite}"
  assert_success
  [ -d "${out}" ]
}

@test "run-tests: --report with no argument is rejected" {
  run "${RUN_TESTS}" --report
  assert_failure
  # The `[run-tests] FATAL:` prefix, not just the flag name, is what makes this
  # case non-vacuous: a run-tests that did not know --report at all would
  # forward it to bats as a test path, and bats would also exit non-zero with
  # the string `--report` in its own error. Asserting run-tests' own die()
  # prefix pins WHO rejected it.
  assert_output --partial '[run-tests] FATAL:'
  assert_output --partial '--report'
}

@test "run-tests: --awk=bwk and --report are accepted in either order" {
  require_bwk_awk
  local -r suite="${BATS_TEST_TMPDIR}/suite3/ok.bats"
  make_trivial_suite "${suite}"
  run "${RUN_TESTS}" --awk=bwk --report "${BATS_TEST_TMPDIR}/r1" "${suite}"
  assert_success
  run "${RUN_TESTS}" --report "${BATS_TEST_TMPDIR}/r2" --awk=bwk "${suite}"
  assert_success
}

@test "run-tests: no report is written when --report is absent" {
  local -r suite="${BATS_TEST_TMPDIR}/suite4/ok.bats"
  make_trivial_suite "${suite}"
  run "${RUN_TESTS}" "${suite}"
  assert_success
  [ -z "$(find "${BATS_TEST_TMPDIR}" -name '*.xml' -print -quit)" ]
}
