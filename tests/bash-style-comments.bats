# .ci/check-bash-style's shdoc and comment rules, driven against fixture files
# written under BATS_TEST_TMPDIR: shdoc-present through todo-form, the reports
# and the passes.
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

@test "bash style: shdoc-present reports a function with no doc block, and one with no @arg or @noargs" {
  assert_fires 'd.sh' 'shdoc-present' 1 'function bare() {' '  echo PAYLOAD_RAN' '}'
  assert_fires 'd.sh' 'shdoc-present' 2 '# @description Inert.' 'function half() {' '  echo PAYLOAD_RAN' '}'
}

@test "bash style: shdoc-present leaves main and the bats hook functions alone" {
  assert_passes 'd.sh' 'function main() {' '  echo PAYLOAD_RAN' '}'
  assert_passes 'd.bats' 'function setup() {' '  echo PAYLOAD_RAN' '}' '@test "inert" {' '  echo PAYLOAD_RAN' '}'
}

@test "bash style: shdoc-present accepts a description that starts on the next line" {
  assert_passes 'd.sh' \
    '# @description' '#   Inert.' '# @noargs' \
    'function multi() {' '  echo PAYLOAD_RAN' '}'
}

@test "bash style: shdoc-arg-positions reports a body that reads a positional the block does not document" {
  assert_fires 'd.sh' 'shdoc-arg-positions' 3 \
    '# @description Inert.' '# @noargs' 'function reads() {' '  echo "$2"' '}'
  assert_fires 'd.sh' 'shdoc-arg-positions' 3 \
    '# @description Inert.' '# @arg $1 name a thing' 'function unread() {' '  echo PAYLOAD_RAN' '}'
}

@test "bash style: shdoc-arg-positions passes matching positions, varargs, and \$0" {
  assert_passes 'd.sh' \
    '# @description Inert.' '# @arg $1 name a thing' '# @arg $@ rest more things' \
    'function matched() {' '  local -r name="$1"' '  shift' '  echo "${name}" "${0##*/}" "$@"' '}'
}

@test "bash style: shdoc-arg-positions lets a documented \$@ cover a peek at \$1" {
  assert_passes 'd.sh' \
    '# @description Inert.' '# @arg $@ args the words given' \
    'function peeks() {' '  echo "${1:-}" "$@"' '}'
}

@test "bash style: shdoc-arg-positions leaves a nested function's positionals to that function" {
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' \
    'function outer() {' \
    '  # @description Inert.' '  # @arg $1 word a word' \
    '  function inner() {' '    echo "$1"' '  }' \
    '  inner PAYLOAD_RAN' '}'
}

@test "bash style: shdoc-arg-name reports a local named differently from its @arg" {
  assert_fires 'd.sh' 'shdoc-arg-name' 4 \
    '# @description Inert.' '# @arg $1 name a thing' \
    'function renamed() {' '  local -r other="$1"' '  echo "${other}"' '}'
}

@test "bash style: shdoc-arg-name reports a renamed bind through a default or a plain assignment" {
  assert_fires 'd.sh' 'shdoc-arg-name' 4 \
    '# @description Inert.' '# @arg $1 name a thing' \
    'function renamed() {' '  local -r other="${1:-}"' '  echo "${other}"' '}'
  assert_fires 'd.sh' 'shdoc-arg-name' 5 \
    '# @description Inert.' '# @arg $1 name a thing' \
    'function renamed() {' '  local other' '  other="$1"' '  echo "${other}"' '}'
}

@test "bash style: shdoc-arg-name passes a matching bind and lets a nameref differ" {
  assert_passes 'd.sh' \
    '# @description Inert.' '# @arg $1 name a thing' \
    'function bound() {' '  local -r name="$1"' '  echo "${name}"' '}'
  assert_passes 'd.sh' \
    '# @description Inert.' '# @arg $1 out_name the variable to fill' \
    'function fill() {' '  local -n out="$1"' '  out=1' '}'
}

@test "bash style: shdoc-set reports an upper-case global assigned without @set" {
  assert_fires 'd.sh' 'shdoc-set' 4 \
    '# @description Inert.' '# @noargs' 'function writes() {' '  GLOBAL_THING=1' '}'
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' '# @set GLOBAL_THING the thing' \
    'function writes() {' '  GLOBAL_THING=1' '}'
}

@test "bash style: shdoc-set reports a global written by declare -g, readonly or export" {
  assert_fires 'd.sh' 'shdoc-set' 4 \
    '# @description Inert.' '# @noargs' 'function writes() {' '  declare -g GLOBAL_THING=1' '}'
  assert_fires 'd.sh' 'shdoc-set' 4 \
    '# @description Inert.' '# @noargs' 'function writes() {' '  readonly GLOBAL_THING=1' '}'
  assert_fires 'd.sh' 'shdoc-set' 4 \
    '# @description Inert.' '# @noargs' 'function writes() {' '  export GLOBAL_THING=1' '}'
}

@test "bash style: shdoc-set ignores locals, command-prefix assignments and shell specials" {
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' \
    'function scoped() {' '  local UPPER_LOCAL=1' '  UPPER_LOCAL=2' '  IFS=, read -r first' '  SECONDS=0' \
    '  echo "${UPPER_LOCAL}" "${first}"' '}'
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' \
    'function scoped() {' '  declare UPPER_LOCAL=1' '  echo "${UPPER_LOCAL}"' '}'
}

@test "bash style: shdoc-set reads a documented name across wrapped tags" {
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' '# @set GLOBAL_THING the thing,' '#      wrapped' \
    'function writes() {' '  GLOBAL_THING=1' '}'
}

@test "bash style: shdoc-set lets a nested function write a name its enclosing function declared local" {
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' \
    'function outer() {' '  local COUNT=0' \
    '  # @description Inert.' '  # @noargs' \
    '  function inner() {' '    COUNT=1' '  }' \
    '  inner' '  echo "${COUNT}"' '}'
}

@test "bash style: shdoc-stderr reports a body that writes to fd 2 without @stderr" {
  assert_fires 'd.sh' 'shdoc-stderr' 3 \
    '# @description Inert.' '# @noargs' 'function warns() {' '  echo PAYLOAD_RAN >&2' '}'
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' '# @stderr the marker' 'function warns() {' '  echo PAYLOAD_RAN >&2' '}'
}

@test "bash style: shdoc-stderr reports 1>&2, a heredoc to fd 2 and /dev/stderr" {
  assert_fires 'd.sh' 'shdoc-stderr' 3 \
    '# @description Inert.' '# @noargs' 'function warns() {' '  echo PAYLOAD_RAN 1>&2' '}'
  assert_fires 'd.sh' 'shdoc-stderr' 3 \
    '# @description Inert.' '# @noargs' 'function warns() {' "  cat <<'EOF' >&2" '  PAYLOAD_RAN' 'EOF' '}'
  assert_fires 'd.sh' 'shdoc-stderr' 3 \
    '# @description Inert.' '# @noargs' 'function warns() {' '  echo PAYLOAD_RAN > /dev/stderr' '}'
}

@test "bash style: shdoc-stderr passes a function that only calls a logger or merges 2 into 1" {
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' \
    'function calls() {' '  log PAYLOAD_RAN' '  some_command 2>&1' '  some_command 2> /dev/null' '}'
}

@test "bash style: shdoc-stderr leaves a nested function's stderr to that function" {
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' \
    'function outer() {' \
    '  # @description Inert.' '  # @noargs' '  # @stderr the marker' \
    '  function inner() {' '    echo PAYLOAD_RAN >&2' '  }' \
    '  inner' '}'
}

@test "bash style: shdoc-arg-positions passes a variadic function that loops over or counts its arguments" {
  assert_passes 'd.sh' \
    '# @description Inert.' '# @arg $@ args the words given' \
    'function loops() {' '  while (($# > 0)); do' '    case "$1" in' '      x) echo PAYLOAD_RAN ;;' '    esac' \
    '    shift' '  done' '}'
  assert_passes 'd.sh' \
    '# @description Inert.' '# @arg $@ args the words given' \
    'function counts() {' '  echo "$#"' '}'
}

@test "bash style: shdoc-arg-positions reports a documented \$@ over a body that reads no positional" {
  assert_fires 'd.sh' 'shdoc-arg-positions' 3 \
    '# @description Inert.' '# @arg $@ args the words given' 'function ignores() {' '  echo PAYLOAD_RAN' '}'
}

@test "bash style: shdoc-set ignores an assignment inside a subshell or a command substitution" {
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' \
    'function scoped() {' '  ( PATH="/x:${PATH}"; export LC_ALL=C; some_command )' '}'
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' \
    'function scoped() {' '  local value' '  value="$(FOO_BAR=1; some_command)"' '  echo "${value}"' '}'
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' \
    'function scoped() {' "  diff <(FOO_BAR=1; some_command) '/dev/null'" '}'
}

@test "bash style: shdoc-stderr passes a descriptor duplication and reports a write from fd 1" {
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' \
    'function dups() {' '  exec 3>&2' '}'
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' \
    'function dups() {' '  some_command 3>&2' '}'
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' \
    'function dups() {' '  exec >&2' '}'
  assert_fires 'd.sh' 'shdoc-stderr' 3 \
    '# @description Inert.' '# @noargs' 'function warns() {' '  echo PAYLOAD_RAN 1>&2' '}'
}

@test "bash style: shdoc-arg-name lets a nameref declared and assigned on separate lines differ" {
  assert_passes 'd.sh' \
    '# @description Inert.' '# @arg $1 name_ref the variable to fill' \
    'function fill() {' '  local -n out' '  out="$1"' '  out=1' '}'
}

@test "bash style: shdoc-set exempts names the shell owns, but not PATH" {
  assert_passes 'd.sh' \
    '# @description Inert.' '# @noargs' \
    'function complete_it() {' "  COMPREPLY=('a')" '  REPLY=1' '  PS4=+' '}'
  assert_fires 'd.sh' 'shdoc-set' 4 \
    '# @description Inert.' '# @noargs' 'function widens() {' '  PATH="/x:${PATH}"' '}'
}

@test "bash style: a blank line detaches the comment block above a function from its shdoc" {
  assert_fires 'd.sh' 'shdoc-present' 4 \
    '# @description Inert.' '# @noargs' '' 'function detached() {' '  echo PAYLOAD_RAN' '}'
}

@test "bash style: a file header above a blank line is not the first function's shdoc" {
  assert_passes 'd.sh' \
    '# @description Inert.' '' \
    '# @description Inert.' '# @noargs' 'function first() {' '  echo PAYLOAD_RAN' '}'
  assert_passes 'd.sh' \
    '# @description Inert.' '# @arg $1 thing a header line that is not an argument of first' '' \
    '# @description Inert.' '# @noargs' 'function first() {' '  echo PAYLOAD_RAN' '}'
}

@test "bash style: comment-line-ref reports a file:line citation" {
  assert_fires 'c.sh' 'comment-line-ref' 1 '# See hooks/lib/classify.sh:120 for the caller.' 'echo PAYLOAD_RAN'
  assert_passes 'c.sh' '# See classify::classify_command in hooks/lib/classify.sh.' 'echo PAYLOAD_RAN'
}

@test "bash style: comment-line-ref passes a port, a time, a placeholder and an shdoc exit code" {
  assert_passes 'c.sh' \
    '# The server answers on http://localhost:8080 at 12:30; retries: 123.' \
    '# Write the citation as file.sh:NN, never with a number.' \
    '# @exitcode 1 a violation' \
    'echo PAYLOAD_RAN'
}

@test "bash style: comment-untracked-ref reports a file under an untracked directory" {
  assert_fires 'c.sh' 'comment-untracked-ref' 1 '# The plan is docs/superpowers/plans/thing.md.' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'comment-untracked-ref' 1 '# See .claude/CLAUDE.md.' 'echo PAYLOAD_RAN'
  assert_passes 'c.sh' '# docs/superpowers/ is untracked, so it is skipped.' 'echo PAYLOAD_RAN'
}

@test "bash style: comment-untracked-ref passes a sentence that only names the directory" {
  assert_passes 'c.sh' \
    '# The gate never reads `.claude/`; it is untracked, like (docs/superpowers/).' \
    '# A .claude directory is the author-local one.' \
    'echo PAYLOAD_RAN'
}

@test "bash style: comment-missing-path reports a repo path no tracked file has" {
  assert_fires 'c.sh' 'comment-missing-path' 1 '# Parts live in hooks/lib/no-such-part.sh.' 'echo PAYLOAD_RAN'
}

@test "bash style: comment-missing-path reports a path hyphenated across two comment lines" {
  assert_fires 'c.sh' 'comment-missing-path' 1 \
    '# Same trade .ci/run-plugin-' \
    '# validate makes for the CLI.' \
    'echo PAYLOAD_RAN'
}

@test "bash style: comment-missing-path passes real files, real directories, globs and placeholders" {
  assert_passes 'c.sh' \
    '# hooks/lib/classify.sh sits under hooks/lib, with hooks/lib/*.sh,' \
    '# .ci/check-<name> and tests/${suite}.bats beside it.' \
    'echo PAYLOAD_RAN'
}

@test "bash style: comment-missing-path ignores punctuation around a real path" {
  assert_passes 'c.sh' \
    '# See hooks/lib/classify.sh, `.ci/check-bash-style`, (docs/architecture.md),' \
    '# tests/cases/ and .github/workflows/ci.yml.' \
    'echo PAYLOAD_RAN'
}

@test "bash style: comment-missing-path ignores a path inside a URL or another repository" {
  assert_passes 'c.sh' \
    '# See https://example.com/docs/no-such-page and' \
    '# anthropics/claude-code/.github/workflows/no-such.yml for the upstream.' \
    'echo PAYLOAD_RAN'
}

@test "bash style: comment-missing-path skips an elided path" {
  assert_passes 'c.sh' '# The parts under hooks/.../no-such.sh are elided here.' 'echo PAYLOAD_RAN'
}

@test "bash style: comment-missing-function reports a namespaced function nothing defines" {
  assert_fires 'c.sh' 'comment-missing-function' 1 '# Calls classify::defined_nowhere first.' 'echo PAYLOAD_RAN'
  assert_passes 'c.sh' '# Calls classify::classify_command first.' 'echo PAYLOAD_RAN'
}

@test "bash style: comment-missing-function accepts a function the scanned file defines" {
  # The prefix is a variable, so no `function <name>::<part>` line sits in this
  # suite for the gate to find in the repository: only the scanned file defines it.
  local -r ns='scanned'
  assert_passes 'c.sh' \
    "# @description Inert; ${ns}::helper is this function." '# @noargs' \
    "function ${ns}::helper() {" '  echo PAYLOAD_RAN' '}'
  assert_passes 'c.sh' \
    "# Calls ${ns}::later, defined below." \
    '# @description Inert.' '# @noargs' \
    "function ${ns}::later() {" '  echo PAYLOAD_RAN' '}'
}

@test "bash style: comment-missing-function reports a name defined nowhere even beside a defined one" {
  assert_fires 'c.sh' 'comment-missing-function' 1 \
    '# @description Calls classify::classify_command, then classify::defined_nowhere.' '# @noargs' \
    'function caller() {' '  echo PAYLOAD_RAN' '}'
}

@test "bash style: comment-commit-relative reports commit-relative wording" {
  assert_fires 'c.sh' 'comment-commit-relative' 1 '# Until now this was unguarded.' 'echo PAYLOAD_RAN'
}

@test "bash style: comment-commit-relative reports commit-relative wording even beside an issue number" {
  assert_fires 'c.sh' 'comment-commit-relative' 1 '# Before this change (#72) it was unguarded.' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'comment-commit-relative' 1 '# Until now (see #128) this was unguarded.' 'echo PAYLOAD_RAN'
}

@test "bash style: comment-commit-relative reports each listed phrase" {
  assert_fires 'c.sh' 'comment-commit-relative' 1 '# Before this gate it was unchecked.' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'comment-commit-relative' 1 '# Correct when this was written.' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'comment-commit-relative' 1 '# The commit before this one broke it.' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'comment-commit-relative' 1 '# As of this commit it is checked.' 'echo PAYLOAD_RAN'
}

@test "bash style: comment-commit-relative passes past-tense accounts of a trap and a word that contains a phrase" {
  assert_passes 'c.sh' \
    '# The old message said "x"; a retry used to hide the failure.' \
    '# Nothing here waits until nowhere is reachable.' \
    'echo PAYLOAD_RAN'
}

@test "bash style: comment-issue-ref reports an issue number in a comment" {
  assert_fires 'c.sh' 'comment-issue-ref' 1 '# The guard is split for speed (#55).' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'comment-issue-ref' 1 '# See #128 for why.' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'comment-issue-ref' 1 '#              #43 shipped a list.' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'comment-issue-ref' 1 'echo PAYLOAD_RAN # since #7'
}

@test "bash style: comment-issue-ref reports a comment that starts with an issue number" {
  assert_fires 'c.sh' 'comment-issue-ref' 1 '#55 split the guard for speed.' 'echo PAYLOAD_RAN'
}

@test "bash style: comment-issue-ref passes a hash that is not an issue number" {
  assert_passes 'c.sh' \
    '# ${#names[@]} counts the names; $# counts the arguments.' \
    '# The colour is #1a2b3c, and docs/architecture.md#42 is an anchor.' \
    '# Row #b and a lone # are not issues.' \
    "echo 'PAYLOAD_RAN #72'"
}

@test "bash style: todo-form reports a deferred-work marker that is not TODO:" {
  assert_fires 'c.sh' 'todo-form' 1 '# todo: tidy this' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'todo-form' 1 '# FIXME tidy this' 'echo PAYLOAD_RAN'
  assert_passes 'c.sh' '# TODO: tidy this' 'echo PAYLOAD_RAN'
}

@test "bash style: todo-form passes a word that only contains a marker" {
  assert_passes 'c.sh' '# The mastodon client keeps its todos in a list.' 'echo PAYLOAD_RAN'
}

@test "bash style: todo-form reports TODO with a name in parentheses, which is not the TODO: form" {
  assert_fires 'c.sh' 'todo-form' 1 '# TODO(name): tidy this' 'echo PAYLOAD_RAN'
}

@test "bash style: comment-missing-function skips a namespace no function uses" {
  assert_passes 'c.sh' \
    '# See style::report for the entry point.' \
    '# std::string is not bash.' \
    'echo PAYLOAD_RAN'
}

@test "bash style: comment-missing-function still reports a misspelt name in a used namespace" {
  assert_fires 'c.sh' 'comment-missing-function' 1 '# Calls classify::no_such_function first.' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'comment-missing-function' 1 '# Calls classify::classify_commands first.' 'echo PAYLOAD_RAN'
}

@test "bash style: comment-commit-relative passes present-tense ordering prose" {
  assert_passes 'c.sh' \
    '# Lint runs before this gate, so the tree is formatted.' \
    '# Before this change takes effect the cache is empty.' \
    'echo PAYLOAD_RAN'
}

@test "bash style: comment-commit-relative reports before-this with a past-tense verb" {
  assert_fires 'c.sh' 'comment-commit-relative' 1 '# Before this gate there was no check.' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'comment-commit-relative' 1 '# Before this change it used to hang.' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'comment-commit-relative' 1 '# Before this commit nobody could tell.' 'echo PAYLOAD_RAN'
}

@test "bash style: todo-form passes prose that is not a marker" {
  assert_passes 'c.sh' \
    '# Add a todo item to the list; xxx stands in for a name here.' \
    '# The mastodon client; TODO: tidy this' \
    'echo PAYLOAD_RAN'
}

@test "bash style: todo-form reports an upper-case marker not followed directly by a colon" {
  assert_fires 'c.sh' 'todo-form' 1 '# TODO tidy this' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'todo-form' 1 '# TODO - tidy this' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'todo-form' 1 '# FIXME: tidy this' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'todo-form' 1 '# XXX: tidy this' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'todo-form' 1 '# XXX tidy this' 'echo PAYLOAD_RAN'
}

@test "bash style: todo-form reports a lower or mixed case marker with a colon" {
  assert_fires 'c.sh' 'todo-form' 1 '# Todo: tidy this' 'echo PAYLOAD_RAN'
  assert_fires 'c.sh' 'todo-form' 1 '# fixme: tidy this' 'echo PAYLOAD_RAN'
}
