# bench/run's cohorts: the report lists every cohort, and an `inspect` row the
# repeat rule denies is timed under `repeat` rather than `inspect`. Driven
# through the script's command line, against the real repo and against a
# fixture repo holding a copy of bench/run, the hook and a small corpus.
#
# bench/run takes GNU long options and runs only in the devShell, so this suite
# skips outside it.
#
# setup sets FIXTURE, the throwaway repo the fixture cases run bench/run in.

# shellcheck disable=SC2016 # file-wide: the backticks are markdown spans in the report
function setup() {
  load 'test_helper/common'
  FIXTURE="${BATS_TEST_TMPDIR}/repo"
  # .ci/in-devshell exports IN_DEVSHELL; the ambient compat legs do not have it.
  if [[ -z "${IN_DEVSHELL:-}" ]]; then
    skip 'not in the devShell; bench/run runs only there'
  fi
}

# @description Build a repo holding a copy of bench/run and of hooks/, with a
#              corpus of the rows given, and commit it: the report records HEAD.
#              A short flag only where macOS has no long form, on purpose: the
#              tests/ rule, though this suite skips outside the devShell.
# @arg $@ rows corpus rows, each a JSON command string, a tab, and a verdict
function make_bench_repo() {
  mkdir -p "${FIXTURE}/bench" "${FIXTURE}/tests/cases"
  git -c init.defaultBranch=main init --quiet "${FIXTURE}"
  cp -- "${REPO_DIR}/bench/run" "${FIXTURE}/bench/run"
  cp -R -- "${REPO_DIR}/hooks" "${FIXTURE}/hooks"
  printf '%s\n' "$@" > "${FIXTURE}/tests/cases/verdicts.tsv"
  git -C "${FIXTURE}" add --all
  git -C "${FIXTURE}" -c user.email='tests@example.invalid' -c user.name='Tests' \
    commit --quiet --message='seed'
}

@test "bench run: the smoke report lists the repeat cohort" {
  # bench/run finds its repo from the working directory, so the suite may be run from anywhere.
  cd "${REPO_DIR}"
  run "${REPO_DIR}/bench/run" --smoke
  assert_success
  assert_line --regexp '^\| `inspect` \| '
  assert_line --regexp '^\| `repeat` \| '
}

@test "bench run: an inspect row the repeat rule denies is timed under repeat" {
  # One probe key, `pgrep:java`: the repeat rule denies it once it reaches the
  # threshold within the window, so in one pass the leading rows are allowed and
  # the trailing ones denied by it.
  make_bench_repo \
    $'"pgrep java"\tallow' \
    $'"pgrep -a java"\tallow' \
    $'"pgrep -af java"\tallow' \
    $'"pgrep --list-full --full java"\tallow'
  # bench/run finds its repo from the working directory.
  cd "${FIXTURE}"
  run "${FIXTURE}/bench/run" --reps 1
  assert_success
  assert_line --regexp '^\| `inspect` \| [^|]+ \| 2 \| '
  assert_line --regexp '^\| `repeat` \| [^|]+ \| 2 \| '
}
