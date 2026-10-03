# The fixtures hold shell source text as single-quoted strings: `${name}` and
# `$((...))` there are what the gate scans, never something to expand here.
# Double-quoting them would expand them in the test. Too many sites for per-site
# disables, so the directive is file-level, as in tests/scanner.bats.
# shellcheck disable=SC2016 # file-level: the fixtures below are scanned source, not substitutions

function setup() {
  load 'test_helper/common'
  CHECK="${REPO_DIR}/.ci/check-bash-style"
  # The gate reads a syntax tree whose shape belongs to the shfmt the flake
  # pins, so only the devShell legs grade it. .ci/in-devshell exports
  # IN_DEVSHELL; the ambient compat legs do not have it.
  if [[ -z "${IN_DEVSHELL:-}" ]]; then
    skip 'not in the devShell; the bash style gate is graded by the hermetic gate leg'
  fi
}

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

@test "bash style: function-keyword passes a function defined with the keyword" {
  assert_passes 'kw.sh' 'function greet() {' '  echo PAYLOAD_RAN' '}'
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
    'function greet() {' \
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
    'greet() { # bash-style allow=function-keyword: fixture reason' \
    '  echo PAYLOAD_RAN' \
    '}'
  run "${CHECK}" "${FIXTURE}"
  assert_success
}

@test "bash style: a marker on the line above excuses the violation" {
  write_fixture 'above.sh' \
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

@test "bash style: a shfmt that answers with another tree shape fails the canary" {
  local -r shim_dir="${BATS_TEST_TMPDIR}/shim"
  mkdir -p "${shim_dir}"
  printf '%s\n' '#!/usr/bin/env bash' "printf '{\"Type\":\"File\"}\n'" > "${shim_dir}/shfmt"
  chmod +x "${shim_dir}/shfmt"
  write_fixture 'clean.sh' 'echo PAYLOAD_RAN'
  PATH="${shim_dir}:${PATH}" run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial 'FAIL: the canary did not trip function-keyword'
}

@test "bash style: quote-expansions reports an unquoted expansion as an argument" {
  assert_fires 'q.sh' 'quote-expansions' 2 'name=x' 'echo ${name}'
}

@test "bash style: quote-expansions reports an unquoted expansion in an assignment, a case word and a test operand" {
  assert_fires 'q.sh' 'quote-expansions' 2 'name=x' 'other=${name}'
  assert_fires 'q.sh' 'quote-expansions' 2 'name=x' 'case ${name} in x) echo PAYLOAD_RAN ;; esac'
  assert_fires 'q.sh' 'quote-expansions' 2 'name=x' '[[ -n ${name} ]] && echo PAYLOAD_RAN'
}

@test "bash style: quote-expansions passes quoted expansions, arithmetic and the integer specials" {
  assert_passes 'q.sh' 'name=x' 'echo "${name}" "$#" $? $$ $!' 'echo "$((name + 1))"' '((name > 0)) && echo PAYLOAD_RAN'
}

@test "bash style: quote-expansions leaves the right-hand side of =~, == and != alone" {
  assert_passes 'q.sh' 're=x' \
    '[[ "${re}" =~ ${re} ]] && echo PAYLOAD_RAN' \
    '# shellcheck disable=SC2053 # fixture: a glob on purpose' \
    '[[ "${re}" == ${re} ]] && echo PAYLOAD_RAN'
}

@test "bash style: single-quote-literals reports a double-quoted string with nothing to expand" {
  assert_fires 'l.sh' 'single-quote-literals' 1 'echo "PAYLOAD_RAN"'
}

@test "bash style: single-quote-literals passes expansion, an apostrophe, a backslash and a test name" {
  assert_passes 'l.sh' 'name=x' 'echo "${name} ran"' "echo \"it's inert\"" 'printf "a\nb"'
  assert_passes 'l.bats' '@test "inert name" {' '  echo PAYLOAD_RAN' '}'
}

@test "bash style: quote-literal-path reports a bare path argument" {
  assert_fires 'p.sh' 'quote-literal-path' 1 'some_command /etc/os-release'
  assert_fires 'p.sh' 'quote-literal-path' 1 'some_command ./relative'
}

@test "bash style: quote-literal-path passes a quoted path and a bare redirect target" {
  assert_passes 'p.sh' "some_command '/etc/os-release' 2> /dev/null < /proc/loadavg"
}

@test "bash style: quote-subst-in-assign reports a bare command or arithmetic substitution" {
  assert_fires 's.sh' 'quote-subst-in-assign' 1 'count=$((1 + 1))'
  assert_fires 's.sh' 'quote-subst-in-assign' 1 'now=$(some_command)'
}

@test "bash style: quote-subst-in-assign passes the quoted forms" {
  assert_passes 's.sh' 'count="$((1 + 1))"' 'now="$(some_command)"'
}
