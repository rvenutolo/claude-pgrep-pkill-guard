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

# @description Write a fixture and set its executable bit, so the gate treats
#              it as an executed script. Nothing ever runs it.
# @arg $1 name file name, created under BATS_TEST_TMPDIR
# @arg $@ lines the file's lines, in order
# @set FIXTURE the absolute path of the file written
function write_script() {
  write_fixture "$@"
  chmod +x "${FIXTURE}"
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
  assert_passes 'o.sh' '# @description Inert.' '# @noargs' 'function run_cli() {' '  echo PAYLOAD_RAN' '}' 'run_cli -h'
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
    'unalias -a' \
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

@test "bash style: xargs-flags reports xargs without both flags" {
  assert_fires 'x.sh' 'xargs-flags' 1 'some_command | xargs --max-args=1 other_command'
  assert_fires 'x.sh' 'xargs-flags' 1 'some_command | xargs --no-run-if-empty other_command'
  assert_passes 'x.sh' 'some_command | xargs --no-run-if-empty --max-args=1 other_command'
}

@test "bash style: no-echo-e reports echo -e" {
  assert_fires 'e.sh' 'no-echo-e' 1 "echo -e 'PAYLOAD_RAN'"
  assert_passes 'e.sh' "echo 'PAYLOAD_RAN'" "printf '%s\n' 'PAYLOAD_RAN'"
}

@test "bash style: no-echo-e reports -e after another echo option" {
  assert_fires 'e.sh' 'no-echo-e' 1 "echo -n -e 'PAYLOAD_RAN'"
  assert_fires 'e.sh' 'no-echo-e' 1 "echo -ne 'PAYLOAD_RAN'"
  assert_passes 'e.sh' "echo -n 'PAYLOAD_RAN'" "echo 'PAYLOAD_RAN' -e"
}

@test "bash style: fetch-flags reports curl and wget that read the user's config" {
  assert_fires 'f.sh' 'fetch-flags' 1 "curl --silent 'https://example.invalid/'"
  assert_fires 'f.sh' 'fetch-flags' 1 "wget 'https://example.invalid/'"
  assert_passes 'f.sh' \
    "curl --disable --fail --silent --location --show-error 'https://example.invalid/'" \
    "wget --no-config 'https://example.invalid/'"
}

@test "bash style: fetch-flags passes a lookup of curl or wget, which fetches nothing" {
  assert_passes 'f.sh' 'command -v curl' 'command -v wget > /dev/null'
}

@test "bash style: long-options passes every builtin, which has no long form" {
  assert_passes 'o.sh' \
    'readarray -t arr < <(some_command)' \
    "compgen -W 'a b' -- 'x'" \
    'jobs -p' \
    'builtin cd -P' \
    'fc -l' \
    'help -s cd' \
    'history -c' \
    'disown -h' \
    'complete -r' \
    'compopt -o nospace' \
    'bind -l' \
    'enable -n test' \
    'caller 0' \
    'dirs -v' \
    'times'
}

@test "bash style: long-options reads a negative number as an argument, except for head and tail" {
  assert_passes 'o.sh' 'sleep -1' 'sleep -0.5'
  assert_fires 'o.sh' 'long-options' 1 "head -5 'file'"
  assert_fires 'o.sh' 'long-options' 1 "tail -20 'file'"
}

@test "bash style: long-options gives each wrapper its own value-taking flags" {
  assert_fires 'o.sh' 'long-options' 1 "sudo -n grep -q 'x' 'file'"
  assert_passes 'o.sh' "nice -n 5 grep --quiet 'x' 'file'"
  assert_fires 'o.sh' 'long-options' 1 "nice -n 5 grep -q 'x' 'file'"
  assert_passes 'o.sh' "sudo -u root awk -f 'prog.awk'"
  assert_passes 'o.sh' "timeout -k 5 30 awk -f 'prog.awk'"
}

@test "bash style: test-double-equals reports = inside [[ ]]" {
  assert_fires 't.sh' 'test-double-equals' 1 "[[ 'a' = 'b' ]] && echo PAYLOAD_RAN"
  assert_passes 't.sh' "[[ 'a' == 'b' ]] && echo PAYLOAD_RAN"
}

@test "bash style: empty-string-test reports a comparison against the empty string" {
  assert_fires 't.sh' 'empty-string-test' 2 'name=x' "[[ \"\${name}\" == '' ]] && echo PAYLOAD_RAN"
  assert_fires 't.sh' 'empty-string-test' 2 'name=x' "[[ \"\${name}\" != \"\" ]] && echo PAYLOAD_RAN"
  assert_passes 't.sh' 'name=x' '[[ -z "${name}" ]] && echo PAYLOAD_RAN'
}

@test "bash style: empty-string-test sees the empty string on the left" {
  assert_fires 't.sh' 'empty-string-test' 2 'name=x' "[[ '' == \"\${name}\" ]] && echo PAYLOAD_RAN"
}

@test "bash style: empty-string-test passes a string that is not empty" {
  assert_passes 't.sh' 'name=x' \
    "[[ \"\${name}\" == ' ' ]] && echo PAYLOAD_RAN" \
    '[[ "${name}" == "${name}" ]] && echo PAYLOAD_RAN'
}

@test "bash style: no-lexical-compare reports < and > inside [[ ]]" {
  assert_fires 't.sh' 'no-lexical-compare' 1 '[[ 1 < 2 ]] && echo PAYLOAD_RAN'
  assert_fires 't.sh' 'no-lexical-compare' 1 '[[ 1 > 2 ]] && echo PAYLOAD_RAN'
  assert_passes 't.sh' '((1 < 2)) && echo PAYLOAD_RAN'
}

@test "bash style: no-one-line-case reports a case squeezed onto one line" {
  assert_fires 't.sh' 'no-one-line-case' 1 'case x in x) echo PAYLOAD_RAN ;; esac'
  assert_passes 't.sh' 'case x in' '  x) echo PAYLOAD_RAN ;;' 'esac'
}

@test "bash style: no-one-line-case reports a one-line case inside a one-line function" {
  assert_fires 't.sh' 'no-one-line-case' 3 \
    '# @description Inert.' '# @noargs' 'function f() { case x in x) echo PAYLOAD_RAN ;; esac; }'
}

@test "bash style: no-one-line-case passes an expanded case inside a function" {
  assert_passes 't.sh' \
    '# @description Inert.' '# @noargs' 'function f() {' '  case x in' '    x) echo PAYLOAD_RAN ;;' '  esac' '}'
}

@test "bash style: no-fallthrough reports ;& and ;;&" {
  assert_fires 't.sh' 'no-fallthrough' 2 'case x in' '  x) echo PAYLOAD_RAN ;&' '  y) echo PAYLOAD_RAN ;;' 'esac'
  assert_fires 't.sh' 'no-fallthrough' 2 'case x in' '  x) echo PAYLOAD_RAN ;;&' '  y) echo PAYLOAD_RAN ;;' 'esac'
}

@test "bash style: no-fallthrough passes a case that ends every arm with ;;" {
  assert_passes 't.sh' 'case x in' '  x) echo PAYLOAD_RAN ;;' '  y) echo PAYLOAD_RAN ;;' 'esac'
}

@test "bash style: no-fallthrough passes a last arm with no terminator" {
  assert_passes 't.sh' 'case x in' '  x) echo PAYLOAD_RAN ;;' '  y) echo PAYLOAD_RAN' 'esac'
}

@test "bash style: explicit-for-in reports the implicit positional loop" {
  assert_fires 't.sh' 'explicit-for-in' 1 'for arg; do' '  echo PAYLOAD_RAN' 'done'
  assert_passes 't.sh' 'for arg in "$@"; do' '  echo PAYLOAD_RAN' 'done'
}

@test "bash style: explicit-for-in reports the implicit loop inside a function" {
  assert_fires 't.sh' 'explicit-for-in' 4 \
    '# @description Inert.' '# @noargs' 'function f() {' '  for arg; do' '    echo PAYLOAD_RAN' '  done' '}'
}

@test "bash style: no-for-in-subst reports a loop over a command substitution" {
  assert_fires 't.sh' 'no-for-in-subst' 1 'for line in $(some_command); do' '  echo PAYLOAD_RAN' 'done'
}

@test "bash style: no-for-in-subst reports a substitution mixed with other words" {
  assert_fires 't.sh' 'no-for-in-subst' 1 "for line in 'first' \$(some_command); do" '  echo PAYLOAD_RAN' 'done'
  assert_fires 't.sh' 'no-for-in-subst' 1 'for line in $(some_command)-suffix; do' '  echo PAYLOAD_RAN' 'done'
}

@test "bash style: no-for-in-subst passes a quoted substitution and a plain list" {
  assert_passes 't.sh' 'for line in "$(some_command)"; do' '  echo PAYLOAD_RAN' 'done'
  assert_passes 't.sh' "for line in 'first' 'second'; do" '  echo PAYLOAD_RAN' 'done'
}

@test "bash style: no-pipe-while reports a pipe into while" {
  assert_fires 't.sh' 'no-pipe-while' 1 'some_command | while read -r line; do' '  echo PAYLOAD_RAN' 'done'
  assert_passes 't.sh' 'while read -r line; do' '  echo PAYLOAD_RAN' 'done < <(some_command)'
}

@test "bash style: no-pipe-while reports |& and until and a longer pipeline" {
  assert_fires 't.sh' 'no-pipe-while' 1 'some_command |& while read -r line; do' '  echo PAYLOAD_RAN' 'done'
  assert_fires 't.sh' 'no-pipe-while' 1 'some_command | until read -r line; do' '  echo PAYLOAD_RAN' 'done'
  assert_fires 't.sh' 'no-pipe-while' 1 \
    'some_command | other_command | while read -r line; do' '  echo PAYLOAD_RAN' 'done'
}

@test "bash style: no-pipe-while reports a loop wrapped in a block or subshell" {
  assert_fires 't.sh' 'no-pipe-while' 1 'some_command | { while read -r line; do echo PAYLOAD_RAN; done; }'
  assert_fires 't.sh' 'no-pipe-while' 1 'some_command | (while read -r line; do echo PAYLOAD_RAN; done)'
}

@test "bash style: no-pipe-while passes a loop wrapped in a block that is not piped into" {
  assert_passes 't.sh' '{ while read -r line; do echo PAYLOAD_RAN; done; } < <(some_command)'
}

@test "bash style: no-pipe-while passes a loop whose output is piped on" {
  assert_passes 't.sh' 'while read -r line; do' '  echo PAYLOAD_RAN' 'done < <(some_command) | other_command'
}

@test "bash style: source-not-dot reports the dot command" {
  assert_fires 't.sh' 'source-not-dot' 1 ". 'lib.sh'"
  assert_passes 't.sh' "source 'lib.sh'"
}

@test "bash style: source-not-dot reports the dot command behind a wrapper" {
  assert_fires 't.sh' 'source-not-dot' 1 "builtin . 'lib.sh'"
  assert_fires 't.sh' 'source-not-dot' 1 "command . 'lib.sh'"
}

@test "bash style: no-let-expr reports let and expr" {
  assert_fires 't.sh' 'no-let-expr' 1 'let count=1'
  assert_fires 't.sh' 'no-let-expr' 1 'count="$(expr 1 + 1)"'
}

@test "bash style: no-let-expr reports expr behind a wrapper" {
  assert_fires 't.sh' 'no-let-expr' 1 'count="$(command expr 1 + 1)"'
}

@test "bash style: no-let-expr passes a lookup of let or expr" {
  assert_passes 't.sh' 'command -v expr > /dev/null' 'command -v let > /dev/null'
}

@test "bash style: no-alias reports an alias" {
  assert_fires 't.sh' 'no-alias' 1 "alias greet='echo PAYLOAD_RAN'"
  assert_fires 't.sh' 'no-alias' 1 "builtin alias greet='echo PAYLOAD_RAN'"
}

@test "bash style: no-alias passes a lookup of alias" {
  assert_passes 't.sh' 'command -v alias > /dev/null'
}

@test "bash style: bare-arith-stmt reports (( )) as a whole statement" {
  assert_fires 't.sh' 'bare-arith-stmt' 2 'count=0' '((count += 1))'
  assert_passes 't.sh' 'count=0' \
    '((count += 1)) || true # fixture: zero is fine' \
    'if ((count > 0)); then' '  echo PAYLOAD_RAN' 'fi' \
    'count="$((count + 1))"'
}

@test "bash style: bare-arith-stmt reports (( )) in every kind of body" {
  assert_fires 't.sh' 'bare-arith-stmt' 2 'if true; then' '  ((count++))' 'fi'
  assert_fires 't.sh' 'bare-arith-stmt' 4 'if false; then' '  echo PAYLOAD_RAN' 'else' '  ((count++))' 'fi'
  assert_fires 't.sh' 'bare-arith-stmt' 4 'if false; then' '  echo PAYLOAD_RAN' 'elif true; then' '  ((count++))' 'fi'
  assert_fires 't.sh' 'bare-arith-stmt' 2 'while true; do' '  ((count++))' 'done'
  assert_fires 't.sh' 'bare-arith-stmt' 2 'until false; do' '  ((count++))' 'done'
  assert_fires 't.sh' 'bare-arith-stmt' 2 'for i in 1 2; do' '  ((count++))' 'done'
  assert_fires 't.sh' 'bare-arith-stmt' 3 'case x in' '  x)' '    ((count++))' '    ;;' 'esac'
  assert_fires 't.sh' 'bare-arith-stmt' 1 '( ((count++)) )'
  assert_fires 't.sh' 'bare-arith-stmt' 4 '# @description Inert.' '# @noargs' 'function f() {' '  ((count++))' '}'
}

@test "bash style: bare-arith-stmt passes (( )) used as a condition or with a reason" {
  assert_passes 't.sh' 'while ((count > 0)); do' '  echo PAYLOAD_RAN' 'done'
  assert_passes 't.sh' 'until ((count > 0)); do' '  echo PAYLOAD_RAN' 'done'
  assert_passes 't.sh' \
    'if ((count > 0)); then' '  echo PAYLOAD_RAN' \
    'elif ((count < 0)); then' '  echo PAYLOAD_RAN' 'fi'
  assert_passes 't.sh' \
    '# @description Inert.' '# @noargs' 'function f() {' '  ((count++)) || true # fixture: zero is fine' '}'
  assert_passes 't.sh' '((count > 0)) && echo PAYLOAD_RAN'
}

@test "bash style: bare-arith-stmt passes a negated statement" {
  assert_passes 't.sh' '! ((count))'
}

@test "bash style: bare-arith-stmt passes a background statement" {
  assert_passes 't.sh' '((count)) &'
}

@test "bash style: blank-fallback-comment reports a blank fallback with no reason on its line" {
  assert_fires 's.sh' 'blank-fallback-comment' 1 'some_command || true'
  assert_fires 's.sh' 'blank-fallback-comment' 1 'some_command || :'
  assert_fires 's.sh' 'blank-fallback-comment' 1 "value=\"\$(some_command)\" || value=''"
}

@test "bash style: blank-fallback-comment reads only an empty assignment as blank" {
  assert_passes 's.sh' "value=\"\$(some_command)\" || items=('a')"
  assert_fires 's.sh' 'blank-fallback-comment' 1 'value="$(some_command)" || items=()'
}

@test "bash style: blank-fallback-comment reports every spelling of a blank fallback" {
  assert_fires 's.sh' 'blank-fallback-comment' 1 'value="$(some_command)" || value='
  assert_fires 's.sh' 'blank-fallback-comment' 1 'value="$(some_command)" || value=""'
  assert_fires 's.sh' 'blank-fallback-comment' 1 "some_command || printf ''"
  assert_fires 's.sh' 'blank-fallback-comment' 1 'some_command || builtin :'
  assert_fires 's.sh' 'blank-fallback-comment' 1 'some_command || command true'
  assert_fires 's.sh' 'blank-fallback-comment' 2 'if some_command ||' '  true; then' '  echo PAYLOAD_RAN' 'fi'
}

@test "bash style: blank-fallback-comment passes a same-line reason and a named sentinel" {
  assert_passes 's.sh' \
    'some_command || true # fixture: failure is expected' \
    "value=\"\$(some_command)\" || value='NO-VALUE'" \
    "some_command || printf 'NO-HEAD'"
}

@test "bash style: blank-fallback-comment takes the reason from the line the fallback is on" {
  assert_passes 's.sh' $'some_command \\' '  || true # fixture: failure is expected'
  assert_fires 's.sh' 'blank-fallback-comment' 2 $'some_command \\' '  || true'
  assert_fires 's.sh' 'blank-fallback-comment' 2 \
    $'some_command \\' '  || true' '# fixture: a reason on a later line does not count'
}

@test "bash style: blank-fallback-comment does not accept a reason on the line above" {
  assert_fires 's.sh' 'blank-fallback-comment' 2 '# fixture: failure is expected' 'some_command || true'
}

@test "bash style: blank-fallback-comment passes a fallback that runs something" {
  assert_passes 's.sh' 'some_command || other_command' 'some_command || return 1' \
    "value=\"\$(some_command)\" || value='x'"
}

@test "bash style: shellcheck-disable-justified reports a directive with no reason" {
  assert_fires 's.sh' 'shellcheck-disable-justified' 1 '# shellcheck disable=SC2034' 'unused=1'
  assert_passes 's.sh' '# shellcheck disable=SC2034 # fixture: read by a caller' 'unused=1'
}

@test "bash style: shellcheck-disable-justified reports a trailing directive and an empty reason" {
  assert_fires 's.sh' 'shellcheck-disable-justified' 1 'unused=1 # shellcheck disable=SC2034'
  assert_fires 's.sh' 'shellcheck-disable-justified' 1 '# shellcheck disable=SC2034 #' 'unused=1'
}

@test "bash style: shellcheck-disable-justified reads several codes and combined directives" {
  assert_fires 's.sh' 'shellcheck-disable-justified' 1 '# shellcheck disable=SC2034,SC2154' 'unused=1'
  assert_passes 's.sh' '# shellcheck disable=SC2034,SC2154 # fixture: read by a caller' 'unused=1'
  assert_fires 's.sh' 'shellcheck-disable-justified' 1 '# shellcheck source=/dev/null disable=SC1091' "source 'lib.sh'"
  assert_passes 's.sh' '# shellcheck source=/dev/null disable=SC1091 # fixture: not a real file' "source 'lib.sh'"
}

@test "bash style: shellcheck-disable-justified leaves other directives alone" {
  assert_passes 's.sh' '# shellcheck source=/dev/null' "source 'lib.sh'" '# shellcheck shell=bash'
}

@test "bash style: no-subst-or-exit reports || exit on a substitution assignment" {
  assert_fires 's.sh' 'no-subst-or-exit' 1 'value="$(some_command)" || exit 1'
  assert_passes 's.sh' 'value="$(some_command)"' 'some_command || exit 1'
}

@test "bash style: no-subst-or-exit reports a substitution inside a longer value and exit behind a wrapper" {
  assert_fires 's.sh' 'no-subst-or-exit' 1 'value="prefix-$(some_command)" || exit 1'
  assert_fires 's.sh' 'no-subst-or-exit' 1 'value="$(some_command)" || exit'
  assert_fires 's.sh' 'no-subst-or-exit' 1 'value="$(some_command)" || builtin exit 1'
}

@test "bash style: no-subst-or-exit passes an assignment with no substitution and a fallback that is not exit" {
  assert_passes 's.sh' 'value=5 || exit 1' 'value="$(some_command)" || other_command'
}

@test "bash style: eval-comment reports an eval with no comment beside it" {
  assert_fires 's.sh' 'eval-comment' 1 "eval 'echo PAYLOAD_RAN'"
  assert_passes 's.sh' '# fixture: the string is a literal built above' "eval 'echo PAYLOAD_RAN'"
}

@test "bash style: eval-comment takes a comment on the same line" {
  assert_passes 's.sh' "eval 'echo PAYLOAD_RAN' # fixture: the string is a literal"
}

@test "bash style: eval-comment reports an eval behind a wrapper or inside a substitution" {
  assert_fires 's.sh' 'eval-comment' 1 "builtin eval 'echo PAYLOAD_RAN'"
  assert_fires 's.sh' 'eval-comment' 1 "command eval 'echo PAYLOAD_RAN'"
  assert_fires 's.sh' 'eval-comment' 1 "value=\"\$(eval 'echo PAYLOAD_RAN')\""
}

@test "bash style: eval-comment does not accept a comment two lines up and passes a lookup" {
  assert_fires 's.sh' 'eval-comment' 3 '# fixture: too far away' 'some_command' "eval 'echo PAYLOAD_RAN'"
  assert_passes 's.sh' 'command -v eval > /dev/null'
}

@test "bash style: main-last reports an executed script whose last function is not main" {
  write_script 'm.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    'function main() {' '  echo PAYLOAD_RAN' '}' \
    '# @description Inert.' '# @noargs' 'function helper() {' '  echo PAYLOAD_RAN' '}' \
    'main "$@"'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:8: [main-last] main is the last function defined"
}

@test "bash style: main-last reports an executed script that does not end in main" {
  write_script 'm.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    'function main() {' '  echo PAYLOAD_RAN' '}' \
    'main "$@"' 'echo PAYLOAD_RAN'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:7: [main-last] the last statement is main"
}

@test "bash style: main-last reports a lone helper and a main call that drops the arguments" {
  write_script 'm.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    '# @description Inert.' '# @noargs' 'function helper() {' '  echo PAYLOAD_RAN' '}' \
    'helper'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:5: [main-last] main is the last function defined"
  write_script 'm.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    'function main() {' '  echo PAYLOAD_RAN' '}' \
    'main'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:6: [main-last] the last statement is main"
}

@test "bash style: the layout rules pass a well-formed executed script, one with no functions, and any sourced file" {
  write_script 'ok.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    '# @description Inert.' '# @noargs' 'function helper() {' '  echo PAYLOAD_RAN' '}' \
    'function main() {' '  helper' '}' \
    'main "$@"' '# a trailing comment'
  run "${CHECK}" "${FIXTURE}"
  assert_success
  write_script 'flat.sh' 'set -Eeuo pipefail' "IFS=\$'\\n\\t'" 'echo PAYLOAD_RAN'
  run "${CHECK}" "${FIXTURE}"
  assert_success
  assert_passes 'lib.sh' \
    '# @description Inert.' '# @noargs' 'function helper() {' '  echo PAYLOAD_RAN' '}' 'echo PAYLOAD_RAN'
  assert_passes 'suite.bats' \
    '# @description Inert.' '# @noargs' 'function helper() {' '  echo PAYLOAD_RAN' '}' \
    '@test "inert" {' '  helper' '}'
}

@test "bash style: functions-grouped reports a statement between two functions" {
  write_script 'g.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    '# @description Inert.' '# @noargs' 'function helper() {' '  echo PAYLOAD_RAN' '}' \
    'echo PAYLOAD_RAN' \
    'function main() {' '  helper' '}' \
    'main "$@"'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:8: [functions-grouped]"
}

@test "bash style: functions-grouped reports a readonly between functions and allows a comment there" {
  write_script 'g.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    '# @description Inert.' '# @noargs' 'function helper() {' '  echo PAYLOAD_RAN' '}' \
    'readonly LATE=1' \
    'function main() {' '  helper' '}' \
    'main "$@"'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:8: [functions-grouped]"
  write_script 'g.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    '# @description Inert.' '# @noargs' 'function helper() {' '  echo PAYLOAD_RAN' '}' \
    '# a comment between functions' \
    'function main() {' '  helper' '}' \
    'main "$@"'
  run "${CHECK}" "${FIXTURE}"
  assert_success
}

@test "bash style: strict-prologue reports a missing pragma and a missing IFS" {
  write_script 'p.sh' 'echo PAYLOAD_RAN'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:1: [strict-prologue] set -Eeuo pipefail"
  write_script 'p.sh' 'set -Eeuo pipefail' 'echo PAYLOAD_RAN'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:1: [strict-prologue] IFS="
}

@test "bash style: strict-prologue allows shopt and a version guard between the pragma and IFS" {
  write_script 'p.sh' \
    'set -Eeuo pipefail' \
    'if ((BASH_VERSINFO[0] < 4)); then' '  exit 1' 'fi' \
    'shopt -s inherit_errexit' \
    "IFS=\$'\\n\\t'" \
    'echo PAYLOAD_RAN'
  run "${CHECK}" "${FIXTURE}"
  assert_success
}

@test "bash style: strict-prologue wants -E, and reads the pragma after a version guard" {
  write_script 'p.sh' 'set -euo pipefail' "IFS=\$'\\n\\t'" 'echo PAYLOAD_RAN'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:1: [strict-prologue] set -Eeuo pipefail"
  write_script 'p.sh' \
    'if ((BASH_VERSINFO[0] < 4)); then' '  exit 1' 'fi' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" 'echo PAYLOAD_RAN'
  run "${CHECK}" "${FIXTURE}"
  assert_success
}

@test "bash style: strict-prologue reports IFS set before the pragma and a one-command IFS" {
  write_script 'p.sh' "IFS=\$'\\n\\t'" 'set -Eeuo pipefail' 'echo PAYLOAD_RAN'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:2: [strict-prologue] IFS="
  write_script 'p.sh' 'set -Eeuo pipefail' "IFS=\$'\\n\\t' read -r line" 'echo PAYLOAD_RAN'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:1: [strict-prologue] IFS="
}

@test "bash style: strict-prologue accepts IFS assigned with readonly" {
  write_script 'p.sh' 'set -Eeuo pipefail' "readonly IFS=\$'\\n\\t'" 'echo PAYLOAD_RAN'
  run "${CHECK}" "${FIXTURE}"
  assert_success
}

@test "bash style: no-default-wellknown-env reports a default on HOME" {
  assert_fires 'e.sh' 'no-default-wellknown-env' 1 'echo "${HOME:-/nowhere}"'
  assert_passes 'e.sh' 'echo "${HOME}" "${OPTIONAL_THING:-}"'
}

@test "bash style: no-default-wellknown-env reports every spelling of a default and every well-known name" {
  assert_fires 'e.sh' 'no-default-wellknown-env' 1 'echo "${HOME:-}"'
  assert_fires 'e.sh' 'no-default-wellknown-env' 1 'echo "${HOME-/nowhere}"'
  assert_fires 'e.sh' 'no-default-wellknown-env' 1 'echo "${USER:=nobody}"'
  assert_fires 'e.sh' 'no-default-wellknown-env' 1 'echo "${SDKMAN_DIR:-/nowhere}"'
  assert_passes 'e.sh' 'echo "${HOME:+set}" "${TMPDIR:-/tmp}"'
}

@test "bash style: max-line-length reports a long multi-word line and a long comment" {
  local word
  word="$(printf 'a%.0s' {1..70})"
  assert_fires 'l.sh' 'max-line-length' 1 "echo ${word} ${word}"
  assert_fires 'l.sh' 'max-line-length' 1 "# ${word} ${word}"
}

@test "bash style: max-line-length excuses one unbreakable literal, and counts characters, not bytes" {
  local literal dashes
  literal="$(printf 'a%.0s' {1..130})"
  assert_passes 'l.sh' "echo '${literal}'"
  # 110 em dashes are 110 characters and 330 bytes.
  dashes="$(printf '—%.0s' {1..110})"
  assert_passes 'l.sh' "# ${dashes}"
}

@test "bash style: max-line-length does not count marker text" {
  local word
  word="$(printf 'a%.0s' {1..100})"
  assert_fires 'hooks/l.sh' 'marker-unused' 1 "echo ${word} # bash-style allow=function-keyword: fixture reason"
  refute_output --partial '[max-line-length]'
}

@test "bash style: max-line-length excuses a comment with one unbroken word, not one of ordinary words" {
  local url prose
  url="https://example.invalid/$(printf 'a%.0s' {1..90})"
  prose="$(printf 'word %.0s' {1..30})"
  assert_passes 'l.sh' "# see ${url} for the details of this"
  assert_fires 'l.sh' 'max-line-length' 1 "# ${prose}"
  assert_fires 'l.sh' 'max-line-length' 1 "# ${url} ${url}"
}

@test "bash style: max-line-length reports a long line inside a heredoc" {
  local literal
  literal="$(printf 'a%.0s' {1..130})"
  assert_fires 'l.sh' 'max-line-length' 2 "cat <<'EOF'" "echo ${literal} ${literal}" 'EOF'
  assert_passes 'l.sh' "printf '%s\\n' '${literal}'"
}

@test "bash style: max-line-length reports a line of exactly 121 characters and passes one of 120" {
  local long short
  long="$(printf 'a%.0s' {1..58})"
  short="$(printf 'a%.0s' {1..57})"
  assert_fires 'l.sh' 'max-line-length' 1 "echo ${long} ${short}"
  assert_passes 'l.sh' "echo ${short} ${short}"
}

@test "bash style: max-line-length excuses a long quoted string after an assignment or an option" {
  local text
  text="$(printf 'word %.0s' {1..30})"
  assert_passes 'l.sh' "PROG='${text}'"
  assert_passes 'l.sh' "readonly PROG=\"\${HOME} ${text}\""
  assert_passes 'l.sh' "some_command --regex='${text}'"
  assert_fires 'l.sh' 'max-line-length' 1 "some_command --first='${text}' --second='${text}'"
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

@test "bash style: main-last reports exec main and an exit after main" {
  write_script 'm.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    'function main() {' '  echo PAYLOAD_RAN' '}' \
    'exec main "$@"'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:6: [main-last] the last statement is main"
  write_script 'm.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    'function main() {' '  echo PAYLOAD_RAN' '}' \
    'main "$@"' 'exit'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:7: [main-last] the last statement is main"
}

@test "bash style: the layout rules pass entry code between the last function and main" {
  write_script 'e.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    'function main() {' '  echo PAYLOAD_RAN' '}' \
    'if (($# == 0)); then' '  exit 1' 'fi' \
    'main "$@"'
  run "${CHECK}" "${FIXTURE}"
  assert_success
}
