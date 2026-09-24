function setup() {
  load 'test_helper/common'
  CHECK="${REPO_DIR}/.ci/check-bats-no-shebang"
}

# @description Build a minimal tracked tree in the shape the gate scans: a git
#              repo holding two shebang-less .bats files. Each negative case
#              below then rewrites one of them.
#
#              A real `git init` rather than a path walk, because the gate reads
#              its file list from `git ls-files` on purpose -- an untracked
#              scratch file must never reach it. common.bash's fixture-escape
#              hardening is what keeps this `git` from resolving to the author's
#              own checkout.
#
#              The fixture files are data the gate only reads; nothing here ever
#              executes them.
#
#              A short flag only where macOS has no long form, on purpose: the
#              compat CI legs run this suite against macOS BSD coreutils, whose
#              mkdir has no --parents.
# @arg $1 root directory to populate
function make_bats_fixture() {
  local -r root="$1"
  mkdir -p "${root}/tests"
  printf '@test "a" {\n  :\n}\n' > "${root}/tests/a.bats"
  printf '@test "b" {\n  :\n}\n' > "${root}/tests/b.bats"
  git -C "${root}" init --quiet
  git -C "${root}" add --all
}

# @description Run the gate from inside a directory. The gate takes no
#              arguments and finds its repo with `git rev-parse --show-toplevel`,
#              so the cd is the fixture selection.
# @arg $1 dir the repo to run the gate in
function gate_in() {
  local -r dir="$1"
  (cd "${dir}" && "${CHECK}")
}

# Every case needs nothing but bash and git -- deliberately no coreutils long
# options and no Nix -- so the ambient macOS compat legs run this suite for real
# rather than skipping it. Hence no devShell skip here, the same as
# tests/shell-shebangs.bats.
#
# The first case is the exception that keeps the rest honest: it runs the gate
# in the real repo, so a fixture that has drifted away from the shape the
# tracked suites actually have cannot hide behind a green suite.

@test "bats no shebang: the real repo passes" {
  run gate_in "${REPO_DIR}"
  assert_success
  assert_output ''
}

@test "bats no shebang: a valid fixture passes" {
  local -r root="${BATS_TEST_TMPDIR}/ok"
  make_bats_fixture "${root}"
  run gate_in "${root}"
  assert_success
}

@test "bats no shebang: a shebang is named and rejected" {
  local -r root="${BATS_TEST_TMPDIR}/shebang"
  make_bats_fixture "${root}"
  printf '#!/usr/bin/env bats\n@test "a" {\n  :\n}\n' > "${root}/tests/a.bats"
  git -C "${root}" add --all
  run gate_in "${root}"
  assert_failure
  assert_output --partial 'tests/a.bats'
  assert_output --partial '#!/usr/bin/env bats'
}

@test "bats no shebang: a lone shebang with no trailing newline is rejected" {
  # `read` stores an unterminated last line AND returns 1. A fallback that
  # blanks the variable on that status throws away the shebang it just read,
  # and the gate passes the file (#305).
  local -r root="${BATS_TEST_TMPDIR}/unterminated"
  make_bats_fixture "${root}"
  printf '#!/usr/bin/env bats' > "${root}/tests/a.bats"
  git -C "${root}" add --all
  run gate_in "${root}"
  assert_failure
  assert_output --partial 'tests/a.bats'
  assert_output --partial '#!/usr/bin/env bats'
}

@test "bats no shebang: an empty .bats file passes" {
  # The other way `read` returns 1: nothing to read at all. No first line
  # means no shebang.
  local -r root="${BATS_TEST_TMPDIR}/empty-file"
  make_bats_fixture "${root}"
  : > "${root}/tests/a.bats"
  git -C "${root}" add --all
  run gate_in "${root}"
  assert_success
}

@test "bats no shebang: a #! past the first line is not a shebang" {
  local -r root="${BATS_TEST_TMPDIR}/later-line"
  make_bats_fixture "${root}"
  printf '# a comment\n#!/usr/bin/env bats\n' > "${root}/tests/a.bats"
  git -C "${root}" add --all
  run gate_in "${root}"
  assert_success
}

@test "bats no shebang: an untracked .bats file is not scanned" {
  local -r root="${BATS_TEST_TMPDIR}/untracked"
  make_bats_fixture "${root}"
  printf '#!/usr/bin/env bats\n' > "${root}/tests/scratch.bats"
  run gate_in "${root}"
  assert_success
  refute_output --partial 'scratch.bats'
}

@test "bats no shebang: every failing file is named, not just the first" {
  local -r root="${BATS_TEST_TMPDIR}/several"
  make_bats_fixture "${root}"
  printf '#!/usr/bin/env bats\n' > "${root}/tests/a.bats"
  printf '#!/usr/bin/env bats\n' > "${root}/tests/b.bats"
  git -C "${root}" add --all
  run gate_in "${root}"
  assert_failure
  assert_output --partial 'tests/a.bats'
  assert_output --partial 'tests/b.bats'
}

@test "bats no shebang: an empty scan is not a clean pass" {
  # A gate that looked at nothing and said ok.
  local -r root="${BATS_TEST_TMPDIR}/empty"
  mkdir -p "${root}"
  printf 'root = true\n' > "${root}/.editorconfig"
  git -C "${root}" init --quiet
  git -C "${root}" add --all
  run gate_in "${root}"
  assert_failure
  assert_output --partial 'no .bats files found'
}
