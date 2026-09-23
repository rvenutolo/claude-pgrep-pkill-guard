# `run --separate-stderr` is a bats 1.5.0 flag: the usage line belongs on
# stderr, and a merged capture cannot tell it apart from a stray stdout write.
bats_require_minimum_version 1.5.0

function setup() {
  load 'test_helper/common'
  FIXTURE="${BATS_TEST_TMPDIR}/repo"
  STUB_DIR="${BATS_TEST_TMPDIR}/stubs"
  MARKER="${BATS_TEST_TMPDIR}/gate-ran"
  make_fixture
}

# @description Build the throwaway repo these cases run the gate in: a bare
#              `git init` holding a copy of run-all-checks and nothing else,
#              plus a `nix` stub on PATH that only touches a marker.
#
#              Never the real script in the real repo. Every case here feeds
#              an argument shape the gate should reject, and the gate used to
#              run anyway -- including `run-tests`, which runs this very file
#              again, recursing through the whole gate. In the fixture every
#              `${REPO_DIR}/...` callee is missing, so a gate that wrongly runs
#              only collects exit 127s it already absorbs with `|| rc=1`; the
#              `nix` stub, the first check it would reach, is the evidence
#              that it ran at all.
#
#              `mkdir -p` because the compat CI legs run this suite against
#              macOS BSD coreutils, whose mkdir has no long form.
#
#              Builds at the FIXTURE, STUB_DIR and MARKER paths setup() chose.
# @noargs
function make_fixture() {
  mkdir -p "${FIXTURE}" "${STUB_DIR}"
  git init --quiet "${FIXTURE}"
  cp "${REPO_DIR}/run-all-checks" "${FIXTURE}/run-all-checks"
  printf '#!/bin/sh\ntouch "%s"\n' "${MARKER}" > "${STUB_DIR}/nix"
  chmod +x "${STUB_DIR}/nix"
}

# @description Run the fixture's run-all-checks from inside the fixture, with
#              the stub first on PATH. The script finds its repo with
#              `git rev-parse --show-toplevel`, so the cd is the fixture
#              selection.
# @arg $@ args the arguments to hand the gate
function gate_in_fixture() {
  (cd "${FIXTURE}" && PATH="${STUB_DIR}:${PATH}" ./run-all-checks "$@")
}

# @description `run` the gate in the fixture, stdout and stderr apart.
# @arg $@ args the arguments to hand the gate
function run_gate() {
  run --separate-stderr gate_in_fixture "$@"
}

# @description Assert the shape of a rejected invocation: exit 2 (the gates'
#              "you called it wrong", distinct from 1, the gate's verdict), the
#              usage line on stderr, nothing on stdout, and no check run.
# @noargs
function assert_rejected() {
  assert_failure 2
  assert_output ''
  assert_equal "${stderr}" 'usage: run-all-checks [--report DIR]'
  [[ ! -e "${MARKER}" ]]
}

@test "run-all-checks: a bare --report is rejected, not ignored" {
  # A caller who asked for a report and got a green run with no report would
  # never know the flag had been dropped.
  run_gate --report
  assert_rejected
}

@test "run-all-checks: an empty --report directory is rejected" {
  run_gate --report ''
  assert_rejected
}

@test "run-all-checks: an unknown flag is rejected, not ignored" {
  run_gate --output "${BATS_TEST_TMPDIR}/out"
  assert_rejected
}

@test "run-all-checks: a surplus argument after --report DIR is rejected" {
  run_gate --report "${BATS_TEST_TMPDIR}/out" extra
  assert_rejected
}

@test "run-all-checks: a lone positional is rejected" {
  run_gate "${BATS_TEST_TMPDIR}/out"
  assert_rejected
}

@test "run-all-checks: no arguments runs the gate" {
  # Every callee is missing from the fixture, so the verdict is a failure; the
  # point is that the gate ran rather than stopping at the argument check.
  run_gate
  assert_failure 1
  [[ -e "${MARKER}" ]]
}

@test "run-all-checks: --report DIR runs the gate" {
  run_gate --report "${BATS_TEST_TMPDIR}/out"
  assert_failure 1
  [[ -e "${MARKER}" ]]
}
