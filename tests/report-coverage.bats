# .ci/report-coverage, against fixture kcov output directories.
#
# setup sets REPORTER, the script under test.

function setup() {
  load 'test_helper/common'
  REPORTER="${REPO_DIR}/.ci/report-coverage"
}

# A files[] array in which every required hooks/ file -- the entry script, the
# loader, and every part under hooks/lib/ -- is present and non-empty, i.e.
# the shape a healthy kcov run produces. The absolute paths are deliberately
# from a machine that is not this one: kcov records whatever path existed where
# the report was produced -- a Nix build sandbox, a CI runner checkout, someone
# else's home directory -- so a fixture carrying THIS repo's path would let a
# reporter that matched on the absolute path pass, and that reporter would go red
# on every real report. Every case that wants a defective files[] passes its
# own array as make_report $3.
HEALTHY_FILES='[
  {"covered_lines": 143, "file": "/build/kcov-src-9f2c/hooks/pgrep-pkill-guard.sh",
   "percent_covered": "95.33", "total_lines": 150},
  {"covered_lines": 60, "file": "/build/kcov-src-9f2c/hooks/pgrep-pkill-guard-body.sh",
   "percent_covered": "75.00", "total_lines": 80},
  {"covered_lines": 220, "file": "/build/kcov-src-9f2c/hooks/lib/tokens.sh",
   "percent_covered": "75.09", "total_lines": 293},
  {"covered_lines": 150, "file": "/build/kcov-src-9f2c/hooks/lib/scanner.sh",
   "percent_covered": "74.63", "total_lines": 201},
  {"covered_lines": 168, "file": "/build/kcov-src-9f2c/hooks/lib/loops.sh",
   "percent_covered": "75.00", "total_lines": 224},
  {"covered_lines": 125, "file": "/build/kcov-src-9f2c/hooks/lib/messages.sh",
   "percent_covered": "74.85", "total_lines": 167},
  {"covered_lines": 262, "file": "/build/kcov-src-9f2c/hooks/lib/consumption.sh",
   "percent_covered": "75.07", "total_lines": 349},
  {"covered_lines": 326, "file": "/build/kcov-src-9f2c/hooks/lib/wrappers.sh",
   "percent_covered": "75.11", "total_lines": 434},
  {"covered_lines": 122, "file": "/build/kcov-src-9f2c/hooks/lib/repeat.sh",
   "percent_covered": "75.30", "total_lines": 162},
  {"covered_lines": 267, "file": "/build/kcov-src-9f2c/hooks/lib/classify.sh",
   "percent_covered": "75.00", "total_lines": 356},
  {"covered_lines": 101, "file": "/build/kcov-src-9f2c/hooks/lib/human.sh",
   "percent_covered": "74.81", "total_lines": 135}
]'
readonly HEALTHY_FILES

# @description Build a fabricated kcov output directory. Fabricated rather than
#              produced by a real kcov run for the usual reason: kcov is
#              Linux-only, a real run costs minutes, and neither of those is
#              what these cases are grading. What they grade is the LOCATION
#              rule -- the merged report `run-tests --coverage` writes with
#              `kcov --merge`, at kcov-merged/coverage.json, and nothing else --
#              and the INTEGRITY rule: every required hooks/ file
#              present in files[] with a non-zero covered-line count. Both are
#              pure JSON-and-filesystem shape and need no kcov at all. A short
#              flag only where macOS has no long form, on purpose: a compat CI
#              leg runs this suite against macOS BSD coreutils, whose mkdir has
#              no --parents.
#
#              The healthy fixture carries a files[] array because the
#              INTEGRITY rule requires one: a report with no files[] is
#              exactly the broken report the reporter must refuse, so a
#              fixture meant to pass carries what a healthy report carries.
# @arg $1 root directory to populate
# @arg $2 percent the percent_covered value to record, or the empty string to
#         write a report with no such field
# @arg $3 files a JSON array to use as files[]; defaults to ${HEALTHY_FILES}.
#         Pass a doctored array to plant the defect the integrity rule catches.
function make_report() {
  local -r root="$1" percent="$2" files="${3:-${HEALTHY_FILES}}"
  mkdir -p "${root}/kcov-merged"
  if [[ -n "${percent}" ]]; then
    printf '{"percent_covered": "%s", "covered_lines": 387, "total_lines": 514, "files": %s}\n' \
      "${percent}" "${files}" > "${root}/kcov-merged/coverage.json"
  else
    printf '{"covered_lines": 387, "total_lines": 514, "files": %s}\n' \
      "${files}" > "${root}/kcov-merged/coverage.json"
  fi
}

# @description Plant a single-run kcov report: a `<binary>.<hash>` directory
#              holding a coverage.json, which is the layout one kcov process
#              writes before any merge. A short flag only where macOS has no
#              long form, for the reason make_report gives.
# @arg $1 root directory to plant it in
# @arg $2 percent the percent_covered value to record
function make_single_run_report() {
  local -r root="$1" percent="$2"
  mkdir -p "${root}/bats.deadbeefdeadbeef"
  printf '{"percent_covered": "%s", "files": %s}\n' "${percent}" "${HEALTHY_FILES}" \
    > "${root}/bats.deadbeefdeadbeef/coverage.json"
}

@test "report-coverage: prints the percentage from the merged report" {
  make_report "${BATS_TEST_TMPDIR}/cov" '76.42'
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_success
  assert_output '76.42'
}

@test "report-coverage: a single-run report beside the merged one is ignored" {
  # A directory reused across runs can hold an older single-run report, and a
  # part that escaped its own directory would look the same. Only the merged
  # report describes the whole suite.
  make_report "${BATS_TEST_TMPDIR}/cov" '76.42'
  make_single_run_report "${BATS_TEST_TMPDIR}/cov" '12.34'
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_success
  assert_output '76.42'
}

@test "report-coverage: a single-run report with no merged one fails loudly" {
  # The layout of a lone kcov run, whose own kcov-merged/ is empty. Its number
  # describes one process's share of the suite at best, so it is refused rather
  # than reported.
  make_single_run_report "${BATS_TEST_TMPDIR}/cov" '12.34'
  mkdir -p "${BATS_TEST_TMPDIR}/cov/kcov-merged"
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_failure
  assert_output --partial "no coverage.json at ${BATS_TEST_TMPDIR}/cov/kcov-merged"
  refute_output --partial '12.34'
}

@test "report-coverage: no report at all fails loudly" {
  mkdir -p "${BATS_TEST_TMPDIR}/empty"
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/empty"
  assert_failure
  assert_output --partial 'no coverage.json'
}

@test "report-coverage: a report with no percent_covered fails" {
  make_report "${BATS_TEST_TMPDIR}/cov" ''
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_failure
  assert_output --partial 'no percent_covered'
}

@test "report-coverage: a missing directory fails" {
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/nope"
  assert_failure
  assert_output --partial 'not a directory'
}

@test "report-coverage: no argument is a usage error" {
  run "${REPORTER}"
  assert_failure
  assert_output --partial 'usage:'
}

@test "report-coverage: the job summary carries the number and its caveat" {
  make_report "${BATS_TEST_TMPDIR}/cov" '76.42'
  local -r summary="${BATS_TEST_TMPDIR}/summary.md"
  GITHUB_STEP_SUMMARY="${summary}" run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_success
  run cat "${summary}"
  assert_output --partial '76.42%'
  # The caveat travels with the number or the number is misread as branch reach.
  # It names the shape kcov miscounts: the continuation lines of a multi-line
  # quoted string are coverable and never hit. kcov does not count heredoc body
  # lines at all, so a caveat blaming heredocs would explain nothing.
  assert_output --partial 'multi-line quoted strings'
  refute_output --partial 'heredoc'
}

@test "report-coverage: no job summary is written when the variable is unset" {
  make_report "${BATS_TEST_TMPDIR}/cov" '76.42'
  run env -u GITHUB_STEP_SUMMARY "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_success
  assert_output '76.42'
}

# --- Report integrity --------------------------------------------------------
#
# kcov 43 desynchronises on a traced command carrying an odd number of unescaped
# apostrophes and drops the whole of hooks/pgrep-pkill-guard-body.sh from the
# report rather than undercounting it. What survives is a well-formed JSON with
# an arithmetically correct percentage over the files that remain, so nothing
# about the report's SHAPE says it is wrong, and helpers the suite provably
# reaches read as never entered.
#
# These cases grade the reporter, not kcov. Reproducing the real loss would mean
# a two-and-a-half-minute Linux-only kcov run to observe a bug in a third-party
# tool; fabricating its output takes milliseconds and pins the only thing this
# repo controls, which is whether the reporter notices.

@test "report-coverage: a report missing the body file fails rather than printing" {
  # The proved failure mode: the entry script survives and the body file is gone.
  make_report "${BATS_TEST_TMPDIR}/cov" '76.42' '[
    {"covered_lines": 143, "file": "/build/kcov-src-9f2c/hooks/pgrep-pkill-guard.sh",
     "percent_covered": "95.33", "total_lines": 150}
  ]'
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_failure
  # Naming the file is the whole point of the message: "the report is incomplete"
  # sends the next reader back to first principles.
  assert_output --partial 'pgrep-pkill-guard-body.sh'
  # The trigger travels with the failure so nobody re-derives it.
  assert_output --partial 'odd number of unescaped apostrophes'
  # And the number must not escape anyway. A gate that goes red while still
  # printing the figure feeds the figure to whatever reads stdout.
  refute_output --partial '76.42'
}

@test "report-coverage: a report missing the entry script fails too" {
  # The same loop grades every required file; grading only the body file would
  # let a typo in the entry script's name sit unnoticed.
  make_report "${BATS_TEST_TMPDIR}/cov" '76.42' '[
    {"covered_lines": 387, "file": "/build/kcov-src-9f2c/hooks/pgrep-pkill-guard-body.sh",
     "percent_covered": "75.29", "total_lines": 514}
  ]'
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_failure
  assert_output --partial 'pgrep-pkill-guard.sh'
  assert_output --partial 'odd number of unescaped apostrophes'
}

@test "report-coverage: a body file with zero covered lines fails" {
  # The other half of the loss: the entry stays in files[] but carries nothing.
  # Distinct from absence because a present-but-empty entry still contributes a
  # total_lines to the denominator, which drags the headline percentage down and
  # reads as "poorly tested code" rather than "failed measurement".
  make_report "${BATS_TEST_TMPDIR}/cov" '27.83' '[
    {"covered_lines": 143, "file": "/build/kcov-src-9f2c/hooks/pgrep-pkill-guard.sh",
     "percent_covered": "95.33", "total_lines": 150},
    {"covered_lines": 0, "file": "/build/kcov-src-9f2c/hooks/pgrep-pkill-guard-body.sh",
     "percent_covered": "0.00", "total_lines": 514}
  ]'
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_failure
  assert_output --partial 'zero covered lines'
  assert_output --partial 'pgrep-pkill-guard-body.sh'
  assert_output --partial 'odd number of unescaped apostrophes'
  refute_output --partial '27.83'
}

@test "report-coverage: a healthy report with all required files still prints the number" {
  # The counterweight to the failing cases above: the integrity rule must reject a
  # lossy report without rejecting a good one. Passed explicitly rather than
  # relying on make_report's default so this case keeps grading the healthy shape
  # even if that default is ever narrowed.
  make_report "${BATS_TEST_TMPDIR}/cov" '76.42' "${HEALTHY_FILES}"
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_success
  assert_output '76.42'
}

@test "report-coverage: the integrity check matches on basename, not on this repo's path" {
  # Every fixture above uses a foreign absolute path, so this case exists to say
  # out loud what they depend on: kcov records the path of the machine that
  # produced the report. A reporter that matched "${REPO_DIR}/hooks/..." would
  # pass its own test suite and go red on every report produced anywhere else --
  # the Nix build sandbox and the CI runner included.
  make_report "${BATS_TEST_TMPDIR}/cov" '76.42' '[
    {"covered_lines": 143, "file": "/nowhere/at/all/hooks/pgrep-pkill-guard.sh",
     "percent_covered": "95.33", "total_lines": 150},
    {"covered_lines": 60, "file": "/nowhere/at/all/hooks/pgrep-pkill-guard-body.sh",
     "percent_covered": "75.00", "total_lines": 80},
    {"covered_lines": 220, "file": "/nowhere/at/all/hooks/lib/tokens.sh",
     "percent_covered": "75.09", "total_lines": 293},
    {"covered_lines": 150, "file": "/nowhere/at/all/hooks/lib/scanner.sh",
     "percent_covered": "74.63", "total_lines": 201},
    {"covered_lines": 168, "file": "/nowhere/at/all/hooks/lib/loops.sh",
     "percent_covered": "75.00", "total_lines": 224},
    {"covered_lines": 125, "file": "/nowhere/at/all/hooks/lib/messages.sh",
     "percent_covered": "74.85", "total_lines": 167},
    {"covered_lines": 262, "file": "/nowhere/at/all/hooks/lib/consumption.sh",
     "percent_covered": "75.07", "total_lines": 349},
    {"covered_lines": 326, "file": "/nowhere/at/all/hooks/lib/wrappers.sh",
     "percent_covered": "75.11", "total_lines": 434},
    {"covered_lines": 122, "file": "/nowhere/at/all/hooks/lib/repeat.sh",
     "percent_covered": "75.30", "total_lines": 162},
    {"covered_lines": 267, "file": "/nowhere/at/all/hooks/lib/classify.sh",
     "percent_covered": "75.00", "total_lines": 356},
    {"covered_lines": 101, "file": "/nowhere/at/all/hooks/lib/human.sh",
     "percent_covered": "74.81", "total_lines": 135}
  ]'
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_success
  assert_output '76.42'
}
