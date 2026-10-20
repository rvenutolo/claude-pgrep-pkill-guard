# run-all-checks' argument handling, in a throwaway repo with `nix`,
# `run-tests`, `.ci/check-devshell-provides` and `bench/run` stubs: a malformed
# invocation is rejected with exit 2 and the usage line, and a well-formed one
# runs the gate, with the suite under the awks --awk asks for and the checks
# --scope selects.
#
# `run --separate-stderr` is a bats 1.5.0 flag: the usage line belongs on
# stderr, and a merged capture cannot tell it apart from a stray stdout write.
#
# setup sets FIXTURE, the throwaway repo the gate runs in, STUB_DIR, the
# directory holding the `nix` stub, MARKER, the file that stub touches, RUNS,
# the file the `run-tests` stub appends its arguments to, and PLATFORM, the file
# the `.ci/check-devshell-provides` and `bench/run` stubs append to.
bats_require_minimum_version 1.5.0

function setup() {
  load 'test_helper/common'
  FIXTURE="${BATS_TEST_TMPDIR}/repo"
  STUB_DIR="${BATS_TEST_TMPDIR}/stubs"
  MARKER="${BATS_TEST_TMPDIR}/gate-ran"
  RUNS="${BATS_TEST_TMPDIR}/suite-runs"
  PLATFORM="${BATS_TEST_TMPDIR}/platform-checks"
  make_fixture
}

# @description Build the throwaway repo these cases run the gate in: a bare
#              `git init` holding a copy of run-all-checks, a `run-tests` stub
#              that records each call's arguments as one line, stubs for the
#              platform-sensitive checks `.ci/check-devshell-provides` and
#              `bench/run` that each record a line of their own, plus a `nix`
#              stub that only touches a marker.
#
#              Never the real script in the real repo. The rejection cases feed
#              an argument shape the gate should reject, and the gate used to
#              run anyway -- including `run-tests`, which runs this very file
#              again, recursing through the whole gate. In the fixture every
#              `${REPO_DIR}/...` callee but the stubs is missing, so
#              a gate that wrongly runs only collects exit 127s it already
#              absorbs with `|| rc=1`; the `nix` stub, which the gate calls, is
#              the evidence that it ran at all.
#
#              A short flag only where macOS has no long form, on purpose: a
#              compat CI leg runs this suite against macOS BSD coreutils, whose
#              mkdir has no --parents.
#
#              Builds at the FIXTURE and STUB_DIR paths setup() chose; the `nix`
#              stub touches MARKER, the `run-tests` stub appends to RUNS, and
#              the platform-check stubs append to PLATFORM. Those stubs keep out
#              of RUNS so it still holds suite runs alone.
# @noargs
function make_fixture() {
  mkdir -p "${FIXTURE}/.ci" "${FIXTURE}/bench" "${STUB_DIR}"
  git init --quiet "${FIXTURE}"
  cp -- "${REPO_DIR}/run-all-checks" "${FIXTURE}/run-all-checks"
  printf '#!/bin/sh\ntouch "%s"\n' "${MARKER}" > "${STUB_DIR}/nix"
  chmod +x "${STUB_DIR}/nix"
  printf '#!/bin/sh\nprintf '"'"'%%s\\n'"'"' "$*" >> "%s"\n' "${RUNS}" > "${FIXTURE}/run-tests"
  chmod +x "${FIXTURE}/run-tests"
  printf '#!/bin/sh\necho devshell-provides >> "%s"\n' "${PLATFORM}" > "${FIXTURE}/.ci/check-devshell-provides"
  chmod +x "${FIXTURE}/.ci/check-devshell-provides"
  printf '#!/bin/sh\necho "bench $*" >> "%s"\n' "${PLATFORM}" > "${FIXTURE}/bench/run"
  chmod +x "${FIXTURE}/bench/run"
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
  assert_equal "${stderr}" \
    'usage: run-all-checks [--scope=shared|--scope=platform] [--awk=gawk|--awk=bwk] [--report DIR]'
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
  run_gate --report "${BATS_TEST_TMPDIR}/out" 'extra'
  assert_rejected
}

@test "run-all-checks: a lone positional is rejected" {
  run_gate "${BATS_TEST_TMPDIR}/out"
  assert_rejected
}

@test "run-all-checks: no arguments runs the gate" {
  # Every `${REPO_DIR}/...` callee but the stubs is missing from the
  # fixture, so the verdict is a failure; the point is that the gate ran rather than stopping at the
  # argument check.
  run_gate
  assert_failure 1
  [[ -e "${MARKER}" ]]
}

@test "run-all-checks: --report DIR runs the gate" {
  run_gate --report "${BATS_TEST_TMPDIR}/out"
  assert_failure 1
  [[ -e "${MARKER}" ]]
}

@test "run-all-checks: an unknown awk is rejected" {
  run_gate --awk=mawk
  assert_rejected
}

@test "run-all-checks: a bare --awk is rejected" {
  run_gate --awk
  assert_rejected
}

@test "run-all-checks: a repeated --awk is rejected, even naming the same awk" {
  run_gate --awk=gawk --awk=gawk
  assert_rejected
}

@test "run-all-checks: a --report directory that looks like a flag is rejected" {
  # Taken as a directory, it would swallow the flag: `--report --awk=gawk` would
  # run both awks and write the report under ./--awk=gawk.
  run_gate --report --awk=gawk
  assert_rejected
}

@test "run-all-checks: a repeated --report is rejected" {
  run_gate --report "${BATS_TEST_TMPDIR}/a" --report "${BATS_TEST_TMPDIR}/b"
  assert_rejected
}

@test "run-all-checks: no --awk runs the suite under gawk, then one-true-awk" {
  run_gate
  assert_failure 1
  assert_equal "$(cat -- "${RUNS}")" "$(printf '\n--awk=bwk')"
}

@test "run-all-checks: --awk=gawk runs the suite once, under gawk" {
  run_gate --awk=gawk
  assert_failure 1
  assert_equal "$(cat -- "${RUNS}")" ''
  assert_equal "$(grep --count '' "${RUNS}")" 1
}

@test "run-all-checks: --awk=bwk runs the suite once, under one-true-awk" {
  run_gate --awk=bwk
  assert_failure 1
  assert_equal "$(cat -- "${RUNS}")" '--awk=bwk'
}

@test "run-all-checks: --awk and --report combine, in either order" {
  local -r out="${BATS_TEST_TMPDIR}/out"
  run_gate --awk=bwk --report "${out}"
  assert_failure 1
  run_gate --report "${out}" --awk=gawk
  assert_failure 1
  assert_equal "$(cat -- "${RUNS}")" "$(printf '%s\n' "--awk=bwk --report ${out}/bwk" "--report ${out}/gawk")"
}

@test "run-all-checks: --scope=shared runs the flake check and no suite" {
  run_gate --scope=shared
  assert_failure 1
  [[ -e "${MARKER}" ]]
  [[ ! -e "${RUNS}" ]]
  [[ ! -e "${PLATFORM}" ]]
}

@test "run-all-checks: --scope=platform runs the suite and check-devshell-provides, not the flake check" {
  # Every callee this scope reaches is a stub, so nothing is missing and the
  # verdict is a pass: a shared check run by mistake would exit 127 and fail it.
  run_gate --scope=platform
  assert_success
  [[ ! -e "${MARKER}" ]]
  assert_equal "$(cat -- "${PLATFORM}")" "$(printf '%s\n' 'devshell-provides' 'bench --smoke')"
  assert_equal "$(cat -- "${RUNS}")" "$(printf '\n--awk=bwk')"
}

@test "run-all-checks: no --scope runs both" {
  run_gate
  assert_failure 1
  [[ -e "${MARKER}" ]]
  assert_equal "$(cat -- "${PLATFORM}")" "$(printf '%s\n' 'devshell-provides' 'bench --smoke')"
  assert_equal "$(cat -- "${RUNS}")" "$(printf '\n--awk=bwk')"
}

@test "run-all-checks: --scope=shared with --awk is rejected" {
  # Both flags only shape the suite, which this scope never runs: a caller
  # passing one expects a suite run it would not get.
  run_gate --awk=gawk --scope=shared
  assert_rejected
}

@test "run-all-checks: --scope=shared with --report is rejected" {
  run_gate --scope=shared --report "${BATS_TEST_TMPDIR}/out"
  assert_rejected
}

@test "run-all-checks: a repeated --scope is rejected" {
  run_gate --scope=platform --scope=platform
  assert_rejected
}

@test "run-all-checks: an unknown scope is rejected" {
  run_gate --scope=all
  assert_rejected
}

@test "run-all-checks: a bare --scope= is rejected" {
  run_gate --scope=
  assert_rejected
}

@test "run-all-checks: --scope=platform combines with --awk and --report" {
  local -r out="${BATS_TEST_TMPDIR}/out"
  run_gate --scope=platform --awk=bwk --report "${out}"
  assert_success
  assert_equal "$(cat -- "${RUNS}")" "--awk=bwk --report ${out}/bwk"
}
