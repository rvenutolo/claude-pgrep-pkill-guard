setup() {
  load 'test_helper/common'
  CHECK="${REPO_DIR}/.ci/check-guard-parts"
}

# @description Build a minimal tracked tree in the shape the gate reads: a
#              loader carrying a two-row GUARD_PARTS table, and the two parts it
#              names, each defining its paired function. Each negative case
#              below then corrupts exactly one of them.
#
#              The table is written out here rather than copied from the real
#              loader. That duplication is the point: the gate must be graded
#              against a table whose rows a test controls, including rows that
#              are deliberately wrong -- which the real loader never has.
#
#              A real `git init` because the gate reads the parts list from
#              `git ls-files`, so an untracked scratch file never counts as a
#              part. common.bash's fixture-escape hardening is what keeps this
#              `git` from resolving to the author's own checkout.
#
#              POSIX short flags on purpose: the compat CI legs run this suite
#              against macOS BSD coreutils, whose mkdir has no --parents.
# @arg $1 root directory to populate
function make_parts_fixture() {
  local -r root="$1"
  mkdir -p "${root}/hooks/lib"
  cat > "${root}/hooks/pgrep-pkill-guard-body.sh" << 'BODY'
# shellcheck shell=bash
readonly -a GUARD_PARTS=(
  'tokens.sh:tokens::is_keyword'
  'classify.sh:classify::inspect_command'
)
BODY
  printf 'function tokens::is_keyword() {\n  :\n}\n' > "${root}/hooks/lib/tokens.sh"
  printf 'function classify::inspect_command() {\n  :\n}\n' > "${root}/hooks/lib/classify.sh"
  git -C "${root}" init --quiet
  git -C "${root}" add --all
}

# Every case drives FIXTURE mode, which needs nothing but bash, git and grep --
# deliberately no coreutils long options and no Nix -- so the ambient macOS
# compat legs run this suite for real rather than skipping it. Hence no devShell
# skip here, the same as tests/invariant-markers.bats and tests/issue-forms.bats.
#
# The first case is the exception that keeps the rest honest: it points the gate
# at the real repo, so a fixture that has drifted away from the shape the
# tracked loader actually has cannot hide behind a green suite.

@test "guard parts: the real repo passes" {
  # REPO_DIR explicitly rather than relying on the argument-less default: the
  # default resolves through `git rev-parse --show-toplevel`, and a bats test
  # must not depend on the directory the suite happened to be launched from.
  # The path taken is identical either way.
  run "${CHECK}" "${REPO_DIR}"
  assert_success
  assert_output --partial 'GUARD_PARTS rows resolve'
}

@test "guard parts: a valid fixture passes" {
  local -r root="${BATS_TEST_TMPDIR}/ok"
  make_parts_fixture "${root}"
  run "${CHECK}" "${root}"
  assert_success
}

@test "guard parts: a row whose function was renamed away is named" {
  # The bug this gate was filed for. The part loads perfectly well; only the
  # string in the table is stale, and at runtime that stands the guard down on
  # every call while the message blames the file (#147).
  local -r root="${BATS_TEST_TMPDIR}/renamed"
  make_parts_fixture "${root}"
  printf 'function inspect_payload() {\n  :\n}\n' > "${root}/hooks/lib/classify.sh"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'hooks/lib/classify.sh does not define classify::inspect_command()'
  # The other row is intact and must not be dragged into the verdict.
  refute_output --partial 'tokens.sh does not define'
}

@test "guard parts: a row naming a file that does not exist is named" {
  local -r root="${BATS_TEST_TMPDIR}/gone"
  make_parts_fixture "${root}"
  rm -f "${root}/hooks/lib/classify.sh"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'hooks/lib/classify.sh, which does not exist'
}

@test "guard parts: a part no row names is reported" {
  # The reverse direction, which had no signal at all before this gate: the
  # loader sources an explicit list, so an unlisted part is never sourced and
  # every function in it is undefined at runtime.
  local -r root="${BATS_TEST_TMPDIR}/unlisted"
  make_parts_fixture "${root}"
  printf 'function loops::loop_context() {\n  :\n}\n' > "${root}/hooks/lib/loops.sh"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'hooks/lib/loops.sh is not named by any GUARD_PARTS row'
}

@test "guard parts: an untracked file in lib/ is not mistaken for a part" {
  # The parts list comes from `git ls-files` on purpose. A scratch file left in
  # hooks/lib/ during editing is not something the loader would ever source,
  # and reporting it would train the reader to ignore this gate.
  local -r root="${BATS_TEST_TMPDIR}/untracked"
  make_parts_fixture "${root}"
  printf 'function scratch() {\n  :\n}\n' > "${root}/hooks/lib/scratch.sh"
  run "${CHECK}" "${root}"
  assert_success
  refute_output --partial 'scratch.sh'
}

@test "guard parts: a part named by two rows is reported" {
  # Sourcing one part twice is not a style question: every part declares
  # readonly constants, and the second source would fail on them.
  local -r root="${BATS_TEST_TMPDIR}/twice"
  make_parts_fixture "${root}"
  cat > "${root}/hooks/pgrep-pkill-guard-body.sh" << 'BODY'
# shellcheck shell=bash
readonly -a GUARD_PARTS=(
  'tokens.sh:tokens::is_keyword'
  'tokens.sh:tokens::is_keyword'
  'classify.sh:classify::inspect_command'
)
BODY
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'named by 2 GUARD_PARTS rows'
}

@test "guard parts: a malformed row is reported rather than parsed loosely" {
  local -r root="${BATS_TEST_TMPDIR}/malformed"
  make_parts_fixture "${root}"
  cat > "${root}/hooks/pgrep-pkill-guard-body.sh" << 'BODY'
# shellcheck shell=bash
readonly -a GUARD_PARTS=(
  'tokens.sh'
  'classify.sh:classify::inspect_command'
)
BODY
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'is not <file>:<function>'
}

@test "guard parts: a namespaced function half is graded, not rejected for its colons" {
  # The row separator is the first colon; `tokens::is_keyword` adds two more.
  # A colon count would call every row in the real table malformed.
  local -r root="${BATS_TEST_TMPDIR}/namespaced"
  make_parts_fixture "${root}"
  cat > "${root}/hooks/pgrep-pkill-guard-body.sh" << 'BODY'
# shellcheck shell=bash
readonly -a GUARD_PARTS=(
  'tokens.sh:tokens::is_keyword'
  'classify.sh:classify::inspect_command'
)
BODY
  printf 'function tokens::is_keyword() {\n  :\n}\n' > "${root}/hooks/lib/tokens.sh"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_success
}

@test "guard parts: a function half that is not a function name is still malformed" {
  # The relaxation above grades the remainder as a name rather than counting
  # colons; a trailing `:extra` is not one, and must not slip through.
  local -r root="${BATS_TEST_TMPDIR}/bad-half"
  make_parts_fixture "${root}"
  cat > "${root}/hooks/pgrep-pkill-guard-body.sh" << 'BODY'
# shellcheck shell=bash
readonly -a GUARD_PARTS=(
  'tokens.sh:is_keyword:extra'
  'classify.sh:classify::inspect_command'
)
BODY
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'is not <file>:<function>'
}

@test "guard parts: an indented definition does not count as a definition" {
  # `declare -F` sees a function only once its enclosing definition has RUN, and
  # nothing in a part runs at load time. A nested definition therefore does not
  # exist when the loader checks, so the gate must not accept one either.
  local -r root="${BATS_TEST_TMPDIR}/nested"
  make_parts_fixture "${root}"
  cat > "${root}/hooks/lib/classify.sh" << 'PART'
function outer() {
  function classify::inspect_command() {
    :
  }
}
PART
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'does not define classify::inspect_command()'
}

@test "guard parts: a comment inside the table is not read as a row" {
  local -r root="${BATS_TEST_TMPDIR}/comment"
  make_parts_fixture "${root}"
  cat > "${root}/hooks/pgrep-pkill-guard-body.sh" << 'BODY'
# shellcheck shell=bash
readonly -a GUARD_PARTS=(
  # low-level helpers first
  'tokens.sh:tokens::is_keyword'
  'classify.sh:classify::inspect_command'
)
BODY
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_success
  assert_output --partial '2 GUARD_PARTS rows resolve'
}

@test "guard parts: a later array in the loader does not leak in as rows" {
  # The reader stops at the closing paren. Without that, any array declared
  # after the table would be graded as part rows.
  local -r root="${BATS_TEST_TMPDIR}/later"
  make_parts_fixture "${root}"
  cat > "${root}/hooks/pgrep-pkill-guard-body.sh" << 'BODY'
# shellcheck shell=bash
readonly -a GUARD_PARTS=(
  'tokens.sh:tokens::is_keyword'
  'classify.sh:classify::inspect_command'
)
readonly -a SOMETHING_ELSE=(
  'not-a-part.sh:not_a_function'
)
BODY
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_success
  refute_output --partial 'not-a-part.sh'
}

@test "guard parts: an empty table is not a clean pass" {
  local -r root="${BATS_TEST_TMPDIR}/empty"
  make_parts_fixture "${root}"
  cat > "${root}/hooks/pgrep-pkill-guard-body.sh" << 'BODY'
# shellcheck shell=bash
readonly -a GUARD_PARTS=(
)
BODY
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'no GUARD_PARTS rows found'
}

@test "guard parts: a loader the gate cannot read is a failure" {
  local -r root="${BATS_TEST_TMPDIR}/no-loader"
  make_parts_fixture "${root}"
  rm -f "${root}/hooks/pgrep-pkill-guard-body.sh"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'there is no table to check'
}
