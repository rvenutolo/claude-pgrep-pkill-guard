setup() {
  load 'test_helper/common'
  CHECK="${REPO_DIR}/.ci/check-invariant-markers"
}

# @description Build a minimal, VALID tree in the shape the marker table
#              expects: the five files it names, each carrying every phrase its
#              row demands, and nothing else. Each negative case below then
#              corrupts exactly one of them.
#
#              The phrases are written out here rather than read from the
#              script. That duplication is the point: if someone edits the table
#              in .ci/check-invariant-markers, this suite goes red and they have
#              to say so out loud, instead of the check silently agreeing with
#              whatever it was just changed to.
#
#              POSIX short flags on purpose: the compat CI legs run this suite
#              against macOS BSD coreutils, whose mkdir has no --parents.
# @arg $1 root directory to populate
function make_marker_fixture() {
  local -r root="$1"
  mkdir -p "${root}/hooks" "${root}/docs" "${root}/tests" "${root}/.ci"
  cat > "${root}/hooks/pgrep-pkill-guard.sh" << 'GUARD'
#!/usr/bin/env bash
# POSIX short flags, deliberately: BSD userland has no long options.
# The `||` is load-bearing beyond the obvious fallback: it keeps errexit out.
GUARD
  cat > "${root}/hooks/pgrep-pkill-guard-body.sh" << 'BODY'
# POSIX short flags, deliberately: the body ships to the same machines.
# The `||` is load-bearing beyond the obvious fallback, as above.
BODY
  cat > "${root}/tests/manifest.bats" << 'MANIFEST'
# POSIX short flags on purpose: the compat legs run against BSD coreutils.
MANIFEST
  cat > "${root}/.ci/check-fast-path-size" << 'SIZE'
# Assert the entry script stays under a hard ceiling of 200 lines.
SIZE
  cat > "${root}/docs/architecture.md" << 'ARCH'
## Design invariants

The doc has to carry every phrase too, since it is the place the rules are
written up: POSIX short flags, deliberately; the `||` being load-bearing
beyond the obvious fallback; POSIX short flags on purpose in the bats suite;
and the entry script staying under 200 lines.
ARCH
}

# Every case drives FIXTURE mode, which needs no devShell and no Nix -- only
# sed and tr, deliberately used in their POSIX form so the ambient macOS compat
# legs run this suite for real rather than skipping it. Hence no skip here, the
# same as tests/devshell-provides.bats and tests/issue-forms.bats.
#
# The first case is the exception that keeps the rest honest: it points the
# script at the real repo, so a fixture that has drifted away from the shape
# the tracked sources actually have cannot hide behind a green suite.

@test "invariant markers: the real repo passes" {
  # REPO_DIR explicitly rather than relying on the argument-less default: the
  # default resolves through `git rev-parse --show-toplevel`, and a bats test
  # must not depend on the directory the suite happened to be launched from.
  # The path taken is identical either way.
  run "${CHECK}" "${REPO_DIR}"
  assert_success
  assert_output --partial 'invariant markers present'
}

@test "invariant markers: a valid fixture passes" {
  local -r root="${BATS_TEST_TMPDIR}/ok"
  make_marker_fixture "${root}"
  run "${CHECK}" "${root}"
  assert_success
}

@test "invariant markers: a missing phrase is named, with its file" {
  local -r root="${BATS_TEST_TMPDIR}/missing"
  make_marker_fixture "${root}"
  # Drop the marker from the entry script only. The same phrase stays in the
  # body file, which is what makes this the interesting case: the check must
  # not be satisfied by the phrase existing SOMEWHERE in the repo.
  cat > "${root}/hooks/pgrep-pkill-guard.sh" << 'DROPPED'
#!/usr/bin/env bash
# The `||` is load-bearing beyond the obvious fallback: it keeps errexit out.
DROPPED
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'hooks/pgrep-pkill-guard.sh does not carry the invariant marker'
  assert_output --partial 'POSIX short flags, deliberately'
  # The body file still has it, so it must not be dragged into the verdict.
  refute_output --partial 'pgrep-pkill-guard-body.sh does not carry'
}

@test "invariant markers: a phrase wrapped across comment lines still counts" {
  # This is the #85 regression in miniature. The marker was present in
  # hooks/pgrep-pkill-guard.sh all along, wrapped across `POSIX short flags,`
  # and `# deliberately:`, and the grep the docs tell a reader to run found
  # only the body file. Collapsing line breaks and `#` continuations before the
  # search is what makes the gate agree with a human reading the comment.
  local -r root="${BATS_TEST_TMPDIR}/wrapped"
  make_marker_fixture "${root}"
  cat > "${root}/hooks/pgrep-pkill-guard.sh" << 'WRAPPED'
#!/usr/bin/env bash
  # Resolved relative to this script rather than via CLAUDE_CONFIG_DIR. POSIX short flags,
  # deliberately: macOS ships BSD userland, whose `dirname` has no long options.
  # The `||` is load-bearing beyond
  # the obvious fallback: it keeps errexit out.
WRAPPED

  # First prove the fixture really is wrapped -- otherwise this test could pass
  # against a matcher that does nothing at all.
  run grep -c 'POSIX short flags, deliberately' "${root}/hooks/pgrep-pkill-guard.sh"
  assert_failure
  run grep -c 'load-bearing beyond the obvious fallback' "${root}/hooks/pgrep-pkill-guard.sh"
  assert_failure

  run "${CHECK}" "${root}"
  assert_success
}

@test "invariant markers: a phrase broken mid-word does not count" {
  # The other side of the tolerance. Collapsing whitespace must not collapse the
  # words themselves: a comment that hyphenated its way across a line break no
  # longer contains the phrase, and saying otherwise would make the matcher
  # agree with text a reader's grep never will.
  local -r root="${BATS_TEST_TMPDIR}/mid-word"
  make_marker_fixture "${root}"
  cat > "${root}/hooks/pgrep-pkill-guard.sh" << 'BROKEN'
#!/usr/bin/env bash
# POSIX short flags, delib
# erately: BSD userland has no long options.
# The `||` is load-bearing beyond the obvious fallback: it keeps errexit out.
BROKEN
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'POSIX short flags, deliberately'
}

@test "invariant markers: a file the table names but the tree lacks is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/no-file"
  make_marker_fixture "${root}"
  rm -f "${root}/tests/manifest.bats"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'tests/manifest.bats is missing or unreadable'
}

@test "invariant markers: an empty file is reported as empty, not as missing a phrase" {
  # An empty read is never a clean pass, and it is not a missing comment either.
  # Reporting it as "phrase absent" would send the reader off to add a comment
  # to a file that is broken in a more interesting way.
  local -r root="${BATS_TEST_TMPDIR}/empty"
  make_marker_fixture "${root}"
  : > "${root}/.ci/check-fast-path-size"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial '.ci/check-fast-path-size read as empty'
  refute_output --partial 'does not carry the invariant marker'
}

@test "invariant markers: every offender is reported, not just the first" {
  # The gate aggregates rather than failing fast, the same way run-all-checks
  # does: one run should tell you everything that has to be restored.
  local -r root="${BATS_TEST_TMPDIR}/many"
  make_marker_fixture "${root}"
  printf '# nothing to see here\n' > "${root}/hooks/pgrep-pkill-guard.sh"
  printf '# nothing to see here either\n' > "${root}/tests/manifest.bats"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'hooks/pgrep-pkill-guard.sh does not carry the invariant marker'
  assert_output --partial 'tests/manifest.bats does not carry the invariant marker'
}
