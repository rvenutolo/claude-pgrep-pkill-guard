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

@test "bash style: unquoted-numeric-opt reports a quoted number as an option value" {
  assert_fires 'n.sh' 'unquoted-numeric-opt' 1 "some_command --fields='1'"
}

@test "bash style: unquoted-numeric-opt passes a bare number and a quoted word" {
  assert_passes 'n.sh' "some_command --fields=1 --delimiter=','"
}

@test "bash style: no-braces-in-arith reports a braced name in arithmetic and in an indexed subscript" {
  assert_fires 'a.sh' 'no-braces-in-arith' 2 'count=1' 'echo "$((${count} + 1))"'
  assert_fires 'a.sh' 'no-braces-in-arith' 3 'i=0' 'items=(a b)' 'echo "${items[${i}]}"'
}

@test "bash style: no-braces-in-arith passes bare names, lengths, operators, nested substitutions and associative keys" {
  assert_passes 'a.sh' 'count=1' 'items=(a b)' \
    'echo "$((count + ${#items[@]}))"' \
    'echo "$((10#${count/./} - 1))"' \
    'echo "$(($(some_command "${count}") / 1000))"'
  assert_passes 'a.sh' 'key=x' 'declare -A seen=()' 'seen["${key}"]=1' 'echo "${seen[${key}]}"'
}

@test "bash style: quote-heredoc-terminator reports a bare terminator over a body with nothing to expand" {
  assert_fires 'h.sh' 'quote-heredoc-terminator' 1 'cat <<EOF' 'PAYLOAD_RAN' 'EOF'
}

@test "bash style: quote-heredoc-terminator passes a quoted terminator and a body that expands" {
  assert_passes 'h.sh' "cat <<'EOF'" 'PAYLOAD_RAN' 'EOF'
  assert_passes 'h.sh' 'name=x' 'cat <<EOF' '${name}' 'EOF'
}

@test "bash style: quote-literal-path passes a glob path, which quoting would break" {
  assert_passes 'p.sh' 'some_command ./*' 'some_command /tmp/*.log'
}

@test "bash style: no-braces-in-arith passes a braced name after a base prefix" {
  assert_passes 'a.sh' 'count=08' 'echo "$((10#${count} + 1))"'
}

@test "bash style: quote-heredoc-terminator passes a backslash-quoted terminator" {
  assert_passes 'h.sh' 'cat <<\EOF' 'PAYLOAD_RAN' 'EOF'
}

@test "bash style: quote-heredoc-terminator passes a body whose backslash escapes quoting would change" {
  assert_passes 'h.sh' 'cat <<EOF' 'cost \$5' 'EOF'
  assert_passes 'h.sh' 'cat <<EOF' 'a\\b' 'EOF'
}

@test "bash style: quote-expansions reports an unquoted expansion inside a command substitution inside double quotes" {
  assert_fires 'q.sh' 'quote-expansions' 2 'path=x' 'echo "$(some_command ${path})"'
}

@test "bash style: quote-expansions passes a quoted expansion inside a command substitution inside double quotes" {
  assert_passes 'q.sh' 'path=x' 'echo "$(some_command "${path}")"'
}

@test "bash style: quote-expansions passes a heredoc body that expands, a C-style for header and an associative subscript" {
  assert_passes 'q.sh' 'name=x' 'cat <<EOF' '${name}' 'EOF'
  assert_passes 'q.sh' 'items=(a b)' 'for ((i = 0; i < ${#items[@]}; i++)); do echo PAYLOAD_RAN; done'
  assert_passes 'q.sh' 'key=x' 'declare -A seen=()' 'echo "${seen[${key}]}"'
}

@test "bash style: no-braces-in-arith reports a braced name in an indexed assignment subscript" {
  assert_fires 'a.sh' 'no-braces-in-arith' 3 'i=0' 'items=(a b)' 'items[${i}]=1'
}

@test "bash style: long-options reports a short flag on a tool that has a long form" {
  assert_fires 'o.sh' 'long-options' 1 "grep -q 'x' 'file'"
  assert_fires 'o.sh' 'long-options' 1 "git commit -q -m 'x'"
}

@test "bash style: long-options sees through wrappers to the real command" {
  assert_fires 'o.bats' 'long-options' 2 '@test "inert" {' "  run grep -q 'x' 'file'" '}'
  assert_fires 'o.sh' 'long-options' 1 "env LC_ALL=C timeout 30m sort -u 'file'"
}

@test "bash style: long-options passes long forms, builtins and tools with no long form" {
  assert_passes 'o.sh' \
    "grep --quiet 'x' 'file'" \
    'read -r line' \
    'set -Eeuo pipefail' \
    'command -v some_command' \
    "git -C 'dir' status" \
    "find 'dir' -name 'x' -print" \
    "awk -f 'prog.awk' 'file'"
}

@test "bash style: long-options leaves flags that are data alone" {
  # A flag handed to a function defined in the file, or to a command held in a
  # variable, is input for the thing under test.
  assert_passes 'o.sh' 'function run_cli() {' '  echo PAYLOAD_RAN' '}' 'run_cli -h'
  assert_passes 'o.sh' 'tool=some_command' '"${tool}" -h'
  assert_passes 'o.sh' 'some_command -- -x'
  assert_passes 'o.sh' "echo 'rm -f inert-string'" "cat <<'EOF'" 'grep -q x' 'EOF'
}

@test "bash style: long-options allows the macOS short flags only under hooks/ and tests/" {
  assert_passes 'hooks/o.sh' "mkdir -p 'dir'" "rm -f -- 'file'"
  assert_passes 'tests/o.bats' '@test "inert" {' "  mkdir -p 'dir'" '}'
  assert_fires 'o.sh' 'long-options' 1 "mkdir -p 'dir'"
  assert_fires 'hooks/o.sh' 'long-options' 1 "grep -q 'x' 'file'"
}

@test "bash style: long-options passes the tools and builtins that have no long form" {
  assert_passes 'o.sh' \
    "test -f 'file'" \
    "bash -c 'echo PAYLOAD_RAN'" \
    'hash -r' \
    'alias -p' \
    "getopts 'ab' opt"
}

@test "bash style: long-options skips the value a wrapper's own short flag takes" {
  assert_passes 'o.sh' "env -u SOME_NAME awk -f 'prog.awk'"
  assert_passes 'o.sh' 'name=x' "env -u \"\${name}\" awk -f 'prog.awk'"
  assert_passes 'o.sh' "timeout -k 5 30 awk -f 'prog.awk'"
  assert_fires 'o.sh' 'long-options' 1 'env -u SOME_NAME grep -q x'
}

@test "bash style: double-dash-before-paths reports rm, mv and cp without --" {
  assert_fires 'd.sh' 'double-dash-before-paths' 1 "rm --force 'file'"
  assert_fires 'd.sh' 'double-dash-before-paths' 1 "mv 'a' 'b'"
  assert_passes 'd.sh' "rm --force -- 'file'" "cp -- 'a' 'b'"
}
