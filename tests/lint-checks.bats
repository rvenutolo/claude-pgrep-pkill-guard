# .ci/run-lint-checks' own control flow, against a throwaway repo and stub
# linters: what the gate does with the file lists it builds and the
# directories it looks for, not what any linter says about a file.
#
# `run --separate-stderr` is a bats 1.5.0 flag: the reason for an empty file
# list or a missing directory belongs on stderr, and a merged capture cannot
# tell it apart from a stray stdout write.
#
# setup sets CHECK, the gate under test, FIXTURE, the throwaway repo the gate
# runs in, and STUB_DIR, the directory holding the stub linters.
bats_require_minimum_version 1.5.0

function setup() {
  load 'test_helper/common'
  # .ci/in-devshell exports IN_DEVSHELL; the ambient compat legs do not have it.
  if [[ -z "${IN_DEVSHELL:-}" ]]; then
    skip 'not in the devShell; the gate re-runs itself there'
  fi
  CHECK="${REPO_DIR}/.ci/run-lint-checks"
  FIXTURE="${BATS_TEST_TMPDIR}/repo"
  STUB_DIR="${BATS_TEST_TMPDIR}/stubs"
  make_lint_fixture
}

# @description Build the throwaway repo these cases run the gate in, and the
#              stub linters it finds on PATH.
#
#              The repo tracks one file of every kind the gate lists except
#              Markdown, which each case adds or withholds: a bash script, an
#              awk program, a Nix file, and the .github directory with its
#              Renovate config and a workflow. It also holds a stub
#              `.ci/check-bash-style`, because the gate calls that one by its
#              path under the repo root rather than through PATH.
#
#              Every linter is a stub that exits 0, so a case's verdict comes
#              from the gate's handling of its lists alone, and the suite needs
#              no linter installed.
#
#              A real `git init` rather than a path walk, because the gate reads
#              its file lists from `git ls-files` on purpose. common.bash's
#              fixture-escape hardening is what keeps this `git` from resolving
#              to the author's own checkout.
#
#              A short flag only where macOS has no long form, on purpose: a
#              compat CI leg runs this suite against macOS BSD coreutils, whose
#              mkdir has no --parents.
#
#              Builds at the FIXTURE and STUB_DIR paths setup() chose.
# @noargs
function make_lint_fixture() {
  local -r -a linters=(
    'shellcheck' 'shfmt' 'gawk' 'just' 'statix' 'deadnix' 'actionlint' 'zizmor' 'yamllint'
    'renovate-config-validator' 'markdownlint-cli2' 'typos' 'editorconfig-checker'
  )
  local linter
  mkdir -p "${FIXTURE}/.ci" "${FIXTURE}/.github/workflows" "${STUB_DIR}"
  for linter in "${linters[@]}"; do
    printf '#!/bin/sh\nexit 0\n' > "${STUB_DIR}/${linter}"
    chmod +x "${STUB_DIR}/${linter}"
  done
  cp -- "${STUB_DIR}/shellcheck" "${FIXTURE}/.ci/check-bash-style"
  printf '#!/usr/bin/env bash\necho ok\n' > "${FIXTURE}/run-thing"
  printf 'BEGIN { exit 0 }\n' > "${FIXTURE}/scan.awk"
  printf '{ }\n' > "${FIXTURE}/flake.nix"
  printf '{}\n' > "${FIXTURE}/.github/renovate.json"
  printf 'on: push\n' > "${FIXTURE}/.github/workflows/ci.yml"
  git -C "${FIXTURE}" init --quiet
  git -C "${FIXTURE}" add --all
}

# @description Run the gate from inside the fixture, with the stub linters first
#              on PATH. The gate takes no arguments and takes its repo from
#              its own path, so the fixture runs a copy of it at the same
#              relative path.
# @noargs
function gate_in_fixture() {
  cp -- "${CHECK}" "${FIXTURE}/.ci/run-lint-checks"
  (cd "${FIXTURE}" && PATH="${STUB_DIR}:${PATH}" "${FIXTURE}/.ci/run-lint-checks")
}

# Every case needs nothing but bash, git and POSIX `mkdir -p`, `cp`, `mv -f`
# and `chmod`, but the gate takes no fixture argument and re-runs itself through
# .ci/in-devshell whenever IN_DEVSHELL is unset. The ambient compat legs have no
# Nix to start a devShell with, so setup skips this suite there, the same as
# tests/bats-no-shebang.bats; the gate legs run it.
#
# Nothing here grades a linter's verdict on the real repo: run-all-checks runs
# the gate itself, with the real linters, on every gate run.

@test "lint checks: a fixture tracking every listed kind of file passes" {
  # The baseline that keeps the failure cases honest: with a Markdown file
  # tracked, nothing else in the fixture fails the gate.
  printf '# Title\n' > "${FIXTURE}/README.md"
  git -C "${FIXTURE}" add -- 'README.md'
  run --separate-stderr gate_in_fixture
  assert_success
  assert_output ''
}

@test "lint checks: an empty Markdown file list is a failure, not a clean pass" {
  # An empty list means the enumeration broke, not that the repo has no
  # Markdown; a gate that skips the linter and passes has looked at nothing.
  run --separate-stderr gate_in_fixture
  assert_failure 1
  assert_output ''
  [[ "${stderr}" == *'[run-lint-checks] no markdown files found - this is a failure, not a clean pass'* ]]
}

@test "lint checks: a missing .github/workflows directory is a failure, not a clean pass" {
  # actionlint finds the workflows by itself, so the gate runs it only when the
  # directory is there; without it the step has linted nothing.
  printf '# Title\n' > "${FIXTURE}/README.md"
  git -C "${FIXTURE}" add -- 'README.md'
  mv -f -- "${FIXTURE}/.github/workflows" "${BATS_TEST_TMPDIR}/workflows"
  run --separate-stderr gate_in_fixture
  assert_failure 1
  assert_output ''
  [[ "${stderr}" == *'[run-lint-checks] no .github/workflows directory found - this is a failure, not a clean pass'* ]]
}

@test "lint checks: a missing .github directory is a failure, not a clean pass" {
  # zizmor is pointed at .github, so without the directory it has audited
  # nothing; the workflows went with it, so the actionlint step says so too.
  printf '# Title\n' > "${FIXTURE}/README.md"
  git -C "${FIXTURE}" add -- 'README.md'
  mv -f -- "${FIXTURE}/.github" "${BATS_TEST_TMPDIR}/github"
  run --separate-stderr gate_in_fixture
  assert_failure 1
  assert_output ''
  [[ "${stderr}" == *'[run-lint-checks] no .github directory found - this is a failure, not a clean pass'* ]]
  [[ "${stderr}" == *'[run-lint-checks] no .github/workflows directory found - this is a failure, not a clean pass'* ]]
}
