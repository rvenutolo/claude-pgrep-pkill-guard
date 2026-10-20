# run-tests' argument handling -- --report, --jobs, --coverage and --awk=bwk --
# and its fan-out of files across concurrent workers, with and without
# --coverage, graded against small fixture suites rather than the real one.
#
# `run --separate-stderr` is a bats 1.5.0 flag: the --jobs rejections assert on
# run-tests' own stderr.
#
# setup sets RUN_TESTS, the path of the runner under test.

bats_require_minimum_version 1.5.0

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

@test "run-tests: --coverage splits a classify.bats the same way on any CPU count" {
  require_kcov
  # The split decides which lines kcov's apostrophe swallow windows hide (#128),
  # so a split that followed the worker count would give each machine its own
  # figure. --jobs stands in for a smaller or larger machine here.
  local -r dir="${BATS_TEST_TMPDIR}/suite18"
  mkdir -p "${dir}"
  cat > "${dir}/classify.bats" << 'BATS'
@test "slice probe" {
  printf 'SLICE=%s\n' "${CLASSIFY_SLICE:-unset}" >&3
}
BATS
  local one three
  run "${RUN_TESTS}" --jobs 1 --coverage "${BATS_TEST_TMPDIR}/cov18a" "${dir}/classify.bats"
  assert_success
  one="$(grep --only-matching 'SLICE=[0-9]*/[0-9]*' <<< "${output}" | sort)"
  run "${RUN_TESTS}" --jobs 3 --coverage "${BATS_TEST_TMPDIR}/cov18b" "${dir}/classify.bats"
  assert_success
  three="$(grep --only-matching 'SLICE=[0-9]*/[0-9]*' <<< "${output}" | sort)"
  [[ -n "${one}" ]]
  assert_equal "${one}" "${three}"
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

@test "run-tests: runs every given file and prints each one's output" {
  local -r dir="${BATS_TEST_TMPDIR}/suite19"
  mkdir -p "${dir}"
  printf '@test "first fixture case" {\n  [[ 1 -eq 1 ]]\n}\n' > "${dir}/first.bats"
  printf '@test "second fixture case" {\n  [[ 1 -eq 1 ]]\n}\n' > "${dir}/second.bats"
  run "${RUN_TESTS}" "${dir}"
  assert_success
  assert_output --partial 'first fixture case'
  assert_output --partial 'second fixture case'
}

@test "run-tests: fails when any one file fails" {
  local -r dir="${BATS_TEST_TMPDIR}/suite20"
  mkdir -p "${dir}"
  printf '@test "passing fixture case" {\n  [[ 1 -eq 1 ]]\n}\n' > "${dir}/pass.bats"
  printf '@test "failing fixture case" {\n  [[ 1 -eq 2 ]]\n}\n' > "${dir}/fail.bats"
  run "${RUN_TESTS}" "${dir}/pass.bats" "${dir}/fail.bats"
  assert_failure
  assert_output --partial 'not ok'
}

@test "run-tests: prints each file's output whole, in queue order" {
  # Each test sleeps so both files are mid-run at once under --jobs 2; output
  # written straight to the terminal would then interleave their lines.
  local -r dir="${BATS_TEST_TMPDIR}/suite21"
  mkdir -p "${dir}"
  local file i
  for file in 'alpha' 'beta'; do
    for i in 1 2 3; do
      printf '@test "%s case %s" {\n  sleep 0.2\n}\n' "${file}" "${i}"
    done > "${dir}/${file}.bats"
  done
  run "${RUN_TESTS}" --jobs 2 "${dir}/alpha.bats" "${dir}/beta.bats"
  assert_success
  local -a alpha_lines=() beta_lines=()
  for i in "${!lines[@]}"; do
    case "${lines[i]}" in
      *'alpha case'*) alpha_lines+=("${i}") ;;
      *'beta case'*) beta_lines+=("${i}") ;;
      *) ;;
    esac
  done
  assert_equal "${#alpha_lines[@]}" 3
  assert_equal "${#beta_lines[@]}" 3
  # Either file may be queued first; what matters is that one file's lines all
  # come before the other's.
  local -r alpha_first="${alpha_lines[0]}" alpha_last="${alpha_lines[2]}"
  local -r beta_first="${beta_lines[0]}" beta_last="${beta_lines[2]}"
  [[ "${alpha_last}" -lt "${beta_first}" || "${beta_last}" -lt "${alpha_first}" ]]
}

# @description Write a .bats file whose one test marks itself started, then waits
#              up to 10 s for a sibling file's test to do the same. Two such
#              files pass together only when both run at once.
# @arg $1 dir the directory both files live in
# @arg $2 own this file's name, without .bats
# @arg $3 other the sibling's name, without .bats
function make_rendezvous_file() {
  local -r dir="$1" own="$2" other="$3"
  cat > "${dir}/${own}.bats" << BATS
@test "${own} meets ${other}" {
  touch "\${BATS_TEST_FILENAME%/*}/${own}.started"
  local i
  for ((i = 0; i < 100; i++)); do
    if [[ -f "\${BATS_TEST_FILENAME%/*}/${other}.started" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}
BATS
}

@test "run-tests: --jobs 2 runs two files at once" {
  local -r dir="${BATS_TEST_TMPDIR}/suite22"
  mkdir -p "${dir}"
  make_rendezvous_file "${dir}" 'one' 'two'
  make_rendezvous_file "${dir}" 'two' 'one'
  run "${RUN_TESTS}" --jobs 2 "${dir}/one.bats" "${dir}/two.bats"
  assert_success
}

@test "run-tests: --jobs 1 runs one file at a time" {
  # mkdir is atomic: a second file taking the lock while the first holds it
  # fails its test.
  local -r dir="${BATS_TEST_TMPDIR}/suite23"
  mkdir -p "${dir}"
  local file
  for file in 'one' 'two'; do
    cat > "${dir}/${file}.bats" << 'BATS'
@test "holds the lock alone" {
  mkdir "${BATS_TEST_FILENAME%/*}/lock"
  sleep 0.3
  rmdir "${BATS_TEST_FILENAME%/*}/lock"
}
BATS
  done
  run "${RUN_TESTS}" --jobs 1 "${dir}/one.bats" "${dir}/two.bats"
  assert_success
}

@test "run-tests: --jobs with no value is rejected" {
  # The `[run-tests] FATAL:` prefix pins who rejected it: bats has a --jobs of
  # its own and would fail too, with the flag name in its own error.
  run --separate-stderr "${RUN_TESTS}" --jobs
  assert_failure 1
  [[ "${stderr}" == *'[run-tests] FATAL:'*'--jobs'* ]]
}

@test "run-tests: --jobs 0 is rejected" {
  local -r suite="${BATS_TEST_TMPDIR}/suite24/ok.bats"
  make_trivial_suite "${suite}"
  run --separate-stderr "${RUN_TESTS}" --jobs 0 "${suite}"
  assert_failure 1
  [[ "${stderr}" == *'[run-tests] FATAL:'*'--jobs'* ]]
}

@test "run-tests: --jobs that is not a number is rejected" {
  local -r suite="${BATS_TEST_TMPDIR}/suite25/ok.bats"
  make_trivial_suite "${suite}"
  run --separate-stderr "${RUN_TESTS}" --jobs 'many' "${suite}"
  assert_failure 1
  [[ "${stderr}" == *'[run-tests] FATAL:'*'--jobs'* ]]
}

@test "run-tests: --report writes a JUnit file per test file" {
  # Each file runs as its own bats, so each needs its own report; a shared
  # directory would leave only the last one to finish.
  local -r dir="${BATS_TEST_TMPDIR}/suite26"
  mkdir -p "${dir}"
  printf '@test "first fixture case" {\n  [[ 1 -eq 1 ]]\n}\n' > "${dir}/first.bats"
  printf '@test "second fixture case" {\n  [[ 1 -eq 1 ]]\n}\n' > "${dir}/second.bats"
  run "${RUN_TESTS}" --report "${BATS_TEST_TMPDIR}/r26" "${dir}/first.bats" "${dir}/second.bats"
  assert_success
  local -a reports=()
  mapfile -t reports < <(find "${BATS_TEST_TMPDIR}/r26" -name '*.xml' -type f)
  assert_equal "${#reports[@]}" 2
}

@test "run-tests: forwards bats arguments to every file" {
  local -r dir="${BATS_TEST_TMPDIR}/suite27"
  mkdir -p "${dir}"
  local file
  for file in 'first' 'second'; do
    printf '@test "keep case" {\n  [[ 1 -eq 1 ]]\n}\n@test "drop case" {\n  [[ 1 -eq 1 ]]\n}\n' \
      > "${dir}/${file}.bats"
  done
  run "${RUN_TESTS}" --filter 'keep' "${dir}/first.bats" "${dir}/second.bats"
  assert_success
  local -a kept=()
  mapfile -t kept < <(grep --fixed-strings 'keep case' <<< "${output}")
  assert_equal "${#kept[@]}" 2
  refute_output --partial 'drop case'
}

@test "run-tests: runs with one worker when the CPU count is unknown" {
  local -r dir="${BATS_TEST_TMPDIR}/suite28"
  local -r stub="${BATS_TEST_TMPDIR}/stub28"
  mkdir -p "${dir}" "${stub}"
  printf '@test "first fixture case" {\n  [[ 1 -eq 1 ]]\n}\n' > "${dir}/first.bats"
  printf '@test "second fixture case" {\n  [[ 1 -eq 1 ]]\n}\n' > "${dir}/second.bats"
  local tool
  for tool in 'nproc' 'getconf' 'sysctl'; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub}/${tool}"
    chmod +x "${stub}/${tool}"
  done
  # PATH carries the failing probes first, so run-tests cannot learn the CPU
  # count from any of them.
  PATH="${stub}:${PATH}" run "${RUN_TESTS}" "${dir}/first.bats" "${dir}/second.bats"
  assert_success
  # The worker count run-tests logs, not just a pass: an empty or garbage count
  # would also run both files, and only this line says it fell back to one.
  assert_output --partial '[run-tests] running 2 files, 1 at a time'
  assert_output --partial 'first fixture case'
  assert_output --partial 'second fixture case'
}

@test "run-tests: TERM stops every worker" {
  # The fixture's test runs a loop that records its own process id and its
  # parent's, the fixture file's bats, then polls for 30 s; `kill -0` on those
  # ids shows whether either outlived run-tests. Not ps: the devShell carries
  # none. The loop gives up on its own, so a failing case leaks nothing for
  # long.
  local -r dir="${BATS_TEST_TMPDIR}/suite29"
  mkdir -p "${dir}"
  cat > "${dir}/sleeper" << 'SH'
#!/usr/bin/env bash
printf '%s\n%s\n' "$$" "${PPID}" > "${0%/*}/running.tmp"
mv -f -- "${0%/*}/running.tmp" "${0%/*}/running"
for ((i = 0; i < 300; i++)); do
  sleep 0.1
done
SH
  chmod +x "${dir}/sleeper"
  cat > "${dir}/slow.bats" << 'BATS'
@test "slow fixture case" {
  "${BATS_TEST_FILENAME%/*}/sleeper"
}
BATS
  # fd 3 closed: bats waits on it, and a background job holding it open hangs
  # the run.
  "${RUN_TESTS}" "${dir}/slow.bats" > "${dir}/run.log" 2>&1 3>&- &
  local -r pid="$!"
  local i
  for ((i = 0; i < 100; i++)); do
    if [[ -f "${dir}/running" ]]; then
      break
    fi
    sleep 0.1
  done
  local -a watched=()
  mapfile -t watched < "${dir}/running"
  assert_equal "${#watched[@]}" 2
  kill -TERM "${pid}"
  local watched_pid survivors=''
  for ((i = 0; i < 50; i++)); do
    survivors=''
    for watched_pid in "${watched[@]}"; do
      if kill -0 "${watched_pid}" 2> /dev/null; then
        survivors+="${watched_pid} "
      fi
    done
    if [[ -z "${survivors}" ]]; then
      break
    fi
    sleep 0.1
  done
  wait "${pid}" || true # run-tests' own status is not the subject
  assert_equal "${survivors}" ''
}
