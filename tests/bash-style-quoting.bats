# .ci/check-bash-style's quoting and flag rules, driven against fixture files
# written under BATS_TEST_TMPDIR: quote-expansions through fetch-flags, the
# reports and the passes.
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

@test "bash style: quote-literal-path leaves the command word alone, behind wrappers too" {
  assert_passes 'p.sh' './tool --flag' 'run ./tool --flag' 'run timeout 5 ./tool --flag'
  assert_fires 'p.sh' 'quote-literal-path' 1 'run ./tool ./relative'
  assert_fires 'p.sh' 'quote-literal-path' 1 'env --chdir=x timeout 5 ./tool /etc/os-release'
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

@test "bash style: long-options reads a flag handed to a test helper as data" {
  # run_hook is defined in tests/test_helper/common.bash, which the gate reads
  # from the repository that holds it, not from the fixture's directory.
  assert_passes 'tests/o.bats' \
    '@test "inert" {' "  run_hook -x 'echo PAYLOAD_RAN'" "  run run_hook -x 'echo PAYLOAD_RAN'" '}'
  assert_fires 'tests/o.bats' 'long-options' 2 '@test "inert" {' "  no_such_helper -x 'echo PAYLOAD_RAN'" '}'
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

@test "bash style: xargs-flags and long-options leave BSD xargs alone under hooks/ and tests/" {
  assert_passes 'tests/x.sh' 'some_command | xargs -0 -n 1 other_command'
  assert_passes 'hooks/x.sh' 'some_command | xargs -r -I {} other_command {}'
  assert_fires 'x.sh' 'xargs-flags' 1 'some_command | xargs -0 -n 1 other_command'
  assert_output --partial '[long-options] use the long form of xargs -n'
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
