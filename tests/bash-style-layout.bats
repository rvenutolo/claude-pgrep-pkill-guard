# .ci/check-bash-style's rules on a whole script's shape, driven against
# fixture files written under BATS_TEST_TMPDIR: main-last, functions-grouped,
# strict-prologue, no-default-wellknown-env, max-line-length and
# mktemp-exit-trap, the reports and the passes.
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

@test "bash style: main-last reports a negated or backgrounded main call and any other expansion of the arguments" {
  # Each of these runs main, so a predicate that only looks for the name and
  # an `@` takes it for the call the rule demands. None of them hands main the
  # script's arguments and leaves its status as the script's.
  local last_statement
  for last_statement in '! main "$@"' 'main "$@" &' 'main "${@:2}"' 'main "${@:-x}"' 'main "${@/a/b}"' \
    'main "${#@}"' 'main "${!@}"'; do
    write_script 'm.sh' \
      'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
      'function main() {' '  echo PAYLOAD_RAN' '}' \
      "${last_statement}"
    run "${CHECK}" "${FIXTURE}"
    assert_failure 1
    assert_output --partial "FAIL: ${FIXTURE}:6: [main-last] the last statement is main"
  done
  write_script 'm.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    'function main() {' '  echo PAYLOAD_RAN' '}' \
    'main "$@"'
  run "${CHECK}" "${FIXTURE}"
  assert_success
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

@test "bash style: mktemp-exit-trap reports an executed script that calls mktemp with no EXIT trap" {
  write_script 'm.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    'function main() {' '  local tmp' '  tmp="$(mktemp)"' '  echo "${tmp}"' '}' \
    'main "$@"'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:5: [mktemp-exit-trap]"
}

@test "bash style: mktemp-exit-trap passes an EXIT trap, a dry run, and a sourced file" {
  write_script 'm.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    'function main() {' '  local tmp' '  trap cleanup EXIT' '  tmp="$(mktemp)"' '  echo "${tmp}"' '}' \
    'main "$@"'
  run "${CHECK}" "${FIXTURE}"
  assert_success
  write_script 'm.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    'function main() {' '  mktemp --dry-run' '}' \
    'main "$@"'
  run "${CHECK}" "${FIXTURE}"
  assert_success
  assert_passes 'lib.sh' 'tmp="$(mktemp)"'
}

@test "bash style: mktemp-exit-trap does not count a trap that only clears EXIT" {
  write_script 'm.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    'function main() {' '  local tmp' '  trap - EXIT' '  tmp="$(mktemp)"' '  echo "${tmp}"' '}' \
    'main "$@"'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:6: [mktemp-exit-trap]"
}

@test "bash style: mktemp-exit-trap skips the short dry-run flag" {
  # Under hooks/ the short flag is the macOS form, so long-options allows it.
  mkdir -p "${BATS_TEST_TMPDIR}/hooks"
  write_script 'hooks/m.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    'function main() {' '  mktemp -u' '}' \
    'main "$@"'
  run "${CHECK}" "${FIXTURE}"
  assert_success
}

@test "bash style: mktemp-exit-trap sees mktemp behind a wrapper" {
  write_script 'm.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    'function main() {' '  local tmp' '  tmp="$(command mktemp)"' '  echo "${tmp}"' '}' \
    'main "$@"'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:5: [mktemp-exit-trap]"
  write_script 'm.sh' \
    'set -Eeuo pipefail' "IFS=\$'\\n\\t'" \
    'function main() {' '  local tmp' '  tmp="$(env VAR=x mktemp)"' '  echo "${tmp}"' '}' \
    'main "$@"'
  run "${CHECK}" "${FIXTURE}"
  assert_failure 1
  assert_output --partial "FAIL: ${FIXTURE}:5: [mktemp-exit-trap]"
}
