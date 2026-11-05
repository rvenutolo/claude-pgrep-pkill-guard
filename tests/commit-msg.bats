# .githooks/commit-msg, run against the real .commitlintrc.yml: the subjects
# and bodies the hook must accept, the ones it must reject, and the one it
# accepts with a warning. The CI commitlint job runs the same devShell
# commitlint against the same file, reading the commits from git rather than
# from a message file, so the rules graded here are the rules CI applies.
#
# The hook reaches commitlint through .ci/in-devshell, which runs it directly
# when IN_DEVSHELL is set and starts a fresh devShell otherwise. The ambient
# compat legs have no Nix to start one with, so this suite skips outside it.

function setup() {
  load 'test_helper/common'
  # .ci/in-devshell exports IN_DEVSHELL; the ambient compat legs do not have it.
  if [[ -z "${IN_DEVSHELL:-}" ]]; then
    skip 'not in the devShell; commitlint runs only there'
  fi
}

# @description Run the hook from the repo root on a message file holding the
#              text given. The hook finds .commitlintrc.yml through
#              `git rev-parse --show-toplevel`, so the cd selects the real
#              config.
# @arg $1 message the full commit message, newlines included
function hook_on() {
  local -r message="$1"
  local -r msg_file="${BATS_TEST_TMPDIR}/COMMIT_EDITMSG"
  printf '%s' "${message}" > "${msg_file}"
  (cd "${REPO_DIR}" && "${REPO_DIR}/.githooks/commit-msg" "${msg_file}")
}

@test "commit-msg: a plain subject passes" {
  run hook_on $'feat: add a flag\n'
  assert_success
}

@test "commit-msg: a breaking-change subject passes" {
  run hook_on $'feat!: drop a flag\n'
  assert_success
}

@test "commit-msg: a scoped breaking-change subject passes" {
  run hook_on $'feat(api)!: drop a flag\n'
  assert_success
}

@test "commit-msg: a revert subject passes" {
  run hook_on $'revert: feat: add a flag\n\nThis reverts commit 0123456789abcdef0123456789abcdef01234567.\n'
  assert_success
}

# Without .commitlintrc.yml's issuePrefixes, the issue-citing line opens a footer and
# draws a footer-leading-blank warning, which does not fail the commit; so
# the absence of the warning is what this pins, not only the exit status.
@test "commit-msg: a body citing an issue mid-paragraph passes without a warning" {
  run hook_on $'fix: tighten a check\n\nThe first body line.\nThis follows #12 and more text after it.\n'
  assert_success
  refute_output --partial 'footer-leading-blank'
}

@test "commit-msg: a subject with no type is rejected" {
  run hook_on $'add a flag\n'
  assert_failure
  assert_output --partial 'type may not be empty'
}

# config-conventional sets footer-leading-blank to a warning, so the commit
# goes through; what .commitlintrc.yml's issuePrefixes choice preserves is
# that the rule still sees the footer and says so.
@test "commit-msg: a BREAKING CHANGE footer with no blank line above it warns" {
  run hook_on $'feat: drop a flag\n\nThe body.\nBREAKING CHANGE: the flag is gone\n'
  assert_success
  assert_output --partial 'footer-leading-blank'
}
