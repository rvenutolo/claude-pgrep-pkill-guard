# shellcheck shell=bash
#
# Loop detection: the enclosing while/until/for and what its body does, sourced
# by hooks/pgrep-pkill-guard-body.sh whenever the entry script loads the body
# -- in human mode, or once the prefilter has let a payload through. Never
# executed: no shebang, no exec bit, and it must not set `set -Eeuo pipefail`,
# `IFS`, or the ERR trap -- the entry script owns them all, and a sourced file
# that sets them reconfigures its caller. Never add `shopt -s inherit_errexit`
# (invariant 2). Long options only where the BSD tool has them: this runs on
# BSD userland too (invariant 1).

# @description Determine whether a token index sits inside a while/until condition, inside any loop
#              body, or outside every loop. A for/select head reports "none": it is evaluated once,
#              so a self-matching pgrep there pins no termination test. `$(`, a backtick, and a plain
#              `(` each push a scope-barrier marker so that a loop entirely inside one cannot pop, or
#              be popped by, a loop spanning the enclosing command: a stray `done` inside a
#              substitution (whether from a real nested loop or just literal text, such as an echoed
#              "done") finds the barrier on top and pops nothing beyond it. An unmatched
#              command-position `do` there is not bounded: it pushes `body` above the marker, the
#              closing `)` then pops nothing, and the tokens after it read as `body`. The marker is
#              transparent when reading the context AT the target index, though: an invocation that is
#              simply inside a substitution with no loop of its own still belongs to whatever cond/body
#              span encloses that substitution, which is why `until [ -z "$(pgrep --full x)" ]; do ...`
#              still reports `cond` -- the lookup skips barrier markers to find the nearest real span.
#              The close of a substitution (`$(...)`, `$((...))`, a backtick pair, `<(...)`, `>(...)`)
#              ends a word of its command and not the command itself, so a loop keyword right after
#              it is an argument (`echo $(true) done`, `cat <(echo x) done`) -- unless the word
#              holding it is an assignment (`FOO=$(true) break`), which leaves command position as
#              it was.
# @arg $1 command the raw command string
# @arg $2 tokens the token stream from scanner::scan_command
# @arg $3 target index of the invocation token
# @stdout none, cond, or body
function loops::loop_context() {
  local -r command="$1" tokens="$2" target="$3"
  local -a stack=()
  local idx=0 at_cmd=1 dollar=0 offset token redir='' kind closed_assign=0
  local -a word_assign=()
  local -A region=()
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    if ((idx == target)); then
      local i="$((${#stack[@]} - 1))" found='none'
      while ((i >= 0)); do
        case "${stack[i]}" in
          'cond')
            found='cond'
            break
            ;;
          'body')
            found='body'
            break
            ;;
          'head')
            found='none'
            break
            ;;
          *) i="$((i - 1))" ;;
        esac
      done
      printf '%s\n' "${found}"
      return 0
    fi
    tokens::region_step "${command}" "${offset}" "${token}" region kind
    closed_assign=0
    case "${kind}" in
      'P' | 'A' | 'B' | 'S')
        if tokens::region_opens_assignment_value region "${kind}" "${offset}"; then
          word_assign+=(1)
        else
          word_assign+=(0)
        fi
        ;;
      'close')
        closed_assign="${word_assign[-1]}"
        unset 'word_assign[-1]'
        ;;
    esac
    # A redirection leaves command position as it was, like the rest of the walkers (see
    # tokens::redirection_step).
    if tokens::redirection_step "${token}" redir; then
      idx="$((idx + 1))"
      continue
    fi
    if ((at_cmd == 1)); then
      case "${token}" in
        'while' | 'until') stack+=('cond') ;;
        'for' | 'select') stack+=('head') ;;
        'do')
          if ((${#stack[@]} > 0)) && [[ "${stack[${#stack[@]} - 1]}" == 'cond' ||
            "${stack[${#stack[@]} - 1]}" == 'head' ]]; then
            unset 'stack[${#stack[@]}-1]'
          fi
          stack+=('body')
          ;;
        'done')
          if ((${#stack[@]} > 0)) && [[ "${stack[${#stack[@]} - 1]}" == 'body' ]]; then
            unset 'stack[${#stack[@]}-1]'
          fi
          ;;
      esac
    fi
    case "${token}" in
      '(')
        if ((dollar == 1)); then
          stack+=('capture')
        else
          stack+=('subshell')
        fi
        ;;
      ')')
        # Only a `)` with a paren marker on top pops. A case-pattern `)`
        # terminates a pattern list and has no opener, so popping on it would
        # discard whatever span encloses the `case` -- the loop body itself,
        # for a `case` written inside one. Requiring a paren marker on top
        # makes the distinction without parsing `case`/`esac` wherever a
        # body/cond/head or backtick marker, or nothing, is on top. A `case`
        # written directly inside `$( )` or `( )` is not told apart: its
        # pattern `)` finds the paren marker and pops it.
        if ((${#stack[@]} > 0)) && [[ "${stack[${#stack[@]} - 1]}" == 'subshell' ||
          "${stack[${#stack[@]} - 1]}" == 'capture' ]]; then
          unset 'stack[${#stack[@]}-1]'
        fi
        ;;
      '`')
        if ((${#stack[@]} > 0)) && [[ "${stack[${#stack[@]} - 1]}" == 'backtick' ]]; then
          unset 'stack[${#stack[@]}-1]'
        else
          stack+=('backtick')
        fi
        ;;
    esac
    if [[ "${token}" == *'$' ]]; then
      dollar=1
    else
      dollar=0
    fi
    # The close of a substitution ends a word, not a command, unless the word is an assignment
    # (`FOO=$(true) break`): that leaves command position where it was.
    if [[ "${kind}" == 'close' ]]; then
      at_cmd="${closed_assign}"
    elif tokens::is_operator "${token}" || tokens::is_keyword "${token}"; then
      at_cmd=1
    else
      at_cmd=0
    fi
    idx="$((idx + 1))"
  done <<< "${tokens}"
  printf 'none\n'
}

# @description True when the loop body enclosing an invocation contains a break, exit or return in
#              command position, which makes a body-position pgrep the effective termination test.
#              A `$(`, a backtick, or a plain `(` opens a scope barrier, mirroring loops::loop_context: a
#              `do`/`done`/`break` inside a substitution belongs to the shell that substitution runs,
#              so it must neither pop the enclosing body's depth nor count as its terminator. Without
#              the barrier a literal `done` inside `$( )` zeroed the depth and hid a real `break` that
#              followed it, and loops::loop_context (which has the barrier) answered `body` for the same
#              command -- two readers of one structure disagreeing (#8). The barrier is opaque in
#              both directions: while one is open, every loop keyword is ignored.
# @arg $1 command the raw command string
# @arg $2 tokens the token stream from scanner::scan_command
# @arg $3 target index of the invocation token
# @exitcode 0 a terminator is present in the enclosing body
# @exitcode 1 no terminator
function loops::body_has_terminator() {
  local -r command="$1" tokens="$2" target="$3"
  local depth=0 seen=0 at_cmd=1 idx=0 dollar=0 offset token redir='' kind closed_assign=0
  local -a word_assign=()
  local -a barrier=()
  local -A region=()
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    ((idx == target)) && seen=1
    tokens::region_step "${command}" "${offset}" "${token}" region kind
    closed_assign=0
    case "${kind}" in
      'P' | 'A' | 'B' | 'S')
        if tokens::region_opens_assignment_value region "${kind}" "${offset}"; then
          word_assign+=(1)
        else
          word_assign+=(0)
        fi
        ;;
      'close')
        closed_assign="${word_assign[-1]}"
        unset 'word_assign[-1]'
        ;;
    esac
    # A redirection in front of a terminator (`>f break`) leaves command position as it was.
    if tokens::redirection_step "${token}" redir; then
      idx="$((idx + 1))"
      continue
    fi
    if ((at_cmd == 1 && ${#barrier[@]} == 0)); then
      case "${token}" in
        'do') depth="$((depth + 1))" ;;
        'done')
          ((seen == 1 && depth > 0)) && return 1
          ((depth > 0)) && depth="$((depth - 1))"
          ;;
        'break' | 'exit' | 'return') ((depth > 0)) && return 0 ;;
      esac
    fi
    case "${token}" in
      '(')
        if ((dollar == 1)); then
          barrier+=('capture')
        else
          barrier+=('subshell')
        fi
        ;;
      ')')
        # Same rule as loops::loop_context: a case-pattern `)` has no opener and must
        # not pop anything.
        if ((${#barrier[@]} > 0)) && [[ "${barrier[${#barrier[@]} - 1]}" == 'subshell' ||
          "${barrier[${#barrier[@]} - 1]}" == 'capture' ]]; then
          unset 'barrier[${#barrier[@]}-1]'
        fi
        ;;
      '`')
        if ((${#barrier[@]} > 0)) && [[ "${barrier[${#barrier[@]} - 1]}" == 'backtick' ]]; then
          unset 'barrier[${#barrier[@]}-1]'
        else
          barrier+=('backtick')
        fi
        ;;
    esac
    if [[ "${token}" == *'$' ]]; then
      dollar=1
    else
      dollar=0
    fi
    # The close of a substitution ends a word, not a command, unless the word is an assignment
    # (`FOO=$(true) break`): that leaves command position where it was.
    if [[ "${kind}" == 'close' ]]; then
      at_cmd="${closed_assign}"
    elif tokens::is_operator "${token}" || tokens::is_keyword "${token}"; then
      at_cmd=1
    else
      at_cmd=0
    fi
    idx="$((idx + 1))"
  done <<< "${tokens}"
  return 1
}

# @description True when the do/done body belonging to the `for`/`select`/`while`/`until` head at
#              head_idx contains `kill` in command position. Covers the idioms where `kill` is not
#              adjacent to the invocation in the token stream at all, so the rest of this guard's
#              kill detection (which looks for `kill` next to or piped from the invocation) cannot
#              see it: `for pid in $(pgrep -f java); do kill "$pid"; done` (head_idx is the `in`
#              token, invoked from the backward scan) and `pgrep -f java | while read -r p; do kill
#              "$p"; done` (head_idx is the `while` token itself, invoked from the forward pipeline
#              scan). Either way this walks forward past the head's condition/iterable list to find
#              the matching `do`, then scans that body (respecting nested do/done depth, the way
#              loops::body_has_terminator does) for a command-position `kill`. A loop whose body never
#              kills (`for f in $(pgrep -f java); do echo "$f"; done`) must return 1 so the caller
#              falls through to the ordinary warn path.
# @arg $1 tokens_var name of the caller's token array
# @arg $2 openers_var name of the caller's array mapping the index of each token that closes a
#         region to the index of the token that opened it
# @arg $3 head_idx index of the `in`/`while`/`until` token whose body's `do` follows
# @exitcode 0 the loop body kills
# @exitcode 1 it does not, or no body was found
function loops::loop_body_has_kill() {
  local -n toks="$1"
  local -r tokens_var="$1" openers_var="$2" head_idx="$3"
  # shellcheck disable=SC2034 # written through tokens::redirection_step's nameref, which shellcheck cannot follow
  local idx="$((head_idx + 1))" token found_do=0 body_depth=1 at_cmd=1 redir=''
  local -a pstack=()

  # Walk the condition/iterable list to the `do` that opens this loop's body,
  # tracking any nested `$(...)`/backtick/subshell depth so a `do` inside one
  # of those (a real nested loop, or just literal text) is not mistaken for
  # this loop's.
  while ((idx < ${#toks[@]})); do
    token="${toks[idx]}"
    case "${token}" in
      '(') pstack+=('p') ;;
      ')') ((${#pstack[@]} > 0)) && unset 'pstack[${#pstack[@]}-1]' ;;
      '`')
        if ((${#pstack[@]} > 0)) && [[ "${pstack[${#pstack[@]} - 1]}" == 'b' ]]; then
          unset 'pstack[${#pstack[@]}-1]'
        else
          pstack+=('b')
        fi
        ;;
    esac
    if ((${#pstack[@]} == 0)) && [[ "${token}" == 'do' ]]; then
      found_do=1
      idx="$((idx + 1))"
      break
    fi
    idx="$((idx + 1))"
  done
  ((found_do == 1)) || return 1

  while ((idx < ${#toks[@]})); do
    token="${toks[idx]}"
    # A redirection in front of the `kill` (`>f kill "$p"`) leaves command position as it was.
    if tokens::redirection_step "${token}" redir; then
      idx="$((idx + 1))"
      continue
    fi
    if ((at_cmd == 1)); then
      case "${token}" in
        'do') body_depth="$((body_depth + 1))" ;;
        'done')
          body_depth="$((body_depth - 1))"
          ((body_depth == 0)) && return 1
          ;;
        'kill') return 0 ;;
      esac
    fi
    # The close of a substitution ends a word, not a command, unless the word is an assignment.
    if tokens::is_word_region_close "${tokens_var}" "${openers_var}" "${idx}"; then
      at_cmd=0
    elif tokens::is_operator "${token}" || tokens::is_keyword "${token}"; then
      at_cmd=1
    else
      at_cmd=0
    fi
    idx="$((idx + 1))"
  done
  return 1
}
