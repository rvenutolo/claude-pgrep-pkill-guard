setup() {
  load 'test_helper/common'
  REPORTER="${REPO_DIR}/.ci/report-coverage"
}

# @description Build a fabricated kcov output directory. Fabricated rather than
#              produced by a real kcov run for the usual reason: kcov is
#              Linux-only, a real run costs two and a half minutes, and neither
#              of those is what these cases are grading. What they grade is the
#              LOCATION rule -- exactly one coverage.json, one level down, with
#              kcov's empty kcov-merged/ excluded -- which is pure filesystem
#              shape and needs no kcov at all. POSIX short flags on purpose: the
#              compat CI legs run this suite against macOS BSD coreutils, whose
#              mkdir has no --parents.
# @arg $1 root directory to populate
# @arg $2 percent the percent_covered value to record, or the empty string to
#         write a report with no such field
function make_report() {
  local -r root="$1" percent="${2:-}"
  # The hashed directory name is the point: kcov derives it per run, which is
  # why the reporter globs instead of hardcoding a path.
  mkdir -p "${root}/bats.deadbeefdeadbeef"
  # kcov creates this alongside the real report and leaves it EMPTY for a
  # single-binary run. Every fixture has it, because a reporter that reached for
  # it would find nothing and, written the obvious way, would say nothing.
  mkdir -p "${root}/kcov-merged"
  if [[ -n "${percent}" ]]; then
    printf '{"percent_covered": "%s", "covered_lines": 387, "total_lines": 514}\n' \
      "${percent}" > "${root}/bats.deadbeefdeadbeef/coverage.json"
  else
    printf '{"covered_lines": 387, "total_lines": 514}\n' \
      > "${root}/bats.deadbeefdeadbeef/coverage.json"
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
