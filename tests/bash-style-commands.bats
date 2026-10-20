# .ci/check-bash-style's rules on tests, case, loops, pipelines and single
# commands, driven against fixture files written under BATS_TEST_TMPDIR:
# test-double-equals through eval-comment, the reports and the passes.
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
