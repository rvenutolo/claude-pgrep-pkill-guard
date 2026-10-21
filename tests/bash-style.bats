# .ci/check-bash-style itself, driven against fixture files written under
# BATS_TEST_TMPDIR: its failure paths, the exception markers, the canary, the
# order of its output and how it tells a sourced file from an executed one.
# Each rule's own cases are in the tests/bash-style-*.bats files.
#
# The fixtures hold shell source text as single-quoted strings: `${name}` and
# `$((...))` there are what the gate scans, never something to expand here.
# Double-quoting them would expand them in the test. Too many sites for per-site
# disables, so the directive is file-level, as in tests/scanner.bats.
#
# setup loads test_helper/common and test_helper/bash-style, which sets CHECK,
# the gate under test, and skips outside the devShell.
# shellcheck disable=SC2016 # file-level: the fixtures below are scanned source, not substitutions

function setup() {
  load 'test_helper/common'
  load 'test_helper/bash-style'
}

# @description Track a one-line script in a throwaway git repository, with the
#              tracked mode and the on-disk executable bit set independently.
# @arg $1 tracked_mode `+x` or `-x`: the mode git records
# @arg $2 disk_mode `+x` or `-x`: the bit left on the file
# @set REPO_ROOT the repository holding the file
function make_tracked_script() {
  local -r tracked_mode="$1"
  local -r disk_mode="$2"
  REPO_ROOT="${BATS_TEST_TMPDIR}/tracked"
  mkdir -p "${REPO_ROOT}"
  git -C "${REPO_ROOT}" init --quiet
  printf '%s\n' 'echo PAYLOAD_RAN' > "${REPO_ROOT}/t.sh"
  git -C "${REPO_ROOT}" add -- 't.sh'
  git -C "${REPO_ROOT}" update-index "--chmod=${tracked_mode}" -- 't.sh'
  chmod "${disk_mode}" "${REPO_ROOT}/t.sh"
}

# @description Build a directory holding only the named tools, as links to the
#              ones on PATH, so a test can run the gate with one tool missing.
# @arg $1 name directory name, created under BATS_TEST_TMPDIR
# @arg $@ tools the tools to link
# @set TOOL_DIR the directory holding the links
function make_tool_dir() {
  local -r name="$1"
  shift
  local tool
  TOOL_DIR="${BATS_TEST_TMPDIR}/${name}"
  mkdir -p "${TOOL_DIR}"
  for tool in "$@"; do
    ln -s "$(command -v "${tool}")" "${TOOL_DIR}/${tool}"
  done
}

# @description Put a shfmt on PATH that answers with the real tree after one
#              key in it is renamed, and assert the canary fails the gate.
# @arg $1 key the tree key to rename
function assert_canary_catches_renamed_key() {
  local -r key="$1"
  local -r shim_dir="${BATS_TEST_TMPDIR}/shim"
  local real_shfmt
  real_shfmt="$(command -v shfmt)"
  mkdir -p "${shim_dir}"
  printf '%s\n' '#!/usr/bin/env bash' \
    "${real_shfmt} \"\$@\" | sed -e 's/\"${key}\":/\"Renamed\":/g'" > "${shim_dir}/shfmt"
  chmod +x "${shim_dir}/shfmt"
  write_fixture 'clean.sh' 'echo PAYLOAD_RAN'
  PATH="${shim_dir}:${PATH}" run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  # Either verdict fails the gate: a rule that no longer fires, or a rule that
  # cannot read the tree at all.
  assert_output --regexp 'FAIL: the canary (did not trip|could not be scanned)'
  refute_output --partial 'ERROR: line'
}

# @description Assert a marker on the first line of a fixture excuses the
#              long-options hit on the second line and not the one on the
#              third.
# @arg $@ lines the fixture's lines after the marker
function assert_marker_stops_at_header() {
  write_fixture 'header.sh' '# bash-style allow=long-options: fixture reason' "$@"
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:3: [long-options]"
  refute_output --partial "${FIXTURE}:2: ["
  refute_output --partial '[marker-unused]'
}

@test "bash style: function-keyword passes a function defined with the keyword" {
  assert_passes 'kw.sh' '# @description Inert.' '# @noargs' 'function greet() {' '  echo PAYLOAD_RAN' '}'
}

@test "bash style: no-raw-tab reports a tab inside a heredoc body" {
  assert_fires 'hooks/heredoc.sh' 'no-raw-tab' 2 \
    "cat <<'EOF'" \
    "a$(printf '\t')b" \
    'EOF'
}

@test "bash style: no files is a failure, not a clean pass" {
  run "${CHECK}"
  assert_failure 1
  assert_output --partial 'FAIL: no files given'
}

@test "bash style: a clean file passes" {
  write_fixture 'clean.sh' \
    '# @description Inert.' '# @noargs' 'function greet() {' \
    '  echo PAYLOAD_RAN' \
    '}'
  run "${CHECK}" "${FIXTURE}"
  assert_success
  assert_output 'OK: 1 files pass the bash style gate'
}

@test "bash style: a file shfmt cannot parse is a failure" {
  write_fixture 'broken.sh' 'function greet() {'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE} could not be scanned"
}

@test "bash style: a bats file is parsed as bats" {
  write_fixture 'ok.bats' \
    '@test "inert" {' \
    '  echo PAYLOAD_RAN' \
    '}'
  run "${CHECK}" "${FIXTURE}"
  assert_success
}

@test "bash style: function-keyword names a function defined without the keyword" {
  write_fixture 'bare.sh' \
    'greet() {' \
    '  echo PAYLOAD_RAN' \
    '}'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:1: [function-keyword] define greet with the function keyword"
}

@test "bash style: no-raw-tab names the line holding a tab" {
  write_fixture 'tab.sh' \
    'echo PAYLOAD_RAN' \
    "echo 'a$(printf '\t')b'"
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:2: [no-raw-tab]"
}

@test "bash style: a marker on the same line excuses the violation" {
  write_fixture 'marked.sh' \
    '# @description Inert.' '# @noargs' \
    'greet() { # bash-style allow=function-keyword: fixture reason' \
    '  echo PAYLOAD_RAN' \
    '}'
  run "${CHECK}" "${FIXTURE}"
  assert_success
}

@test "bash style: a marker on the line above excuses the violation" {
  write_fixture 'above.sh' \
    '# @description Inert.' '# @noargs' \
    '# bash-style allow=function-keyword: fixture reason' \
    'greet() {' \
    '  echo PAYLOAD_RAN' \
    '}'
  run "${CHECK}" "${FIXTURE}"
  assert_success
}

@test "bash style: a marker covers every line of a multi-line statement" {
  write_fixture 'span.sh' \
    '# bash-style allow=no-raw-tab: fixture reason' \
    'echo PAYLOAD_RAN &&' \
    "  echo 'a$(printf '\t')b'"
  run "${CHECK}" "${FIXTURE}"
  assert_success
}

@test "bash style: a marker above a function header does not reach into the body" {
  write_fixture 'wide.sh' \
    '# @description Inert.' '# @noargs' \
    '# bash-style allow=long-options: fixture reason' \
    'function wide() {' \
    "  grep -q 'x' 'file'" \
    '}'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:5: [long-options]"
  assert_output --partial "FAIL: ${FIXTURE}:3: [marker-unused]"
}

@test "bash style: a marker above a case covers the header and not an arm" {
  write_fixture 'header.sh' \
    '# bash-style allow=long-options: fixture reason' \
    'case "$(some_tool -s)" in' \
    "  x) grep -q 'x' 'file' ;;" \
    'esac'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:3: [long-options]"
  refute_output --partial "${FIXTURE}:2: ["
  refute_output --partial '[marker-unused]'
}

@test "bash style: a marker above an if or a loop covers the condition and not the body" {
  assert_marker_stops_at_header 'if some_tool -s; then' "  grep -q 'x' 'file'" 'fi'
  assert_marker_stops_at_header 'while some_tool -s; do' "  grep -q 'x' 'file'" 'done'
  assert_marker_stops_at_header 'until some_tool -s; do' "  grep -q 'x' 'file'" 'done'
  assert_marker_stops_at_header 'for item in "$(some_tool -s)"; do' "  grep -q 'x' 'file'" 'done'
}

@test "bash style: a marker above a block, a subshell, a test or a case arm covers only its first line" {
  assert_marker_stops_at_header '{ some_tool -s &&' "  grep -q 'x' 'file'; }"
  assert_marker_stops_at_header '(some_tool -s &&' "  grep -q 'x' 'file')"
  write_fixture 'header.bats' \
    '# bash-style allow=long-options: fixture reason' \
    '@test "inert" {' \
    "  grep -q 'x' 'file'" \
    '}'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:3: [long-options]"
  assert_output --partial "FAIL: ${FIXTURE}:1: [marker-unused]"
  write_fixture 'arm.sh' \
    'case x in' \
    '  # bash-style allow=long-options: fixture reason' \
    '  x)' \
    "    grep -q 'x' 'file'" \
    '    ;;' \
    'esac'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:4: [long-options]"
  assert_output --partial "FAIL: ${FIXTURE}:2: [marker-unused]"
}

@test "bash style: a marker does not reach the next statement" {
  write_fixture 'next.sh' \
    'echo PAYLOAD_RAN # bash-style allow=function-keyword: fixture reason' \
    'greet() {' \
    '  echo PAYLOAD_RAN' \
    '}'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:2: [function-keyword]"
  assert_output --partial "FAIL: ${FIXTURE}:1: [marker-unused]"
}

@test "bash style: a marker for another rule does not excuse this one" {
  write_fixture 'other.sh' \
    'greet() { # bash-style allow=no-raw-tab: fixture reason' \
    '  echo PAYLOAD_RAN' \
    '}'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:1: [function-keyword]"
  assert_output --partial "FAIL: ${FIXTURE}:1: [marker-unused]"
}

@test "bash style: a marker with no reason is a violation" {
  write_fixture 'noreason.sh' \
    'greet() { # bash-style allow=function-keyword:' \
    '  echo PAYLOAD_RAN' \
    '}'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:1: [marker-no-reason]"
}

@test "bash style: a marker naming an unknown rule is a violation" {
  write_fixture 'unknown.sh' \
    'echo PAYLOAD_RAN # bash-style allow=no-such-rule: fixture reason'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:1: [marker-unknown-rule] no rule is named \"no-such-rule\""
}

@test "bash style: a marker after the last statement of a file is reported when stale" {
  write_fixture 'last.sh' \
    'echo PAYLOAD_RAN' \
    '# bash-style allow=function-keyword: fixture reason'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:2: [marker-unused]"
}

@test "bash style: a marker with no colon after the rule id is malformed" {
  write_fixture 'nocolon.sh' \
    'greet() { # bash-style allow=function-keyword fixture reason' \
    '  echo PAYLOAD_RAN' \
    '}'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:1: [marker-malformed] write # bash-style allow=<rule-id>: <reason>"
}

@test "bash style: a bash-style comment that is not an allow marker is malformed" {
  write_fixture 'other-form.sh' \
    'echo PAYLOAD_RAN # bash-style something-else'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:1: [marker-malformed]"
  assert_fires 'bare.sh' 'marker-malformed' 1 'echo PAYLOAD_RAN # bash-style'
}

@test "bash style: two markers in one comment excuse two rules" {
  local -r first='# bash-style allow=single-quote-literals: fixture reason'
  local -r second='# bash-style allow=quote-literal-path: another reason'
  assert_passes 'two.sh' "echo \"PAYLOAD_RAN\" /etc/os-release ${first} ${second}"
}

@test "bash style: each marker in one comment is judged alone" {
  local -r first='# bash-style allow=single-quote-literals: fixture reason'
  assert_fires 'two.sh' 'marker-malformed' 1 "echo \"PAYLOAD_RAN\" ${first} # bash-style allow=no-colon"
  refute_output --partial '[single-quote-literals]'
  assert_fires 'two.sh' 'marker-no-reason' 1 "echo \"PAYLOAD_RAN\" ${first} # bash-style allow=no-raw-tab:"
  assert_fires 'two.sh' 'marker-unused' 1 "echo \"PAYLOAD_RAN\" ${first} # bash-style allow=no-raw-tab: unused"
  assert_output --partial 'nothing here violates no-raw-tab'
  refute_output --partial '[single-quote-literals]'
}

@test "bash style: a marker that excuses nothing is a violation" {
  write_fixture 'stale.sh' \
    'echo PAYLOAD_RAN # bash-style allow=function-keyword: fixture reason'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:1: [marker-unused]"
}

@test "bash style: every failing file is reported, and the verdict counts them" {
  write_fixture 'one.sh' 'one() { echo PAYLOAD_RAN; }'
  local -r first="${FIXTURE}"
  write_fixture 'two.sh' 'two() { echo PAYLOAD_RAN; }'
  run "${CHECK}" "${first}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${first}:1: [function-keyword]"
  assert_output --partial "FAIL: ${FIXTURE}:1: [function-keyword]"
  assert_output --partial 'FAIL: 2 of 2 files break the bash style rules'
}

@test "bash style: the files are reported in argument order, whichever scan ends first" {
  local -a filler=()
  mapfile -t filler < <(printf 'echo PAYLOAD_RAN %s\n' {1..400})
  write_fixture 'slow.sh' "${filler[@]}" 'echo "PAYLOAD_RAN"'
  local -r slow="${FIXTURE}"
  write_fixture 'quick.sh' 'echo "PAYLOAD_RAN"'
  local -r quick="${FIXTURE}"
  run "${CHECK}" "${slow}" "${quick}"
  assert_failure 1
  assert_line --index 0 --partial "FAIL: ${slow}:401: [single-quote-literals]"
  assert_line --index 1 --partial "FAIL: ${quick}:1: [single-quote-literals]"
  assert_line --index 2 'FAIL: 2 of 2 files break the bash style rules'
  run "${CHECK}" "${quick}" "${slow}"
  assert_failure 1
  assert_line --index 0 --partial "FAIL: ${quick}:1: [single-quote-literals]"
  assert_line --index 1 --partial "FAIL: ${slow}:401: [single-quote-literals]"
}

@test "bash style: the parser's complaint about a file stays with that file's lines" {
  write_fixture 'one.sh' 'echo "PAYLOAD_RAN"'
  local -r first="${FIXTURE}"
  write_fixture 'broken.sh' 'function greet() {'
  local -r broken="${FIXTURE}"
  write_fixture 'two.sh' 'echo "PAYLOAD_RAN"'
  run "${CHECK}" "${first}" "${broken}" "${FIXTURE}"
  assert_failure 1
  assert_line --index 0 --partial "FAIL: ${first}:1: [single-quote-literals]"
  assert_line --index 1 --partial "${broken}:1:"
  assert_line --index 2 "FAIL: ${broken} could not be scanned"
  assert_line --index 3 --partial "FAIL: ${FIXTURE}:1: [single-quote-literals]"
  assert_line --index 4 'FAIL: 3 of 3 files break the bash style rules'
}

@test "bash style: the gate leaves nothing behind in the temporary directory" {
  local -r scratch="${BATS_TEST_TMPDIR}/scratch"
  mkdir -p "${scratch}"
  write_fixture 'one.sh' 'echo "PAYLOAD_RAN"'
  TMPDIR="${scratch}" run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  run find "${scratch}" -mindepth 1
  assert_output ''
}

@test "bash style: a shfmt that answers with another tree shape fails the canary" {
  local -r shim_dir="${BATS_TEST_TMPDIR}/shim"
  mkdir -p "${shim_dir}"
  # The shim drains stdin first: one that exits unread can break the gate's
  # pipe into it, and the gate then reports "could not be scanned" instead of
  # the verdict this test asserts.
  printf '%s\n' '#!/usr/bin/env bash' 'cat > /dev/null' "printf '{\"Type\":\"File\"}\n'" > "${shim_dir}/shfmt"
  chmod +x "${shim_dir}/shfmt"
  write_fixture 'clean.sh' 'echo PAYLOAD_RAN'
  PATH="${shim_dir}:${PATH}" run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial 'FAIL: the canary did not trip function-keyword'
}

@test "bash style: the canary catches a rename of each tree key its rules read" {
  local key
  for key in 'Type' 'Stmts' 'Cmd' 'Args' 'Assigns' 'Parts' 'Value' 'Name' 'Param' 'Exp' 'Index' 'Op' 'X' 'Y' \
    'Redirs' 'Word' 'Items' 'Loop' 'Then' 'Do' 'Rbrace' 'Body' 'Variant' 'Comments' 'Hash' 'Text' 'Pos' 'Line'; do
    assert_canary_catches_renamed_key "${key}"
  done
}

@test "bash style: a jq that stops reporting the text rule fails the canary" {
  local -r shim_dir="${BATS_TEST_TMPDIR}/shim"
  local real_jq
  real_jq="$(command -v jq)"
  mkdir -p "${shim_dir}"
  printf '%s\n' '#!/usr/bin/env bash' \
    "${real_jq} \"\$@\" | grep --invert-match 'no-raw-tab'" \
    'exit 0' > "${shim_dir}/jq"
  chmod +x "${shim_dir}/jq"
  write_fixture 'clean.sh' 'echo PAYLOAD_RAN'
  PATH="${shim_dir}:${PATH}" run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial 'FAIL: the canary did not trip no-raw-tab'
  refute_output --partial 'ERROR: line'
}

@test "bash style: a shfmt that fails on the canary is a verdict, not a crash" {
  local -r shim_dir="${BATS_TEST_TMPDIR}/shim"
  mkdir -p "${shim_dir}"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "${shim_dir}/shfmt"
  chmod +x "${shim_dir}/shfmt"
  write_fixture 'clean.sh' 'echo PAYLOAD_RAN'
  PATH="${shim_dir}:${PATH}" run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial 'FAIL: the canary could not be scanned'
  refute_output --partial 'ERROR: line'
}

@test "bash style: a missing shfmt or jq is exit 2, before anything is scanned" {
  write_fixture 'clean.sh' 'echo PAYLOAD_RAN'
  # bash and dirname are what the gate needs to reach its tool check.
  make_tool_dir 'no-shfmt' 'bash' 'dirname' 'jq'
  run env PATH="${TOOL_DIR}" "${CHECK}" "${FIXTURE}"
  assert_failure 2
  assert_output 'FAIL: shfmt is not on PATH; run this gate through .ci/in-devshell'
  make_tool_dir 'no-jq' 'bash' 'dirname' 'shfmt'
  run env PATH="${TOOL_DIR}" "${CHECK}" "${FIXTURE}"
  assert_failure 2
  assert_output 'FAIL: jq is not on PATH; run this gate through .ci/in-devshell'
}

@test "bash style: a file tracked 100755 is executed even when its on-disk bit is clear" {
  make_tracked_script '+x' '-x'
  cd "${REPO_ROOT}"
  run "${CHECK}" 't.sh'
  assert_failure 1
  assert_output --partial 't.sh:1: [strict-prologue]'
}

@test "bash style: a file tracked 100644 is sourced even when its on-disk bit is set" {
  make_tracked_script '-x' '+x'
  cd "${REPO_ROOT}"
  run "${CHECK}" 't.sh'
  assert_success
}

@test "bash style: the tracked mode is read from the file's own repository, wherever the gate is run from" {
  make_tracked_script '+x' '-x'
  cd "${BATS_TEST_TMPDIR}"
  run "${CHECK}" "${REPO_ROOT}/t.sh"
  assert_failure 1
  assert_output --partial 't.sh:1: [strict-prologue]'
  make_tracked_script '-x' '+x'
  run "${CHECK}" "${REPO_ROOT}/t.sh"
  assert_success
}

@test "bash style: a git that cannot list the repository is a verdict, not a crash" {
  local -r shim_dir="${BATS_TEST_TMPDIR}/shim"
  local real_git
  real_git="$(command -v git)"
  mkdir -p "${shim_dir}"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  *ls-files*) exit 1 ;;' \
    'esac' \
    "exec ${real_git} \"\$@\"" > "${shim_dir}/git"
  chmod +x "${shim_dir}/git"
  write_fixture 'clean.sh' 'echo PAYLOAD_RAN'
  PATH="${shim_dir}:${PATH}" run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial 'FAIL: could not list the files git tracks'
  refute_output --partial 'ERROR: line'
}

@test "bash style: a git grep that fails is a verdict, not a crash" {
  local -r shim_dir="${BATS_TEST_TMPDIR}/shim"
  local real_git
  real_git="$(command -v git)"
  mkdir -p "${shim_dir}"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  *" grep "*) exit 128 ;;' \
    'esac' \
    "exec ${real_git} \"\$@\"" > "${shim_dir}/git"
  chmod +x "${shim_dir}/git"
  write_fixture 'clean.sh' 'echo PAYLOAD_RAN'
  PATH="${shim_dir}:${PATH}" run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial 'FAIL: could not search the repository for function definitions'
  refute_output --partial 'ERROR: line'
}
