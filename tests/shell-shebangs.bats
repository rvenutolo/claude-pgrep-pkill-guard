function setup() {
  load 'test_helper/common'
  CHECK="${REPO_DIR}/.ci/check-shell-shebangs"
}

# @description Build a minimal tracked tree in the shape the gate scans: a git
#              repo holding one canonical bash script, one shebang-less sourced
#              part, one non-script data file, and the exempt POSIX-sh gate.
#              Each negative case below then corrupts exactly one of them.
#
#              A real `git init` rather than a path walk, because the gate reads
#              its file list from `git ls-files` on purpose -- an untracked
#              scratch file must never reach it. common.bash's fixture-escape
#              hardening is what keeps this `git` from resolving to the author's
#              own checkout.
#
#              POSIX short flags on purpose: the compat CI legs run this suite
#              against macOS BSD coreutils, whose mkdir has no --parents.
# @arg $1 root directory to populate
function make_shebang_fixture() {
  local -r root="$1"
  mkdir -p "${root}/.ci" "${root}/hooks/lib"
  printf '#!/usr/bin/env bash\necho ok\n' > "${root}/run-thing"
  printf '# shellcheck shell=bash\nfunction f() { :; }\n' > "${root}/hooks/lib/part.sh"
  printf 'root = true\n' > "${root}/.editorconfig"
  printf '#!/bin/sh\nexit 0\n' > "${root}/.ci/check-inactive-on-old-bash"
  git -C "${root}" init --quiet
  git -C "${root}" add --all
}

# Every case drives FIXTURE mode, which needs nothing but bash and git --
# deliberately no coreutils long options and no Nix -- so the ambient macOS
# compat legs run this suite for real rather than skipping it. Hence no
# devShell skip here, the same as tests/invariant-markers.bats and
# tests/issue-forms.bats.
#
# The first case is the exception that keeps the rest honest: it points the gate
# at the real repo, so a fixture that has drifted away from the shape the
# tracked sources actually have cannot hide behind a green suite.

@test "shell shebangs: the real repo passes" {
  # REPO_DIR explicitly rather than relying on the argument-less default: the
  # default resolves through `git rev-parse --show-toplevel`, and a bats test
  # must not depend on the directory the suite happened to be launched from.
  # The path taken is identical either way.
  run "${CHECK}" "${REPO_DIR}"
  assert_success
  assert_output --partial 'shebangs canonical'
}

@test "shell shebangs: a valid fixture passes" {
  local -r root="${BATS_TEST_TMPDIR}/ok"
  make_shebang_fixture "${root}"
  run "${CHECK}" "${root}"
  assert_success
}

@test "shell shebangs: #!/bin/bash is named and rejected" {
  # The hole this gate was filed for (#171). Before it existed, a file spelled
  # this way was dropped from BOTH shellcheck and shfmt by
  # .ci/run-lint-checks' shell_files, with no diagnostic at all.
  local -r root="${BATS_TEST_TMPDIR}/bin-bash"
  make_shebang_fixture "${root}"
  printf '#!/bin/bash\necho ok\n' > "${root}/run-thing"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'run-thing'
  assert_output --partial '#!/bin/bash'
  assert_output --partial '#!/usr/bin/env bash'
}

@test "shell shebangs: env -S bash is rejected too" {
  # The other spelling #171 calls out. It is bash, it works, and shell_files
  # still would not have matched it.
  local -r root="${BATS_TEST_TMPDIR}/env-s"
  make_shebang_fixture "${root}"
  printf '#!/usr/bin/env -S bash\necho ok\n' > "${root}/run-thing"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'non-canonical bash shebang'
}

@test "shell shebangs: an unexempt non-bash interpreter must be declared" {
  local -r root="${BATS_TEST_TMPDIR}/python"
  make_shebang_fixture "${root}"
  printf '#!/usr/bin/env python3\nprint("ok")\n' > "${root}/tool"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'tool'
  assert_output --partial 'SHEBANG_EXEMPT'
}

@test "shell shebangs: an exempt path pins its exact shebang" {
  # The exemption is for one spelling, not for the path. Rewriting the stock-sh
  # gate's shebang to bash must redden rather than pass on a stale allowance --
  # the whole point of that file is that it runs under bash 3.2-era /bin/sh.
  local -r root="${BATS_TEST_TMPDIR}/exempt-drift"
  make_shebang_fixture "${root}"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${root}/.ci/check-inactive-on-old-bash"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'check-inactive-on-old-bash'
  assert_output --partial '#!/bin/sh'
}

@test "shell shebangs: an exemption row for a vanished file is reported" {
  # An exemption nobody can see the subject of is an exemption nobody
  # re-examines. If the file goes, the row has to go with it.
  local -r root="${BATS_TEST_TMPDIR}/exempt-gone"
  make_shebang_fixture "${root}"
  rm -f "${root}/.ci/check-inactive-on-old-bash"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'is not a tracked file'
}

@test "shell shebangs: a shebang-less sourced part is not asked for one" {
  # hooks/lib/*.sh and hooks/pgrep-pkill-guard-body.sh carry no shebang on
  # purpose -- they are sourced, never executed, and check-executable-bit
  # forbids the exec bit. The gate judges the shebangs that exist; it must
  # never demand one.
  local -r root="${BATS_TEST_TMPDIR}/no-shebang"
  make_shebang_fixture "${root}"
  run "${CHECK}" "${root}"
  assert_success
  refute_output --partial 'part.sh'
}

@test "shell shebangs: a .bats file is left to check-bats-no-shebang" {
  # Two gates must not give a file contradictory orders. .bats files may carry
  # no shebang at all, which is check-bats-no-shebang's rule; this gate would
  # otherwise tell one to make its shebang canonical instead.
  local -r root="${BATS_TEST_TMPDIR}/bats"
  make_shebang_fixture "${root}"
  printf '#!/bin/bash\n@test "x" { :; }\n' > "${root}/tests.bats"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_success
  refute_output --partial 'tests.bats'
}

@test "shell shebangs: an empty scan is not a clean pass" {
  # Same class of bug as an empty tool list in check-devshell-provides: a gate
  # that looked at nothing and said ok.
  local -r root="${BATS_TEST_TMPDIR}/empty"
  mkdir -p "${root}"
  printf 'root = true\n' > "${root}/.editorconfig"
  git -C "${root}" init --quiet
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'empty scan'
}

@test "shell shebangs: every failing file is named, not just the first" {
  # The gate aggregates rather than failing fast, the same way run-all-checks
  # does: one run should surface every offender.
  local -r root="${BATS_TEST_TMPDIR}/several"
  make_shebang_fixture "${root}"
  printf '#!/bin/bash\necho ok\n' > "${root}/run-thing"
  printf '#!/bin/bash\necho ok\n' > "${root}/run-other"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'run-thing'
  assert_output --partial 'run-other'
}
