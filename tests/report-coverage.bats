setup() {
  load 'test_helper/common'
  REPORTER="${REPO_DIR}/.ci/report-coverage"
}

# A files[] array in which both hooks/ files are present and non-empty, i.e. the
# shape a healthy kcov run produces. The absolute paths are deliberately from a
# machine that is not this one: kcov records whatever path existed where the
# report was produced -- a Nix build sandbox, a CI runner checkout, someone
# else's home directory -- so a fixture carrying THIS repo's path would let a
# reporter that matched on the absolute path pass, and that reporter would go red
# on every real report. Every case that wants a broken report overrides this.
HEALTHY_FILES='[
  {"covered_lines": 143, "file": "/build/kcov-src-9f2c/hooks/pgrep-pkill-guard.sh",
   "percent_covered": "95.33", "total_lines": 150},
  {"covered_lines": 387, "file": "/build/kcov-src-9f2c/hooks/pgrep-pkill-guard-body.sh",
   "percent_covered": "75.29", "total_lines": 514}
]'

# @description Build a fabricated kcov output directory. Fabricated rather than
#              produced by a real kcov run for the usual reason: kcov is
#              Linux-only, a real run costs two and a half minutes, and neither
#              of those is what these cases are grading. What they grade is the
#              LOCATION rule -- exactly one coverage.json, one level down, with
#              kcov's empty kcov-merged/ excluded -- and, since #128, the
#              INTEGRITY rule: both hooks/ files present in files[] with a
#              non-zero covered-line count. Both are pure JSON-and-filesystem
#              shape and need no kcov at all. POSIX short flags on purpose: the
#              compat CI legs run this suite against macOS BSD coreutils, whose
#              mkdir has no --parents.
#
#              The fixture grew a files[] array when the integrity rule landed.
#              It predates that rule and used to omit files[] entirely, which now
#              describes exactly the broken report the reporter must refuse. The
#              fix is for the healthy fixture to carry what a healthy report
#              carries, NOT for the reporter to tolerate a report with no files[]
#              -- a report that has lost every file is the loudest instance of
#              the loss #128 is about, and grandfathering it in to keep an old
#              fixture green would gut the check on its first day.
# @arg $1 root directory to populate
# @arg $2 percent the percent_covered value to record, or the empty string to
#         write a report with no such field
# @arg $3 files a JSON array to use as files[]; defaults to ${HEALTHY_FILES}.
#         Pass a doctored array to plant the defect the integrity rule catches.
function make_report() {
  local -r root="$1" percent="${2:-}" files="${3:-${HEALTHY_FILES}}"
  # The hashed directory name is the point: kcov derives it per run, which is
  # why the reporter globs instead of hardcoding a path.
  mkdir -p "${root}/bats.deadbeefdeadbeef"
  # kcov creates this alongside the real report and leaves it EMPTY for a
  # single-binary run. Every fixture has it, because a reporter that reached for
  # it would find nothing and, written the obvious way, would say nothing.
  mkdir -p "${root}/kcov-merged"
  if [[ -n "${percent}" ]]; then
    printf '{"percent_covered": "%s", "covered_lines": 387, "total_lines": 514, "files": %s}\n' \
      "${percent}" "${files}" > "${root}/bats.deadbeefdeadbeef/coverage.json"
  else
    printf '{"covered_lines": 387, "total_lines": 514, "files": %s}\n' \
      "${files}" > "${root}/bats.deadbeefdeadbeef/coverage.json"
  fi
}

@test "report-coverage: prints the percentage from the one report it finds" {
  make_report "${BATS_TEST_TMPDIR}/cov" '76.42'
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_success
  assert_output '76.42'
}

@test "report-coverage: an empty kcov-merged is not a second match" {
  make_report "${BATS_TEST_TMPDIR}/cov" '76.42'
  # Belt and braces: even a POPULATED kcov-merged must be pruned, because a
  # future kcov that fills it in would otherwise turn every run into the
  # two-matches failure below.
  printf '{"percent_covered": "0.00"}\n' > "${BATS_TEST_TMPDIR}/cov/kcov-merged/coverage.json"
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_success
  assert_output '76.42'
}

@test "report-coverage: no report at all fails loudly" {
  mkdir -p "${BATS_TEST_TMPDIR}/empty/kcov-merged"
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/empty"
  assert_failure
  assert_output --partial 'no coverage.json'
}

@test "report-coverage: two reports fail rather than picking one" {
  make_report "${BATS_TEST_TMPDIR}/cov" '76.42'
  mkdir -p "${BATS_TEST_TMPDIR}/cov/bats.0123456789abcdef"
  printf '{"percent_covered": "12.34"}\n' \
    > "${BATS_TEST_TMPDIR}/cov/bats.0123456789abcdef/coverage.json"
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_failure
  assert_output --partial 'exactly one'
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
  assert_output --partial 'heredoc'
}

@test "report-coverage: no job summary is written when the variable is unset" {
  make_report "${BATS_TEST_TMPDIR}/cov" '76.42'
  run env -u GITHUB_STEP_SUMMARY "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_success
  assert_output '76.42'
}

# --- Report integrity (#128) -------------------------------------------------
#
# kcov 43 desynchronises on a traced command carrying both an apostrophe and a
# newline and drops the whole of hooks/pgrep-pkill-guard-body.sh from the report
# rather than undercounting it. What survives is a well-formed JSON with an
# arithmetically correct percentage over the files that remain, so nothing about
# the report's SHAPE says it is wrong -- which is how #126 came to be filed
# against helpers the suite provably reaches.
#
# These cases grade the reporter, not kcov. Reproducing the real loss would mean
# a two-and-a-half-minute Linux-only kcov run to observe a bug in a third-party
# tool; fabricating its output takes milliseconds and pins the only thing this
# repo controls, which is whether the reporter notices.

@test "report-coverage: a report missing the body file fails rather than printing" {
  # The proved failure mode: the entry script survives, the body file is gone,
  # and every remaining number is internally consistent.
  make_report "${BATS_TEST_TMPDIR}/cov" '76.42' '[
    {"covered_lines": 143, "file": "/build/kcov-src-9f2c/hooks/pgrep-pkill-guard.sh",
     "percent_covered": "95.33", "total_lines": 150}
  ]'
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_failure
  # Naming the file is the whole point of the message: "the report is incomplete"
  # sends the next reader back to first principles.
  assert_output --partial 'pgrep-pkill-guard-body.sh'
  # The issue number travels with the failure so nobody re-derives the trigger.
  assert_output --partial '#128'
  # And the number must not escape anyway. A gate that goes red while still
  # printing the figure feeds the figure to whatever reads stdout.
  refute_output --partial '76.42'
}

@test "report-coverage: a report missing the entry script fails too" {
  # The rule is symmetric and both halves are enforced by the same loop; grading
  # only the body file would let a typo in the entry script's name sit unnoticed.
  make_report "${BATS_TEST_TMPDIR}/cov" '76.42' '[
    {"covered_lines": 387, "file": "/build/kcov-src-9f2c/hooks/pgrep-pkill-guard-body.sh",
     "percent_covered": "75.29", "total_lines": 514}
  ]'
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_failure
  assert_output --partial 'pgrep-pkill-guard.sh'
  assert_output --partial '#128'
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
  assert_output --partial '#128'
  refute_output --partial '27.83'
}

@test "report-coverage: a healthy report with both files still prints the number" {
  # The counterweight to the three cases above: the integrity rule must reject a
  # lossy report without rejecting a good one. Passed explicitly rather than
  # relying on make_report's default so this case keeps grading the healthy shape
  # even if that default is ever narrowed.
  make_report "${BATS_TEST_TMPDIR}/cov" '76.42' '[
    {"covered_lines": 143, "file": "/build/kcov-src-9f2c/hooks/pgrep-pkill-guard.sh",
     "percent_covered": "95.33", "total_lines": 150},
    {"covered_lines": 387, "file": "/build/kcov-src-9f2c/hooks/pgrep-pkill-guard-body.sh",
     "percent_covered": "75.29", "total_lines": 514}
  ]'
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
    {"covered_lines": 387, "file": "/nowhere/at/all/hooks/pgrep-pkill-guard-body.sh",
     "percent_covered": "75.29", "total_lines": 514}
  ]'
  run "${REPORTER}" "${BATS_TEST_TMPDIR}/cov"
  assert_success
  assert_output '76.42'
}
