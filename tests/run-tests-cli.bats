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

# @description Skip a case that drives `run-tests --awk=bwk`. That path is
#              devShell-only by construction and the two ambient compat legs run
#              this suite against whatever the runner ships, so it has to be
#              probed rather than assumed. Skipping there is honest: the
#              hermetic gate leg is the one that grades the flag, and a test
#              that quietly rewrote the invocation to something ambient tools
#              accept would be grading a command run-tests never runs.
#
#              Three separate things have to hold, and each of them has already
#              been observed NOT to on some leg:
#
#              1. `nawk` on PATH at all.
#              2. That `nawk` is genuinely one-true-awk. `command -v nawk` is
#                 not enough -- ubuntu-latest ships a `nawk` that IS gawk, and
#                 run-tests then dies with "expected one-true-awk at the head of
#                 PATH, got: GNU Awk 5.2.1". So the version string is checked
#                 here the same way use_bwk_awk checks it after the swap.
#              3. GNU coreutils, because use_bwk_awk builds its shim directory
#                 with `mktemp --directory`, `ln --symbolic` and
#                 `head --lines=1`. macOS ships BSD, which has none of them.
# @noargs
function require_bwk_awk() {
  if ! command -v nawk > /dev/null 2>&1; then
    skip 'nawk is not on PATH; --awk=bwk is graded by the hermetic gate leg'
  fi
  local version=''
  version="$(nawk --version 2>&1 | head -n 1)" || version='<no version output>'
  case "${version}" in
    'awk version '*) ;;
    *) skip "nawk is not one-true-awk (${version}); --awk=bwk is graded by the hermetic gate leg" ;;
  esac
  local probe=''
  if ! probe="$(mktemp --directory 2> /dev/null)"; then
    skip 'mktemp has no --directory (BSD coreutils); --awk=bwk is graded by the hermetic gate leg'
  fi
  rm -rf "${probe}"
}

# @description Skip a case that needs kcov to actually run. `--coverage` is
#              Linux-only by construction -- nixpkgs declares no darwin kcov, so
#              the devShell does not carry it on macOS -- and the two ambient
#              compat legs run this suite against whatever the runner ships,
#              where kcov is absent on both. Skipping there is honest for the
#              same reason require_bwk_awk skips: the hermetic Linux gate leg is
#              the one that grades this flag, and a case that quietly degraded to
#              "run without kcov" would be grading a command run-tests never
#              runs.
#
#              Argument-parsing cases do NOT call this. Rejecting `--coverage`
#              with no directory is pure parsing and must be graded on every leg,
#              including the ones with no kcov -- that is where a flag silently
#              forwarded to bats as a test path would show up first.
# @noargs
function require_kcov() {
  if ! command -v kcov > /dev/null 2>&1; then
    skip 'kcov is not on PATH; --coverage is graded by the hermetic Linux gate leg'
  fi
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

@test "run-tests: --coverage with no argument is rejected" {
  # No require_kcov: this is parsing, and it must hold on a leg with no kcov.
  # The `[run-tests] FATAL:` prefix is what makes it non-vacuous, exactly as in
  # the --report case above -- a run-tests that did not know --coverage would
  # forward it to bats as a test path, and bats would fail too, with the same
  # string in its output.
  run "${RUN_TESTS}" --coverage
  assert_failure
  assert_output --partial '[run-tests] FATAL:'
  assert_output --partial '--coverage'
}

@test "run-tests: --coverage writes a report and keeps terminal output" {
  require_kcov
  local -r suite="${BATS_TEST_TMPDIR}/suite5/ok.bats"
  local -r out="${BATS_TEST_TMPDIR}/cov"
  make_trivial_suite "${suite}"
  run "${RUN_TESTS}" --coverage "${out}" "${suite}"
  assert_success
  assert_output --partial 'trivial fixture case'
  [ -d "${out}" ]
  # Exactly the shape .ci/report-coverage looks for: one level down, and not the
  # empty kcov-merged/ kcov leaves beside it.
  [ -n "$(find "${out}" -mindepth 2 -maxdepth 2 -path '*/kcov-merged/*' -prune -o -name 'coverage.json' -print -quit)" ]
}

@test "run-tests: --coverage creates a directory that does not exist yet" {
  require_kcov
  local -r suite="${BATS_TEST_TMPDIR}/suite6/ok.bats"
  local -r out="${BATS_TEST_TMPDIR}/nested2/deeper/cov"
  make_trivial_suite "${suite}"
  run "${RUN_TESTS}" --coverage "${out}" "${suite}"
  assert_success
  [ -d "${out}" ]
}

@test "run-tests: --coverage and --report compose in either order" {
  require_kcov
  local -r suite="${BATS_TEST_TMPDIR}/suite7/ok.bats"
  make_trivial_suite "${suite}"
  run "${RUN_TESTS}" --coverage "${BATS_TEST_TMPDIR}/c1" --report "${BATS_TEST_TMPDIR}/r3" "${suite}"
  assert_success
  [ -n "$(find "${BATS_TEST_TMPDIR}/r3" -name '*.xml' -print -quit)" ]
  run "${RUN_TESTS}" --report "${BATS_TEST_TMPDIR}/r4" --coverage "${BATS_TEST_TMPDIR}/c2" "${suite}"
  assert_success
  [ -n "$(find "${BATS_TEST_TMPDIR}/r4" -name '*.xml' -print -quit)" ]
}

@test "run-tests: COVERAGE is not exported when --coverage is absent" {
  # The guard in tests/test_helper/common.bash keys off COVERAGE, so an ordinary
  # run leaking it would silently stop unsetting BASH_ENV for every test in the
  # suite. Graded through the fixture suite's own environment rather than by
  # reading run-tests, so it survives a rewrite of how the flag is plumbed.
  #
  # `env -u COVERAGE` is what makes the case mean what it says, and it is not
  # theoretical: the first version omitted it and went red under `just coverage`
  # and nowhere else. A coverage run exports COVERAGE=1 into everything below
  # it, this suite included, so the inner run-tests INHERITED the variable and
  # the case could not tell that apart from run-tests having exported it. Clear
  # it first and the assertion grades run-tests, which is the subject.
  local -r suite="${BATS_TEST_TMPDIR}/suite8/env.bats"
  mkdir -p "$(dirname "${suite}")"
  cat > "${suite}" << 'BATS'
@test "COVERAGE is unset" {
  [ -z "${COVERAGE:-}" ]
}
BATS
  run env -u COVERAGE "${RUN_TESTS}" "${suite}"
  assert_success
}
