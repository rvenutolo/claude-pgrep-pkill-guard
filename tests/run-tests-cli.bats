# run-tests' argument handling -- --report, --coverage and --awk=bwk -- and the
# --coverage fan-out across files, graded against small fixture suites rather
# than the real one.
#
# setup sets RUN_TESTS, the path of the runner under test.

function setup() {
  load 'test_helper/common'
  RUN_TESTS="${REPO_DIR}/run-tests"
}

# @description Write a trivial always-passing bats file into the fixture dir, so
#              these cases grade run-tests' ARGUMENT HANDLING rather than the
#              real suite. Running the real suite from inside itself would be
#              slow, recursive and would double every fixture-escape check.
#              A short flag only where macOS has no long form, on purpose -- see
#              make_manifest_fixture in tests/manifest.bats.
# @arg $1 path the .bats file to write
function make_trivial_suite() {
  local -r path="$1"
  mkdir -p "${path%/*}"
  cat > "${path}" << 'BATS'
@test "trivial fixture case" {
  [[ 1 -eq 1 ]]
}
BATS
}

# @description Skip a case that drives `run-tests --awk=bwk`. That path is
#              devShell-only by construction and the ambient compat legs run
#              this suite against whatever the runner ships, so it has to be
#              probed rather than assumed. Skipping there is honest: the
#              hermetic gate leg is the one that grades the flag, and a test
#              that quietly rewrote the invocation to something ambient tools
#              accept would be grading a command run-tests never runs.
#
#              Separate things have to hold, and each of them has already
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
  if ! mktemp --directory --dry-run > /dev/null 2>&1; then
    skip 'mktemp has no --directory (BSD coreutils); --awk=bwk is graded by the hermetic gate leg'
  fi
}

# @description Skip a case that needs kcov to actually run. `--coverage` is
#              Linux-only by construction -- nixpkgs declares no darwin kcov, so
#              the devShell does not carry it on macOS -- and the ambient
#              compat legs run this suite against whatever the runner ships,
#              where kcov is absent. Skipping there is honest for the
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
  [[ -d "${out}" ]]
  [[ -n "$(find "${out}" -name '*.xml' -print -quit)" ]]
}

@test "run-tests: --report creates a directory that does not exist yet" {
  local -r suite="${BATS_TEST_TMPDIR}/suite2/ok.bats"
  local -r out="${BATS_TEST_TMPDIR}/nested/deeper/report"
  make_trivial_suite "${suite}"
  run "${RUN_TESTS}" --report "${out}" "${suite}"
  assert_success
  [[ -d "${out}" ]]
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
  [[ -z "$(find "${BATS_TEST_TMPDIR}" -name '*.xml' -print -quit)" ]]
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
  # Exactly the shape .ci/report-coverage reads: the merged report, and the HTML
  # index a person opens.
  [[ -f "${out}/kcov-merged/coverage.json" ]]
  [[ -f "${out}/index.html" ]]
}

@test "run-tests: --coverage with flags but no test file is rejected" {
  require_kcov
  # Without the check this ran nothing, merged nothing and still passed.
  run "${RUN_TESTS}" --coverage "${BATS_TEST_TMPDIR}/cov17" --filter 'nothing'
  assert_failure
  assert_output --partial '[run-tests] FATAL: --coverage found no .bats file'
}

@test "run-tests: --coverage runs every given file and prints each one's output" {
  require_kcov
  local -r dir="${BATS_TEST_TMPDIR}/suite12"
  mkdir -p "${dir}"
  printf '@test "first fixture case" {\n  [[ 1 -eq 1 ]]\n}\n' > "${dir}/first.bats"
  printf '@test "second fixture case" {\n  [[ 1 -eq 1 ]]\n}\n' > "${dir}/second.bats"
  run "${RUN_TESTS}" --coverage "${BATS_TEST_TMPDIR}/cov12" "${dir}/first.bats" "${dir}/second.bats"
  assert_success
  assert_output --partial 'ok 1 first fixture case'
  assert_output --partial 'ok 1 second fixture case'
  [[ -f "${BATS_TEST_TMPDIR}/cov12/kcov-merged/coverage.json" ]]
}

@test "run-tests: --coverage fails when any one file fails" {
  require_kcov
  local -r dir="${BATS_TEST_TMPDIR}/suite13"
  mkdir -p "${dir}"
  printf '@test "passing fixture case" {\n  [[ 1 -eq 1 ]]\n}\n' > "${dir}/pass.bats"
  printf '@test "failing fixture case" {\n  [[ 1 -eq 2 ]]\n}\n' > "${dir}/fail.bats"
  run "${RUN_TESTS}" --coverage "${BATS_TEST_TMPDIR}/cov13" "${dir}/pass.bats" "${dir}/fail.bats"
  assert_failure
  # The failing file's report and the passing file's both reach the reader.
  assert_output --partial 'not ok 1 failing fixture case'
  assert_output --partial 'ok 1 passing fixture case'
}

@test "run-tests: --coverage splits a classify.bats into slices that cover the table" {
  require_kcov
  # A stand-in classify.bats that only reports the slice it was handed, so the
  # case grades how run-tests divides the work and not the real table's runtime.
  local -r dir="${BATS_TEST_TMPDIR}/suite14"
  mkdir -p "${dir}"
  cat > "${dir}/classify.bats" << 'BATS'
@test "slice probe" {
  printf 'SLICE=%s\n' "${CLASSIFY_SLICE:-unset}" >&3
}
BATS
  run "${RUN_TESTS}" --coverage "${BATS_TEST_TMPDIR}/cov14" "${dir}/classify.bats"
  assert_success
  refute_output --partial 'SLICE=unset'
  local -a slices=()
  mapfile -t slices < <(grep --only-matching 'SLICE=[0-9]*/[0-9]*' <<< "${output}" | sort --unique)
  # Every index from 0 to count-1, all naming the same count.
  local -r count="${slices[0]#*/}"
  [[ "${#slices[@]}" -eq "${count}" ]]
  local i
  for ((i = 0; i < count; i++)); do
    assert_output --partial "SLICE=${i}/${count}"
  done
}

@test "run-tests: --coverage leaves no per-file kcov output behind" {
  require_kcov
  # Each file runs under its own kcov, whose output lives in a temporary
  # directory until the merge. Point TMPDIR at a fixture dir and a leak becomes
  # visible as a coverage.json anywhere beneath it; DIR itself carries only the
  # merged report, not one per file.
  local -r suite="${BATS_TEST_TMPDIR}/suite15/ok.bats"
  local -r tmp="${BATS_TEST_TMPDIR}/tmpdir-coverage"
  local -r out="${BATS_TEST_TMPDIR}/cov15"
  make_trivial_suite "${suite}"
  mkdir -p "${tmp}"
  TMPDIR="${tmp}" run "${RUN_TESTS}" --coverage "${out}" "${suite}"
  assert_success
  [[ -z "$(find "${tmp}" -name 'coverage.json' -print -quit)" ]]
  [[ -z "$(find "${out}" -name 'coverage.json' -not -path "${out}/kcov-merged/*" -print -quit)" ]]
}

@test "run-tests: --coverage creates a directory that does not exist yet" {
  require_kcov
  local -r suite="${BATS_TEST_TMPDIR}/suite6/ok.bats"
  local -r out="${BATS_TEST_TMPDIR}/nested2/deeper/cov"
  make_trivial_suite "${suite}"
  run "${RUN_TESTS}" --coverage "${out}" "${suite}"
  assert_success
  [[ -d "${out}" ]]
}

@test "run-tests: --coverage and --report compose in either order" {
  require_kcov
  local -r suite="${BATS_TEST_TMPDIR}/suite7/ok.bats"
  make_trivial_suite "${suite}"
  run "${RUN_TESTS}" --coverage "${BATS_TEST_TMPDIR}/c1" --report "${BATS_TEST_TMPDIR}/r3" "${suite}"
  assert_success
  [[ -n "$(find "${BATS_TEST_TMPDIR}/r3" -name '*.xml' -print -quit)" ]]
  run "${RUN_TESTS}" --report "${BATS_TEST_TMPDIR}/r4" --coverage "${BATS_TEST_TMPDIR}/c2" "${suite}"
  assert_success
  [[ -n "$(find "${BATS_TEST_TMPDIR}/r4" -name '*.xml' -print -quit)" ]]
}

@test "run-tests: --coverage with --report writes a JUnit file per test file" {
  require_kcov
  # Each file runs as its own bats, so each needs its own report; a shared
  # directory would leave only the last one to finish.
  local -r dir="${BATS_TEST_TMPDIR}/suite16"
  mkdir -p "${dir}"
  printf '@test "first fixture case" {\n  [[ 1 -eq 1 ]]\n}\n' > "${dir}/first.bats"
  printf '@test "second fixture case" {\n  [[ 1 -eq 1 ]]\n}\n' > "${dir}/second.bats"
  run "${RUN_TESTS}" --coverage "${BATS_TEST_TMPDIR}/c16" --report "${BATS_TEST_TMPDIR}/r16" \
    "${dir}/first.bats" "${dir}/second.bats"
  assert_success
  run grep --recursive --files-with-matches --include='*.xml' 'fixture case' "${BATS_TEST_TMPDIR}/r16"
  assert_success
  assert_equal "${#lines[@]}" 2
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
  mkdir -p "${suite%/*}"
  cat > "${suite}" << 'BATS'
@test "COVERAGE is unset" {
  [[ -z "${COVERAGE:-}" ]]
}
BATS
  run env -u COVERAGE "${RUN_TESTS}" "${suite}"
  assert_success
}

@test "run-tests: --awk=bwk removes its shim directory on exit" {
  require_bwk_awk
  # The shim is a mktemp directory holding a single `awk -> nawk` symlink, made
  # under TMPDIR. Point TMPDIR at a fixture dir and the leak becomes visible:
  # after the run, nothing named `awk` should survive anywhere beneath it.
  #
  # Asserting on the symlink rather than on "the directory is empty" is what
  # keeps this case stable: the inner bats makes and removes temp dirs of its
  # own under the same TMPDIR, and grading their absence would grade bats.
  local -r suite="${BATS_TEST_TMPDIR}/suite9/ok.bats"
  local -r tmp="${BATS_TEST_TMPDIR}/tmpdir"
  make_trivial_suite "${suite}"
  mkdir -p "${tmp}"
  TMPDIR="${tmp}" run "${RUN_TESTS}" --awk=bwk "${suite}"
  assert_success
  [[ -z "$(find "${tmp}" -name 'awk' -print -quit)" ]]
}

@test "run-tests: --awk=bwk removes its shim directory when TMPDIR holds a quote" {
  require_bwk_awk
  # Same leak check as the case above, with an apostrophe in TMPDIR. A single
  # quote in the shim path must not keep the EXIT trap from removing it.
  local -r suite="${BATS_TEST_TMPDIR}/suite10/ok.bats"
  local -r tmp="${BATS_TEST_TMPDIR}/it's tmpdir"
  make_trivial_suite "${suite}"
  mkdir -p "${tmp}"
  TMPDIR="${tmp}" run "${RUN_TESTS}" --awk=bwk "${suite}"
  assert_success
  [[ -z "$(find "${tmp}" -name 'awk' -print -quit)" ]]
}

@test "run-tests: a repeated --awk=bwk leaves no shim directory behind" {
  require_bwk_awk
  # Same leak check again, with the flag given more than once: however many
  # times it is given, no shim directory survives the run.
  local -r suite="${BATS_TEST_TMPDIR}/suite11/ok.bats"
  local -r tmp="${BATS_TEST_TMPDIR}/tmpdir-repeated"
  make_trivial_suite "${suite}"
  mkdir -p "${tmp}"
  TMPDIR="${tmp}" run "${RUN_TESTS}" --awk=bwk --awk=bwk "${suite}"
  assert_success
  [[ -z "$(find "${tmp}" -name 'awk' -print -quit)" ]]
}
