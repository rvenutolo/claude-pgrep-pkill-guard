setup() {
  load 'test_helper/common'
  CHECK="${REPO_DIR}/.ci/check-bench-fresh"
}

# @description Build a throwaway repo in the shape the check expects: one
#              hooks/ file, one README, and a bench/RESULTS.md whose provenance
#              table records the commit before it -- which is exactly what
#              `just bench` on a branch produces, and therefore the state the
#              check must call fresh. Each case below then moves one thing.
#
#              POSIX short flags on purpose: the compat CI legs run this suite
#              against macOS BSD coreutils, whose mkdir has no --parents.
#
#              Identity is passed with `-c` rather than written with
#              `git config`, because test_helper/common points
#              GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM at /dev/null -- a commit
#              with no resolvable identity fails outright.
# @arg $1 root directory to create the repo in
function make_bench_fixture() {
  local -r root="$1"
  mkdir -p "${root}/hooks" "${root}/bench"
  git -c init.defaultBranch=main init -q "${root}"
  printf 'guard\n' > "${root}/hooks/pgrep-pkill-guard.sh"
  printf 'readme\n' > "${root}/README.md"
  git -C "${root}" add hooks/pgrep-pkill-guard.sh README.md
  commit_fixture "${root}" 'seed'
  write_results "${root}" "$(short_head "${root}")"
  git -C "${root}" add bench/RESULTS.md
  commit_fixture "${root}" 'chore: regenerate bench/RESULTS.md'
}

# @description Commit whatever is staged in the fixture repo.
# @arg $1 root the fixture repo
# @arg $2 message the commit subject
function commit_fixture() {
  local -r root="$1"
  local -r message="$2"
  git -C "${root}" -c user.email='tests@example.invalid' -c user.name='Tests' \
    commit -q -m "${message}"
}

# @description Print the fixture repo's HEAD as a short sha.
# @arg $1 root the fixture repo
# @stdout the short sha
function short_head() {
  git -C "$1" rev-parse --short HEAD
}

# @description Write a bench/RESULTS.md whose provenance table records one sha.
#              The table carries a second row and a paragraph that both contain
#              the word "commit", so a check that matched on that word alone
#              rather than on the row's structure would read the wrong cell.
# @arg $1 root the fixture repo
# @arg $2 sha the commit to record
function write_results() {
  local -r root="$1"
  local -r sha="$2"
  mkdir -p "${root}/bench"
  cat > "${root}/bench/RESULTS.md" << RESULTS
# Hook benchmark results

## Provenance

| field | value |
| --- | --- |
| date | 2026-09-02T00:00:00+00:00 |
| commit | \`${sha}\` |
| note | generated one commit before this row was committed |

Prose below the table, mentioning the word commit on purpose.
RESULTS
}

# @description Replace the provenance table's recorded sha in place, leaving the
#              file uncommitted in the worktree. That is enough for every case
#              here: the check reads the report off disk and the history out of
#              git, so what matters is what the file says, not whether it is
#              staged.
# @arg $1 root the fixture repo
# @arg $2 sha the commit to record
function record_commit() {
  write_results "$1" "$2"
}

# The first case points the script at the real repo; every other case drives
# FIXTURE mode, which needs no devShell -- only git -- so this suite carries no
# skip and runs on the ambient compat legs too, the same as
# tests/devshell-provides.bats and tests/invariant-markers.bats.

@test "bench fresh: the real repo is accepted" {
  # Only the exit code is asserted, deliberately. The two ambient compat legs
  # check out at actions/checkout's default depth of 1, where the recorded
  # commit is not in the object store and the honest verdict is the skip -- so
  # asserting on the `ok:` line here would redden those legs for a property of
  # the checkout rather than of the tree. Both accepted verdicts exit 0, which
  # is the part that holds everywhere.
  #
  # REPO_DIR is passed explicitly rather than relying on the argument-less
  # default: that default resolves through `git rev-parse --show-toplevel`, and
  # a bats test must not depend on the directory the suite was launched from.
  run "${CHECK}" "${REPO_DIR}"
  assert_success
}

@test "bench fresh: a report generated at HEAD's parent passes" {
  # The normal case, and the one the naive design gets wrong: `just bench` runs
  # on a branch, records the commit it ran at, and the regenerated report is
  # then committed on top of it. The recorded commit is HEAD's parent and is on
  # no shared branch yet. That must pass.
  local -r root="${BATS_TEST_TMPDIR}/fresh"
  make_bench_fixture "${root}"
  run "${CHECK}" "${root}"
  assert_success
  assert_output --partial 'hooks/ is unchanged since'
}

@test "bench fresh: a commit outside hooks/ does not make the report stale" {
  # Only hooks/ can move the numbers. A README edit -- or an edit to the bench
  # harness itself -- must not fire, or the gate becomes something people learn
  # to regenerate their way past.
  local -r root="${BATS_TEST_TMPDIR}/unrelated"
  make_bench_fixture "${root}"
  printf 'readme, revised\n' > "${root}/README.md"
  git -C "${root}" add README.md
  commit_fixture "${root}" 'docs: revise the readme'
  run "${CHECK}" "${root}"
  assert_success
}

@test "bench fresh: a hooks/ commit since the recorded one is stale" {
  local -r root="${BATS_TEST_TMPDIR}/stale"
  make_bench_fixture "${root}"
  printf 'guard, split\n' > "${root}/hooks/pgrep-pkill-guard.sh"
  git -C "${root}" add hooks/pgrep-pkill-guard.sh
  commit_fixture "${root}" 'perf: split the guard'
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'bench/RESULTS.md is stale'
  assert_output --partial 'changed in 1 commit(s) since'
  assert_output --partial 'perf: split the guard'
  assert_output --partial 'just bench'
}

@test "bench fresh: an unreachable recorded commit is a different failure" {
  # The state the real repo was in when this gate was written: `4c189fb` is in
  # the object store and on no branch, because it was superseded on its own
  # branch before that branch merged. No comparison is possible, so the report
  # must not claim one -- saying "hooks/ changed" here would send the reader to
  # a diff that does not exist.
  local -r root="${BATS_TEST_TMPDIR}/unreachable"
  make_bench_fixture "${root}"
  printf 'guard, superseded\n' > "${root}/hooks/pgrep-pkill-guard.sh"
  git -C "${root}" add hooks/pgrep-pkill-guard.sh
  commit_fixture "${root}" 'perf: a commit that will be discarded'
  local discarded
  discarded="$(short_head "${root}")"
  git -C "${root}" reset -q --hard HEAD~1
  record_commit "${root}" "${discarded}"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'exists but is not'
  assert_output --partial 'reachable from HEAD'
  assert_output --partial 'just bench'
  refute_output --partial 'is stale'
}

@test "bench fresh: a recorded commit absent from the clone skips" {
  # A shallow clone. The question is unanswerable, and a consumer who cloned
  # with --depth 1 must not get a red gate over history they never fetched.
  local -r root="${BATS_TEST_TMPDIR}/absent"
  make_bench_fixture "${root}"
  record_commit "${root}" 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
  run "${CHECK}" "${root}"
  assert_success
  assert_output --partial 'not in this clone'
  assert_output --partial 'fetch-depth: 0'
  refute_output --partial 'FAIL'
}

@test "bench fresh: a provenance table with no commit row is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/no-row"
  make_bench_fixture "${root}"
  cat > "${root}/bench/RESULTS.md" << 'RESULTS'
# Hook benchmark results

| field | value |
| --- | --- |
| date | 2026-09-02T00:00:00+00:00 |

This report forgot to say which commit it came from.
RESULTS
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'no usable commit row'
}

@test "bench fresh: a commit cell that is not a sha is rejected" {
  # `unknown` in the cell is a malformed report, not a missing history. Handing
  # it to git would surface as a crash inside a plumbing command instead of as
  # the verdict a reader can act on.
  local -r root="${BATS_TEST_TMPDIR}/not-a-sha"
  make_bench_fixture "${root}"
  cat > "${root}/bench/RESULTS.md" << 'RESULTS'
# Hook benchmark results

| field | value |
| --- | --- |
| commit | `unknown` |
RESULTS
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'no usable commit row'
}

@test "bench fresh: a missing report is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/no-report"
  make_bench_fixture "${root}"
  rm -f "${root}/bench/RESULTS.md"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'is missing or unreadable'
}
