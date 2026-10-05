# .ci/run-lint-checks' own control flow, against a throwaway repo and stub
# linters: what the gate does with the file lists it builds, not what any
# linter says about a file.
#
# `run --separate-stderr` is a bats 1.5.0 flag: the reason for an empty file
# list belongs on stderr, and a merged capture cannot tell it apart from a
# stray stdout write.
#
# setup sets CHECK, the gate under test, FIXTURE, the throwaway repo the gate
# runs in, and STUB_DIR, the directory holding the stub linters.
bats_require_minimum_version 1.5.0

function setup() {
  load 'test_helper/common'
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
#              Renovate config. It also holds a stub `.ci/check-bash-style`,
#              because the gate calls that one by its path under the repo root
#              rather than through PATH.
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
  mkdir -p "${FIXTURE}/.ci" "${FIXTURE}/.github" "${STUB_DIR}"
  for linter in "${linters[@]}"; do
    printf '#!/bin/sh\nexit 0\n' > "${STUB_DIR}/${linter}"
    chmod +x "${STUB_DIR}/${linter}"
  done
  cp -- "${STUB_DIR}/shellcheck" "${FIXTURE}/.ci/check-bash-style"
  printf '#!/usr/bin/env bash\necho ok\n' > "${FIXTURE}/run-thing"
  printf 'BEGIN { exit 0 }\n' > "${FIXTURE}/scan.awk"
  printf '{ }\n' > "${FIXTURE}/flake.nix"
  printf '{}\n' > "${FIXTURE}/.github/renovate.json"
  git -C "${FIXTURE}" init --quiet
  git -C "${FIXTURE}" add --all
}

# @description Run the gate from inside the fixture, with the stub linters first
#              on PATH. The gate takes no arguments and finds its repo with
#              `git rev-parse --show-toplevel`, so the cd is the fixture
#              selection.
# @noargs
function gate_in_fixture() {
  (cd "${FIXTURE}" && PATH="${STUB_DIR}:${PATH}" "${CHECK}")
}

# Every case needs nothing but bash, git and POSIX `mkdir -p`, `cp` and
# `chmod` -- deliberately no coreutils long options and no Nix -- so the ambient
# `compat (macos, homebrew bash)` leg runs this suite for real rather than
# skipping it. Hence no devShell skip here, the same as
# tests/bats-no-shebang.bats.
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
