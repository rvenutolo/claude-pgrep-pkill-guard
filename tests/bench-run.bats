# bench/run's cohorts: the report lists every cohort, an `inspect` row the
# repeat rule denies is timed under `repeat` rather than `inspect`, and
# --sample caps the rows each corpus cohort times per pass, spares `typical`, is
# recorded in the report and rejects a bad value. Driven
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

@test "bench run: --sample caps the rows a corpus cohort times on each pass" {
  make_bench_repo \
    $'"while pgrep -f a >/dev/null; do sleep 1; done"\tdeny:loop' \
    $'"while pgrep -f b >/dev/null; do sleep 1; done"\tdeny:loop' \
    $'"while pgrep -f c >/dev/null; do sleep 1; done"\tdeny:loop' \
    $'"while pgrep -f d >/dev/null; do sleep 1; done"\tdeny:loop' \
    $'"while pgrep -f e >/dev/null; do sleep 1; done"\tdeny:loop'
  cd "${FIXTURE}"
  run "${FIXTURE}/bench/run" --reps 2 --sample 2
  assert_success
  assert_line --regexp '^\| `deny` \| [^|]+ \| 4 \| '
}

@test "bench run: a cohort smaller than --sample is timed in full on each pass" {
  make_bench_repo $'"echo PAYLOAD_RAN"\tallow'
  cd "${FIXTURE}"
  run "${FIXTURE}/bench/run" --reps 2 --sample 3
  assert_success
  assert_line --regexp '^\| `skipped` \| [^|]+ \| 2 \| '
  assert_line --regexp '^\| `baseline` \| [^|]+ \| 2 \| '
}

@test "bench run: --sample never thins the typical cohort" {
  make_bench_repo $'"echo PAYLOAD_RAN"\tallow'
  cd "${FIXTURE}"
  local -r row_re='^\| `typical` \| [^|]+ \| ([0-9]+) \| '
  local -a typical_n=()
  local sample line
  for sample in 1 1000; do
    run "${FIXTURE}/bench/run" --reps 2 --sample "${sample}"
    assert_success
    for line in "${lines[@]}"; do
      if [[ "${line}" =~ ${row_re} ]]; then
        typical_n+=("${BASH_REMATCH[1]}")
      fi
    done
  done
  assert_equal "${#typical_n[@]}" 2
  # More typical commands than one per pass, so a cap of 1 would show.
  if ((typical_n[0] <= 2)); then
    fail "typical n is ${typical_n[0]}; too few to show a cap of 1"
  fi
  assert_equal "${typical_n[0]}" "${typical_n[1]}"
}

@test "bench run: the report records the --sample value" {
  make_bench_repo $'"echo PAYLOAD_RAN"\tallow'
  cd "${FIXTURE}"
  run "${FIXTURE}/bench/run" --reps 1 --sample 7
  assert_success
  assert_line --regexp '^\| rows per cohort per pass \| 7 \|$'
}

@test "bench run: --sample rejects a value that is not a positive integer" {
  cd "${REPO_DIR}"
  local value
  for value in 0 x -3 ''; do
    run "${REPO_DIR}/bench/run" --sample "${value}"
    assert_failure 1
    assert_output --partial '--sample must be a positive integer'
  done
}

@test "bench run: --sample with no value is rejected" {
  cd "${REPO_DIR}"
  run "${REPO_DIR}/bench/run" --sample
  assert_failure 1
  assert_output --partial '--sample needs a value'
}
