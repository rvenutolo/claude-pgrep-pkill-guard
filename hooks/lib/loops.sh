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
  local idx=0 at_cmd=1 dollar=0 offset token redir='' kind closed_assign=0 tail_end=-1 glued_tail
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
    glued_tail=0
    ((offset == tail_end && at_cmd == 1)) && glued_tail=1
    tail_end=-1
    case "${kind}" in
      'P' | 'A' | 'B' | 'S')
        if ((glued_tail == 1)) || tokens::region_opens_assignment_value region "${kind}" "${offset}"; then
          word_assign+=(1)
        else
          word_assign+=(0)
        fi
        ;;
      'close')
        closed_assign="${word_assign[-1]}"
        unset 'word_assign[-1]'
        tail_end="${region[end]}"
        ;;
    esac
    # A token touching the close of an assignment's substitution continues that word
    # (`FOO=$(true)$(true) break`, ``FOO=a`true` break``): it leaves command position as it was.
    if ((glued_tail == 1)) && [[ "${kind}" != 'close' ]] && ! tokens::is_operator "${token}"; then
      tail_end="${region[end]}"
      dollar=0
      [[ "${token}" == *'$' ]] && dollar=1
      idx="$((idx + 1))"
      continue
    fi
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
    elif tokens::is_operator "${token}" || tokens::is_keyword "${token}" \
      || { ((at_cmd == 1)) && [[ "${token}" == 'coproc' ]]; }; then
      # `coproc while ...` is still a loop: the reserved word keeps command position.
      at_cmd=1
    else
      at_cmd=0
    fi
    idx="$((idx + 1))"
  done <<< "${tokens}"
  printf 'none\n'
}

# @description True when a break, exit or return found inside a loop body can end the loop whose
#              body is asked about. Each body is known by an id, and a path is the ids of the bodies
#              open at a token, outermost first. A terminator whose path does not hold the body sits
#              outside it. An `exit` or `return` anywhere inside the body ends its loop. A `break`
#              leaves one loop for each count, its own first, so it reaches the body's loop only
#              when its count exceeds the number of loops nested inside the body around it.
# @arg $1 kind `break`, `exit` or `return`
# @arg $2 count the count of a `break`, in decimal with no leading zero; ignored for the others
# @arg $3 path the ids of the bodies open at the terminator, space-separated, outermost first
# @arg $4 body the id of the body asked about
# @exitcode 0 the terminator ends that body's loop
# @exitcode 1 it does not
function loops::terminator_ends_body() {
  local -r kind="$1" count="$2" path="$3" body="$4"
  local -a ids=()
  local position found=-1
  # The entry script's IFS has no space in it.
  IFS=' ' read -r -a ids <<< "${path}"
  for position in "${!ids[@]}"; do
    if [[ "${ids[position]}" == "${body}" ]]; then
      found="${position}"
    fi
  done
  ((found >= 0)) || return 1
  [[ "${kind}" == 'break' ]] || return 0
  if ((count > ${#ids[@]} - 1 - found)); then
    return 0
  fi
  return 1
}

# @description True when the loop body enclosing an invocation contains a break, exit or return in
#              command position, which makes a body-position pgrep the effective termination test.
#              The body is the innermost one that holds the invocation. A terminator counts when it
#              can end that body's loop, as loops::terminator_ends_body decides. It may stand before
#              the invocation or after it, after a nested loop has closed, or inside a nested loop.
#              One in a loop that closed before this body opened, in a loop that opens after it
#              closes, or in a body around it does not count. A `break` with no count leaves its own
#              loop; one whose count the text does not give as a small number (`break "2"`,
#              `break $n`, `break 0`) is taken to leave every loop.
#              A `$(`, a backtick, or a plain `(` opens a scope barrier, mirroring loops::loop_context: a
#              `do`/`done`/`break` inside a substitution belongs to the shell that substitution runs,
#              so it must neither close the enclosing body nor count as its terminator. Without
#              the barrier a literal `done` inside `$( )` closed the body and hid a real `break` that
#              followed it, and loops::loop_context (which has the barrier) answered `body` for the same
#              command -- two readers of one structure disagreeing (#8). The barrier is opaque in
#              both directions for the bodies: the ones open outside it are set aside while it is
#              open, so a loop keyword inside can neither close nor end them, and the bodies opened
#              inside it are dropped when it closes. A loop that sits wholly inside a barrier has
#              its own body there, and only a terminator inside the same barrier can end it. An
#              invocation inside a barrier with no loop of its own around it there belongs to the
#              nearest body outside, as it does for loops::loop_context.
# @arg $1 command the raw command string
# @arg $2 tokens the token stream from scanner::scan_command
# @arg $3 target index of the invocation token
# @exitcode 0 a terminator in the enclosing body can end its loop
# @exitcode 1 none can
function loops::body_has_terminator() {
  local -r command="$1" tokens="$2" target="$3"
  local seen=0 at_cmd=1 idx=0 dollar=0 offset token redir='' kind closed_assign=0 tail_end=-1 glued_tail
  local next_body=0 body='' pending='' count record
  local -a word_assign=()
  local -a barrier=()
  # The ids of the open bodies, outermost first, each written as a space and the id, and the
  # terminators met before the invocation, one `kind:count:path` row each. `scopes` holds the
  # bodies set aside at each open barrier, one entry a barrier.
  local open='' scope
  local -a earlier=() scopes=()
  # shellcheck disable=SC2034 # read through tokens::region_opens_assignment_value's nameref
  local -A region=()
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    if [[ -n "${pending}" ]]; then
      # The word after a `break` is its count. An operator or a redirection there means it has
      # none. A count that is not a small literal number (`"2"`, `--`, `$n`, `0`, which bash
      # rejects by leaving every loop) is read as one no nesting outlasts.
      if tokens::is_operator "${token}" || [[ "${token}" =~ ${REDIRECTION_OPERATOR_RE} ]]; then
        count=1
      elif [[ "${token}" =~ ^0*([1-9][0-9]{0,3})$ ]]; then
        count="${BASH_REMATCH[1]}"
      else
        count=10000
      fi
      if ((seen == 0)); then
        earlier+=("break:${count}:${pending}")
      elif loops::terminator_ends_body 'break' "${count}" "${pending}" "${body}"; then
        return 0
      fi
      pending=''
    fi
    if ((idx == target)); then
      seen=1
      # The innermost body: one open in this scope, or else in the nearest scope around it.
      body="${open##* }"
      for ((scope = ${#scopes[@]} - 1; scope >= 0; scope--)); do
        [[ -z "${body}" ]] || break
        body="${scopes[scope]##* }"
      done
      # No body is open: nothing here is a terminator of the invocation's loop.
      [[ -n "${body}" ]] || return 1
      for record in "${earlier[@]}"; do
        IFS=':' read -r kind count pending <<< "${record}"
        loops::terminator_ends_body "${kind}" "${count}" "${pending}" "${body}" && return 0
      done
      pending=''
    fi
    tokens::region_step "${command}" "${offset}" "${token}" region kind
    closed_assign=0
    glued_tail=0
    ((offset == tail_end && at_cmd == 1)) && glued_tail=1
    tail_end=-1
    case "${kind}" in
      'P' | 'A' | 'B' | 'S')
        if ((glued_tail == 1)) || tokens::region_opens_assignment_value region "${kind}" "${offset}"; then
          word_assign+=(1)
        else
          word_assign+=(0)
        fi
        ;;
      'close')
        closed_assign="${word_assign[-1]}"
        unset 'word_assign[-1]'
        tail_end="${region[end]}"
        ;;
    esac
    # A token touching the close of an assignment's substitution continues that word
    # (`FOO=$(true)$(true) break`, ``FOO=a`true` break``): it leaves command position as it was.
    if ((glued_tail == 1)) && [[ "${kind}" != 'close' ]] && ! tokens::is_operator "${token}"; then
      tail_end="${region[end]}"
      dollar=0
      [[ "${token}" == *'$' ]] && dollar=1
      idx="$((idx + 1))"
      continue
    fi
    # A redirection in front of a terminator (`>f break`) leaves command position as it was.
    if tokens::redirection_step "${token}" redir; then
      idx="$((idx + 1))"
      continue
    fi
    if ((at_cmd == 1)); then
      case "${token}" in
        'do')
          next_body="$((next_body + 1))"
          open+=" ${next_body}"
          ;;
        'done')
          if [[ -n "${open}" ]]; then
            # The invocation's own body closing ends the search: nothing behind it is in the body.
            if ((seen == 1)) && [[ "${open##* }" == "${body}" ]]; then
              return 1
            fi
            open="${open% *}"
          fi
          ;;
        'break') pending="${open}" ;;
        'exit' | 'return')
          if [[ -n "${open}" ]]; then
            if ((seen == 0)); then
              earlier+=("${token}:0:${open}")
            elif loops::terminator_ends_body "${token}" 0 "${open}" "${body}"; then
              return 0
            fi
          fi
          ;;
      esac
    fi
    case "${token}" in
      '(')
        if ((dollar == 1)); then
          barrier+=('capture')
        else
          barrier+=('subshell')
        fi
        scopes+=("${open}")
        open=''
        ;;
      ')')
        # Same rule as loops::loop_context: a case-pattern `)` has no opener and must
        # not pop anything.
        if ((${#barrier[@]} > 0)) && [[ "${barrier[${#barrier[@]} - 1]}" == 'subshell' ||
          "${barrier[${#barrier[@]} - 1]}" == 'capture' ]]; then
          unset 'barrier[${#barrier[@]}-1]'
          open="${scopes[${#scopes[@]} - 1]}"
          unset 'scopes[${#scopes[@]}-1]'
        fi
        ;;
      '`')
        if ((${#barrier[@]} > 0)) && [[ "${barrier[${#barrier[@]} - 1]}" == 'backtick' ]]; then
          unset 'barrier[${#barrier[@]}-1]'
          open="${scopes[${#scopes[@]} - 1]}"
          unset 'scopes[${#scopes[@]}-1]'
        else
          barrier+=('backtick')
          scopes+=("${open}")
          open=''
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
    elif tokens::is_operator "${token}" || tokens::is_keyword "${token}" \
      || { ((at_cmd == 1)) && [[ "${token}" == 'coproc' ]]; }; then
      # `coproc while ...` is still a loop: the reserved word keeps command position.
      at_cmd=1
    else
      at_cmd=0
    fi
    idx="$((idx + 1))"
  done <<< "${tokens}"
  # A `break` that is the last word of the command.
  if [[ -n "${pending}" ]] && ((seen == 1)); then
    loops::terminator_ends_body 'break' 1 "${pending}" "${body}" && return 0
  fi
  return 1
}

# @description Find the `do` that opens the loop body a given `done` closes. The stream is walked
#              from its start, with the command position loops::loop_body_has_kill tracks, so a
#              `do` or `done` that is an argument word (`echo done`) opens and closes nothing.
#              Bash also reads the keywords in two places that are not command position here: a
#              `do` behind a loop variable (`for x do`), and a `done` directly behind the word
#              that closes a compound command (`fi done`, `esac done`, `done done`). A `done`
#              with no body open before the one asked about is passed over.
# @arg $1 tokens_var name of the caller's token array
# @arg $2 openers_var name of the caller's array mapping the index of each token that closes a
#         region to the index of the token that opened it
# @arg $3 done_idx index of the `done` token
# @stdout the index of the matching `do`
# @exitcode 0 the `done` closes a body
# @exitcode 1 it does not: it is no keyword there, or no `do` is open at it
function loops::done_body_start() {
  local -n toks="$1"
  local -r tokens_var="$1" openers_var="$2" done_idx="$3"
  # shellcheck disable=SC2034 # written through tokens::redirection_step's nameref, which shellcheck cannot follow
  local idx=0 token at_cmd=1 redir=''
  local -a starts=()
  while ((idx <= done_idx)); do
    token="${toks[idx]}"
    if tokens::redirection_step "${token}" redir; then
      idx="$((idx + 1))"
      continue
    fi
    case "${token}" in
      'do')
        if ((at_cmd == 1)) \
          || { ((idx >= 2)) && [[ "${toks[idx - 2]}" == 'for' || "${toks[idx - 2]}" == 'select' ]]; }; then
          starts+=("${idx}")
        fi
        ;;
      'done')
        if ((at_cmd == 1)) \
          || { ((idx >= 1)) && [[ "${toks[idx - 1]}" == 'fi' || "${toks[idx - 1]}" == 'esac' ||
            "${toks[idx - 1]}" == 'done' ]]; }; then
          if ((idx == done_idx)); then
            ((${#starts[@]} > 0)) || return 1
            printf '%s' "${starts[${#starts[@]} - 1]}"
            return 0
          fi
          if ((${#starts[@]} > 0)); then
            unset 'starts[${#starts[@]}-1]'
          fi
        fi
        ;;
    esac
    if tokens::is_word_region_close "${tokens_var}" "${openers_var}" "${idx}"; then
      at_cmd=0
    elif tokens::is_operator "${token}" || tokens::is_keyword "${token}" \
      || { ((at_cmd == 1)) && [[ "${token}" == 'coproc' ]]; }; then
      at_cmd=1
    else
      at_cmd=0
    fi
    idx="$((idx + 1))"
  done
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
#              the matching `do`, then scans that body (respecting nested do/done depth) for a
#              command-position `kill`, as
#              scanner::find_invocations recorded them, so one behind a prefix and its options
#              (`do sudo -u root kill "$p"`) counts. A loop whose body never
#              kills (`for f in $(pgrep -f java); do echo "$f"; done`) must return 1 so the caller
#              falls through to the ordinary warn path.
# @arg $1 tokens_var name of the caller's token array
# @arg $2 openers_var name of the caller's array mapping the index of each token that closes a
#         region to the index of the token that opened it
# @arg $3 kills_var name of the caller's array holding an entry at the index of every `kill` in
#         command position
# @arg $4 head_idx index of the `in`/`while`/`until` token whose body's `do` follows
# @exitcode 0 the loop body kills
# @exitcode 1 it does not, or no body was found
function loops::loop_body_has_kill() {
  local -n toks="$1"
  local -n kills="$3"
  local -r tokens_var="$1" openers_var="$2" head_idx="$4"
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
    # A redirection in front of a loop keyword (`>f done`) leaves command position as it was.
    if tokens::redirection_step "${token}" redir; then
      idx="$((idx + 1))"
      continue
    fi
    if [[ -n "${kills[idx]:-}" ]]; then
      return 0
    fi
    if ((at_cmd == 1)); then
      case "${token}" in
        'do') body_depth="$((body_depth + 1))" ;;
        'done')
          body_depth="$((body_depth - 1))"
          ((body_depth == 0)) && return 1
          ;;
      esac
    fi
    # The close of a substitution ends a word, not a command, unless the word is an assignment.
    if tokens::is_word_region_close "${tokens_var}" "${openers_var}" "${idx}"; then
      at_cmd=0
    elif tokens::is_operator "${token}" || tokens::is_keyword "${token}" \
      || { ((at_cmd == 1)) && [[ "${token}" == 'coproc' ]]; }; then
      # `coproc while ...` is still a loop: the reserved word keeps command position.
      at_cmd=1
    else
      at_cmd=0
    fi
    idx="$((idx + 1))"
  done
  return 1
}
