# shellcheck shell=bash
#
# Whether a pgrep result is consumed, captured, or fed to a kill, sourced by
# hooks/pgrep-pkill-guard-body.sh once the entry script's prefilter has let a
# payload through. Never executed: no shebang, no exec bit, and it must not
# set `set -Eeuo pipefail`, `IFS`, or the ERR trap -- the entry script owns
# all three, and a sourced file that sets them reconfigures its caller. Never
# add `shopt -s inherit_errexit` (invariant 2). POSIX short flags, not GNU
# long options: this runs on BSD userland too (invariant 1).

# xargs options that take their value as a SEPARATE word, so that word is data
# rather than the command xargs will run. Only options whose argument is
# mandatory belong here. GNU spells three of these with an OPTIONAL argument
# (`-e`, `-i`, `-l`), which the shell can only attach (`-i%`), never separate --
# so `xargs -i kill {}` runs kill, and listing them would swallow the very
# command word this scan exists to find. Over-consuming hides a kill; under-
# consuming only costs a warn, so the doubtful cases stay out.
# `-J` is BSD/macOS-only and has no GNU meaning, so it is safe to carry here.
readonly -a XARGS_VALUE_OPTIONS=(
  '-a' '--arg-file' '-d' '--delimiter' '-E' '-I' '-J' '-L' '-n' '--max-args'
  '-P' '--max-procs' '-s' '--max-chars' '--process-slot-var'
)

# @description True when a token is an xargs option that consumes the following word as its value.
#              Matches the exact option only: an attached spelling (`-n1`, `--max-args=1`) carries
#              its own value and must not also eat the next word.
# @arg $1 token the token to test
# @exitcode 0 the token is such an option
# @exitcode 1 it is not
function consumption::is_xargs_value_option() {
  local -r token="$1"
  local option
  for option in "${XARGS_VALUE_OPTIONS[@]}"; do
    [[ "${token}" == "${option}" ]] && return 0
  done
  return 1
}

# @description True when an invocation's output is piped into a kill, or when the invocation is
# @description Forward form of consumption::feeds_a_kill: the invocation's output is piped, directly or through
#              `xargs`, into a `kill`. `kill` must head a pipeline segment, or follow an `xargs` that
#              heads one, with flags and prefix words allowed in between: `pgrep --full x | grep -i
#              kill` merely searches for the word and kills nothing. A segment headed by
#              `while`/`until` (`pgrep -f java | while read -r p; do kill "$p"; done`) defers to
#              loops::loop_body_has_kill rather than being written off as `other`.
# @arg $1 tokens_var name of the caller's token array
# @arg $2 target index of the invocation token
# @exitcode 0 a kill consumes the output downstream
# @exitcode 1 it does not
function consumption::feeds_a_kill_forward() {
  local -n toks="$1"
  local -r tokens_var="$1" target="$2"
  local idx segment='none' word xargs_skip=0 prev='none'
  for ((idx = target + 1; idx < ${#toks[@]}; idx++)); do
    word="${toks[idx]##*/}"
    case "${word}" in
      '|')
        segment='head'
        xargs_skip=0
        prev='|'
        ;;
      ';') break ;;
      '<NL>')
        # A newline after a trailing `|` continues the pipeline -- bash does
        # not end the command there, and the kill is usually on the next line.
        # A newline anywhere else does end it.
        [[ "${prev}" == '|' ]] || break
        ;;
      *)
        prev="${word}"
        case "${segment}" in
          head)
            case "${word}" in
              'kill') return 0 ;;
              'xargs')
                segment='xargs'
                xargs_skip=0
                ;;
              'while' | 'until')
                loops::loop_body_has_kill "${tokens_var}" "${idx}" && return 0
                segment='other'
                ;;
              *)
                if ! tokens::is_prefix_command "${word}"; then
                  segment='other'
                fi
                ;;
            esac
            ;;
          xargs)
            if ((xargs_skip == 1)); then
              # Value word belonging to the option before it, not a command.
              xargs_skip=0
            elif [[ "${word}" == 'kill' ]]; then
              return 0
            elif [[ "${word}" == '{' || "${word}" == '}' ]]; then
              : # `-I{}` placeholder braces, not a new command word
            elif consumption::is_xargs_value_option "${word}"; then
              xargs_skip=1
            elif [[ "${word}" != -* ]] && ! tokens::is_prefix_command "${word}"; then
              segment='other'
            fi
            ;;
        esac
        ;;
    esac
  done
  return 1
}

# @description Whether the `kill` whose predecessor token sits at `index` is in command position.
#              Walks back past prefix commands (`sudo kill`) and assignment words (`FOO=bar kill`);
#              an operator or keyword there means command position. `(` restores command position
#              for a real subshell or grouping construct, but `name=(...)` is an array literal: the
#              `(` merely opens a list of words, and a `kill` immediately inside it is never invoked.
#              The token right before the `(` ending in `=` is what tells the two apart.
# @arg $1 tokens_var name of the caller's token array
# @arg $2 index index of the token immediately before the `kill` word
# @exitcode 0 the kill is in command position
# @exitcode 1 it is an argument word, or sits inside an array literal
function consumption::kill_in_command_position() {
  local -n toks="$1"
  local index="$2"
  while ((index >= 0)); do
    if tokens::is_prefix_command "${toks[index]##*/}" || tokens::is_assignment_word "${toks[index]}"; then
      index=$((index - 1))
      continue
    fi
    if [[ "${toks[index]}" == '(' ]] && ((index > 0)) && [[ "${toks[index - 1]}" == *= ]]; then
      return 1
    fi
    if tokens::is_operator "${toks[index]}" || tokens::is_keyword "${toks[index]}"; then
      return 0
    fi
    return 1
  done
  return 0
}

# @description Backward form of consumption::feeds_a_kill: `kill $(pgrep ...)`, `kill -9 $(pgrep ...)`, and the
#              backtick equivalent. Here `kill` precedes the invocation, so the forward scan cannot
#              see it. Skip the substitution punctuation and any flags on the way back, then require
#              the `kill` to be in command position -- otherwise `echo kill $(...)`, where `kill` is
#              merely an argument word, would be denied. A value word that belongs to a preceding
#              `-s`/`--signal` (`kill -s TERM $(pgrep ...)`) is also skipped rather than treated as an
#              unrecognized stop word: it is recognized by peeking at the token immediately before
#              it, since scanning backward means the value is reached before its flag. A bare `in` is
#              only a for/select head -- and thus worth deferring to loops::loop_body_has_kill -- when the
#              token two back (past the loop variable) is actually `for`/`select`; otherwise it is an
#              ordinary argument word (`echo in $(...)`) and the forward walk in loops::loop_body_has_kill
#              could cross into an unrelated later loop's body.
# @arg $1 tokens_var name of the caller's token array
# @arg $2 target index of the invocation token
# @exitcode 0 a kill consumes the substitution
# @exitcode 1 it does not
function consumption::feeds_a_kill_backward() {
  local -n toks="$1"
  local -r tokens_var="$1" target="$2"
  local word k=$((target - 1))
  while ((k >= 0)); do
    word="${toks[k]##*/}"
    case "${word}" in
      '$' | '(' | '`') ;;
      -*) ;;
      'kill')
        # A bare call whose non-zero status is the verdict: safe only because consumption::feeds_a_kill invokes
        # this function as the right-hand side of `||`, which keeps the whole dynamic extent off
        # errexit's radar. Call it the same way from anywhere new.
        consumption::kill_in_command_position "${tokens_var}" "$((k - 1))"
        return
        ;;
      'in')
        if ((k >= 2)) && { [[ "${toks[k - 2]}" == 'for' ]] || [[ "${toks[k - 2]}" == 'select' ]]; }; then
          loops::loop_body_has_kill "${tokens_var}" "${k}" && return 0
        fi
        return 1
        ;;
      *)
        if ((k > 0)) \
          && { [[ "${toks[k - 1]##*/}" == '-s' ]] || [[ "${toks[k - 1]##*/}" == '--signal' ]]; }; then
          : # signal-name value word for -s/--signal, not a stop word
        else
          return 1
        fi
        ;;
    esac
    k=$((k - 1))
  done
  return 1
}

# @description True when the invocation's output feeds a kill, either forward (`pgrep ... | xargs
#              kill`, `... | while read p; do kill "$p"; done`) or backward (`kill $(pgrep ...)`).
#              The two scans are independent; see consumption::feeds_a_kill_forward and consumption::feeds_a_kill_backward.
# @arg $1 tokens_var name of the caller's token array (built once by classify::classify_command; every
#              invocation in the same command reuses it rather than re-parsing the token stream)
# @arg $2 target index of the invocation token
# @exitcode 0 output feeds a kill
# @exitcode 1 it does not
function consumption::feeds_a_kill() {
  local -r tokens_var="$1" target="$2"
  consumption::feeds_a_kill_forward "${tokens_var}" "${target}" || consumption::feeds_a_kill_backward "${tokens_var}" "${target}"
}

# @description True when an invocation sits inside a command substitution, so its output is captured
#              rather than printed. Counted as a depth over the token stream: a substring test on the
#              raw command prefix cannot tell an enclosing `$(` from an unrelated one that has
#              already closed, which made `for i in $(seq 1 5); do pgrep -af java; ...; done` read as
#              a capture. `$` is not an operator token, so the opener is recognised as any token
#              ending in `$` immediately followed by `(`, which also covers `p=$(...)`.
# @arg $1 tokens_var name of the caller's token array, built once by classify::classify_command
# @arg $2 target index of the invocation token
# @exitcode 0 the invocation is inside a command substitution
# @exitcode 1 it is not
function consumption::invocation_is_captured() {
  local -n toks="$1"
  local -r target="$2"
  local -a stack=()
  local idx dollar=0 token entry
  for ((idx = 0; idx <= target; idx++)); do
    token="${toks[idx]}"
    if ((idx == target)); then
      if ((${#stack[@]} == 0)); then
        return 1
      fi
      for entry in "${stack[@]}"; do
        [[ "${entry}" == 'capture' || "${entry}" == 'backtick' ]] && return 0
      done
      return 1
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
        if ((${#stack[@]} > 0)); then
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
  done
  return 1
}

# @description True when the command immediately after an invocation, in the same list, reads `$?`.
#              That is a consumption of the exit status exactly like `&&` or an enclosing `if`, and
#              the forward scan in consumption::result_is_consumed cannot see it because it stops at the `;` or
#              newline that ends the invocation's own simple command.
#
#              The `$?` test runs against the RAW command text rather than the token stream, because
#              the scanner masks a double-quoted `$?` (`echo "exit=$?"`) down to filler -- the very
#              shape #155 recorded -- and the tokens would show nothing. What the tokens do supply,
#              and a raw substring search could not, are mask-aware separator offsets: only a `;` or
#              newline the scanner saw as real code delimits the segment, so a `;` inside a quoted
#              pattern cannot split it.
#
#              Scope is deliberately one command, not the rest of the list: in `pgrep --full x; echo
#              hi; rc=$?` the status belongs to `echo`, and warning there would be wrong. The cost of
#              reading raw text is a single-quoted literal `$?` counting as a read; that direction
#              only over-warns, and no realistic command writes one right after a pgrep.
# @arg $1 command the raw command string
# @arg $2 tokens the token stream from scanner::scan_command
# @arg $3 target index of the invocation token
# @exitcode 0 the following command reads the exit status
# @exitcode 1 it does not
function consumption::next_command_reads_status() {
  local -r command="$1" tokens="$2" target="$3"
  local idx=0 offset token start=-1 end=-1
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    if ((idx > target)) && { [[ "${token}" == ';' ]] || [[ "${token}" == '<NL>' ]]; }; then
      if ((start < 0)); then
        start=$((offset + 1))
      else
        end="${offset}"
        break
      fi
    fi
    idx=$((idx + 1))
  done <<< "${tokens}"
  ((start < 0)) && return 1
  ((end < 0)) && end="${#command}"
  ((end <= start)) && return 1
  [[ "${command:start:end-start}" == *'$?'* ]]
}

# @description True when an invocation's result is read as a boolean, a count, or captured into a
#              variable, rather than merely displayed. Only then can the silent off-by-one produce a
#              wrong conclusion. Five shapes count: pgrep's own `--count` / `-c`; an enclosing `if`
#              or `elif`, or a leading `!`, which read the exit status as a boolean; a following
#              `&&`, `||`, `| wc` or `| xargs`; sitting inside a command substitution; and the next
#              command in the list reading `$?`, which consumption::next_command_reads_status handles. A
#              redirection target is not consumption: `2>&1` tokenizes as `2>`, `&`, `1`, and a lone
#              trailing `&` is backgrounding rather than a boolean operator.
# @arg $1 tokens_var name of the caller's token array, built once by classify::classify_command
# @arg $2 target index of the invocation token
# @arg $3 args the invocation's argument lines
# @arg $4 command the raw command string, for the `$?` check
# @arg $5 tokens the token stream from scanner::scan_command, for the `$?` check
# @exitcode 0 the result is consumed
# @exitcode 1 the result is only displayed
function consumption::result_is_consumed() {
  local -n toks="$1"
  local -r tokens_var="$1" target="$2" args="$3" command="$4" tokens="$5"
  local offset token
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    [[ "${token}" == '--count' ]] && return 0
    if [[ "${token}" == -[a-zA-Z]* && "${token}" != --* && "${token}" == *c* ]]; then
      return 0
    fi
  done <<< "${args}"

  # An enclosing `if` / `elif`, or a negation, reads the exit status as a boolean.
  # Walk back over prefix words so `if sudo pgrep --full x` still counts.
  #
  # Anything between the invocation and the operator or keyword that opened its
  # command is prefix material by construction: scanner::find_invocations only reports an
  # invocation in command position, so a word reached here is a prefix command,
  # one of its flags, that flag's value, or an assignment word. Testing for a
  # prefix COMMAND alone stopped at the value word and hid the enclosing `if` of
  # `if sudo -u bob pgrep --full x`, `if timeout 5 pgrep --full x` and every
  # other prefix carrying an option or an operand (#132). The prefix-command test
  # stays ahead of the stop test because `time` is both a prefix and a keyword.
  local k=$((target - 1)) word
  while ((k >= 0)); do
    word="${toks[k]##*/}"
    case "${word}" in
      'if' | 'elif' | '!') return 0 ;;
      *)
        if ! tokens::is_prefix_command "${word}" \
          && { tokens::is_operator "${toks[k]}" || tokens::is_keyword "${toks[k]}"; }; then
          break
        fi
        ;;
    esac
    k=$((k - 1))
  done

  local idx prev="${toks[target]}" amp=0 pipe=0
  for ((idx = target + 1; idx < ${#toks[@]}; idx++)); do
    token="${toks[idx]}"
    # A redirection target is not consumption: `2>&1` tokenizes as `2>` `&` `1`.
    # The `<NL>` token is spelled with angle brackets and so ends in `>`: it has
    # to be excluded by name, or the word after a newline-continued pipe reads
    # as a redirection target and is skipped.
    if [[ "${prev}" != '<NL>' && "${prev}" == *[\<\>] ]]; then
      prev="${token}"
      continue
    fi
    case "${token}" in
      '&')
        amp=$((amp + 1))
        ((amp >= 2)) && return 0
        ;;
      '|')
        pipe=$((pipe + 1))
        ((pipe >= 2)) && return 0
        ;;
      'wc' | 'xargs') ((pipe >= 1)) && return 0 ;;
      ';') break ;;
      # As in consumption::feeds_a_kill: a newline right after a trailing `|` continues the
      # pipeline, so `| wc -l` on the next line is still consumption.
      '<NL>') [[ "${prev}" == '|' ]] || break ;;
      *) amp=0 ;;
    esac
    prev="${token}"
  done

  # `p=$(pgrep ...)`: the output is captured rather than printed.
  consumption::invocation_is_captured "${tokens_var}" "${target}" && return 0

  # `pgrep --full x; rc=$?`: the status is read by the next command in the list.
  consumption::next_command_reads_status "${command}" "${tokens}" "${target}" && return 0
  return 1
}
