#!/usr/bin/env bash

# Shared setup and fixture helpers for tests/bash-style.bats and the
# tests/bash-style-*.bats files, which drive .ci/check-bash-style. Every case
# starts the gate, so its cases are spread over several files that run-tests'
# file pool runs side by side rather than one file that runs them in turn.
# Each of those files' setup() does: load 'test_helper/common', then
# load 'test_helper/bash-style'.
#
# Globals set:
#   CHECK — absolute path to the gate under test
#
# Skips the test outside the devShell, before the test body runs.

CHECK="${REPO_DIR}/.ci/check-bash-style"
# The gate reads a syntax tree whose shape belongs to the shfmt the flake
# pins, so only the devShell legs grade it. .ci/in-devshell exports
# IN_DEVSHELL; the ambient compat legs do not have it.
if [[ -z "${IN_DEVSHELL:-}" ]]; then
  skip 'not in the devShell; the bash style gate is graded by the hermetic gate leg'
fi

# @description Write one fixture file holding the lines given, each an inert
#              statement: nothing in a fixture is ever executed.
# @arg $1 name file name, created under BATS_TEST_TMPDIR
# @arg $@ lines the file's lines, in order
# @set FIXTURE the absolute path of the file written
function write_fixture() {
  local -r name="$1"
  shift
  FIXTURE="${BATS_TEST_TMPDIR}/${name}"
  printf '%s\n' "$@" > "${FIXTURE}"
}

# @description Write a fixture and set its executable bit, so the gate treats
#              it as an executed script. Nothing ever runs it.
# @arg $1 name file name, created under BATS_TEST_TMPDIR
# @arg $@ lines the file's lines, in order
# @set FIXTURE the absolute path of the file written
function write_script() {
  write_fixture "$@"
  chmod +x "${FIXTURE}"
}

# @description Assert the gate reports one rule at one line of a fixture.
# @arg $1 name fixture file name; its directory part scopes path-based rules
# @arg $2 rule the rule id expected in the FAIL line
# @arg $3 line the line number expected in the FAIL line
# @arg $@ lines the fixture's lines
function assert_fires() {
  local -r name="$1"
  local -r rule="$2"
  local -r line="$3"
  shift 3
  mkdir -p "${BATS_TEST_TMPDIR}/$(dirname -- "${name}")"
  write_fixture "${name}" "$@"
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:${line}: [${rule}]"
}

# @description Assert the gate passes a fixture.
# @arg $1 name fixture file name; its directory part scopes path-based rules
# @arg $@ lines the fixture's lines
function assert_passes() {
  local -r name="$1"
  shift
  mkdir -p "${BATS_TEST_TMPDIR}/$(dirname -- "${name}")"
  write_fixture "${name}" "$@"
  run "${CHECK}" "${FIXTURE}"
  assert_success
}
