# shellcheck shell=bash
#
# Command-position and prefix-command token helpers, sourced by
# hooks/pgrep-pkill-guard-body.sh whenever the entry script loads the body --
# in human mode, or once the prefilter has let a payload through. Never
# executed: no shebang, no exec bit, and it must not set `set -Eeuo pipefail`,
# `IFS`, or the ERR trap -- the entry script owns them all, and a sourced file
# that sets them reconfigures its caller. Never add `shopt -s inherit_errexit`
# (invariant 2). Long options only where the BSD tool has them: this runs on
# BSD userland too (invariant 1).

# Keywords after which the guard treats the next word as being in command
# position. For `for` and `select` that word is the loop variable's name,
# not a command.
readonly -a COMMAND_POSITION_KEYWORDS=(
  'do' 'then' 'else' 'elif' 'while' 'until' 'if' 'for' 'select' '!' 'time'
)

# Words that run another command and so preserve command position for the word
# after them. `sudo pkill --full java` is the single most likely session-killing
# form, so the guard must see through the prefix -- and through the prefix's own
# options, which is what tokens::prefix_chain_step below is for. `timeout` belongs here
# for the same reason the others do: `timeout 5 pkill --full java` runs the kill.
readonly -a PREFIX_COMMANDS=('sudo' 'doas' 'env' 'nohup' 'command' 'time' 'timeout')

# @description True when a token is a command prefix that keeps the following word in command
#              position.
# @arg $1 token the token to test
# @exitcode 0 the token is a prefix command
# @exitcode 1 it is not
function tokens::is_prefix_command() {
  local -r token="$1"
  local prefix
  for prefix in "${PREFIX_COMMANDS[@]}"; do
    [[ "${token}" == "${prefix}" ]] && return 0
  done
  return 1
}

# @description True when an option of a prefix command consumes the NEXT word, so that word is the
#              option's value rather than the command. `--opt=value` needs no entry: an attached
#              value is a single word.
#
#              An option missing from this table leaks -- with no operand budget to absorb it, its
#              value is read as the command word itself, which ends the chain and hides the real
#              command behind it. The `sudo` entries are its whole synopsis. That leak is the
#              fail-open direction, and it is the deliberate trade: an operand budget generous
#              enough to swallow an unknown option's value would read the `pkill` of
#              `sudo deploy.sh pkill x` as a command and deny one bash never runs.
# @arg $1 prefix the prefix command, already reduced to its basename
# @arg $2 word the option word to test
# @exitcode 0 the option consumes the next word
# @exitcode 1 it does not
function tokens::prefix_value_option() {
  local -r prefix="$1" word="$2"
  case "${prefix}" in
    'sudo')
      case "${word}" in
        '-u' | '-g' | '-p' | '-C' | '-D' | '-h' | '-R' | '-r' | '-T' | '-t' | '-U' | '--user' | \
          '--group' | '--prompt' | '--close-from' | '--chdir' | '--host' | '--chroot' | \
          '--role' | '--command-timeout' | '--type' | '--other-user')
          return 0
          ;;
        *) return 1 ;;
      esac
      ;;
    'doas')
      case "${word}" in
        '-u' | '-C' | '-a') return 0 ;;
        *) return 1 ;;
      esac
      ;;
    'env')
      case "${word}" in
        '-u' | '--unset' | '-C' | '--chdir' | '-S' | '--split-string') return 0 ;;
        *) return 1 ;;
      esac
      ;;
    'timeout')
      case "${word}" in
        '-s' | '--signal' | '-k' | '--kill-after') return 0 ;;
        *) return 1 ;;
      esac
      ;;
    'time')
      case "${word}" in
        '-o' | '--output' | '-f' | '--format') return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# @description How many non-flag operands a prefix command takes before the command word.
#
#              Only `timeout` has any: its duration. Every other prefix takes none, so its first
#              non-flag word IS the command -- which is what keeps `sudo deploy.sh pkill x`, where
#              `pkill` is an argument to the script, from reading as a kill.
# @arg $1 prefix the prefix command
# @stdout the operand count
function tokens::prefix_operand_budget() {
  case "$1" in
    'timeout') printf '1' ;;
    *) printf '0' ;;
  esac
}

# @description True when an option makes its prefix run no command at all, so the words after it
#              are not in command position. `command -v pkill` prints a path and `sudo -l pkill`
#              reports whether a rule allows it; neither runs anything. Without this, teaching the
#              chain to see past a prefix's flags would turn both of those allows into false denies.
#
#              The table is deliberately partial: it holds the spellings a person actually types.
#              Every omission (`sudo -K`, `env --help`, ...) costs a false deny, never a false
#              allow, so completeness here buys much less than it does in tokens::prefix_value_option.
# @arg $1 prefix the prefix command
# @arg $2 word the option word to test
# @exitcode 0 the option ends the chain
# @exitcode 1 it does not
function tokens::prefix_breaks_chain() {
  local -r prefix="$1" word="$2"
  case "${prefix}" in
    'command')
      case "${word}" in
        '-v' | '-V') return 0 ;;
        *) return 1 ;;
      esac
      ;;
    'sudo')
      case "${word}" in
        '-l' | '--list' | '-v' | '--validate' | '-e' | '--edit' | '-V' | '--version') return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# @description Advance command-position tracking by one token and report whether the word AFTER it
#              is in command position. This is the whole prefix-chain rule, in one place because
#              scanner::find_invocations and wrappers::shell_wrapper_payloads both need it and a second copy would
#              drift.
#
#              An operator or keyword restores command position and clears the chain, except that a
#              `|` leaves the sentinel `pipe` in it, because `time` is the reserved word only in a
#              pipeline's first command. An assignment word in command position leaves the sentinel
#              `assignment` for the same reason, and the reserved word itself leaves
#              `time-builtin`. A prefix word opens a chain. Inside a chain, the prefix's own flags
#              keep command position for what follows, a flag's value is skipped without ever being
#              in command position itself (`env -u pkill cmd` unsets a variable, it does not run
#              one), `--` ends the flags, and the operands the prefix is entitled to are spent one
#              per word. The first word that is none of those IS the command, so the chain ends
#              there. An option that makes the prefix run nothing ends it too.
# @arg $1 token the raw token
# @arg $2 word the token reduced to its basename
# @arg $3 at_cmd 1 when this token is itself in command position
# @arg $4 chain name of the caller's variable holding the prefix in effect, or one of the sentinels
#         `pipe`, `assignment`, `time-builtin` and `--`, which match no prefix; empty when neither
# @arg $5 skip name of the caller's variable marking the next word as a flag's value
# @arg $6 operands name of the caller's variable holding the chain's remaining operand budget
# @exitcode 0 the next word is in command position
# @exitcode 1 it is not
function tokens::prefix_chain_step() {
  local -r token="$1" word="$2" at_cmd="$3"
  # Namerefs must not share a name with the caller's variable, or bash refuses
  # the assignment as a circular reference, so each carries a _ref suffix. The
  # positional locals are equally unsafe as caller names: never pass a variable
  # called token, word, or at_cmd to this function by name.
  local -n chain_ref="$4" skip_ref="$5" operands_ref="$6"
  if tokens::is_operator "${token}"; then
    # Every operator restores command position, but a pipe leaves a sentinel
    # behind: `time` may prefix only the FIRST command of a pipeline, so past a
    # `|` it is an ordinary word PATH resolves to GNU time. The `&` arm keeps
    # that sentinel so `|&` reads like the `|` it extends, while a `&` on its
    # own still starts a command where the reserved word is legal. The scanner
    # emits `||` as two `|` tokens, so the sentinel follows `||` as well, even
    # though `time` is the reserved word there.
    if [[ "${token}" == '|' ]] || [[ "${token}" == '&' && "${chain_ref}" == 'pipe' ]]; then
      chain_ref='pipe'
    else
      chain_ref=''
    fi
    skip_ref=0
    operands_ref=0
    return 0
  fi
  if ((skip_ref == 1)); then
    skip_ref=0
    return 0
  fi
  # Only a prefix or assignment that is itself in command position chains: in
  # `git command x` the word `command` is an argument, not a prefix. The prefix
  # test runs before the keyword test because `time` is both, and only the
  # prefix reading understands its `-o file`.
  if ((at_cmd == 1)) && tokens::is_prefix_command "${word}"; then
    # `time` is bash's reserved word only as the very first word of a command:
    # `time -o f cmd` runs `-o`, not GNU time. Behind a prefix (`env time`,
    # `sudo -u bob time`) or an assignment (`FOO=1 time`) the word is one those
    # resolve through PATH, which is GNU time and does understand `-o` -- hence
    # the empty-chain test, the assignment sentinel below being what makes the
    # assignment case work. A path spelling (`/usr/bin/time`) is never the reserved
    # word either. The sentinel keeps the reserved word's own `-p` in command
    # position while matching no arm of either table.
    if [[ "${token}" == 'time' && -z "${chain_ref}" ]]; then
      chain_ref='time-builtin'
    else
      chain_ref="${word}"
    fi
    skip_ref=0
    operands_ref="$(tokens::prefix_operand_budget "${word}")"
    return 0
  fi
  if tokens::is_keyword "${token}"; then
    chain_ref=''
    skip_ref=0
    operands_ref=0
    return 0
  fi
  if ((at_cmd != 1)); then
    chain_ref=''
    return 1
  fi
  if tokens::is_assignment_word "${token}"; then
    # An assignment is not a chain, but it does mean the next word is no longer
    # the command's first: `FOO=1 time ...` runs GNU time, not the reserved
    # word. The sentinel records that and matches no arm of either table.
    [[ -z "${chain_ref}" ]] && chain_ref='assignment'
    return 0
  fi
  if [[ -z "${chain_ref}" ]]; then
    return 1
  fi
  if [[ "${token}" == '--' ]]; then
    # Past the terminator nothing is a flag any more, so `timeout -- -k 5 cmd`
    # takes `-k` as its duration, not as a kill-after option. The chain stays
    # open because the operands the prefix is entitled to still come first:
    # `timeout -- 5 cmd` runs cmd. The sentinel matches no arm of either table.
    chain_ref='--'
    return 0
  fi
  if [[ "${chain_ref}" != '--' ]]; then
    if tokens::prefix_breaks_chain "${chain_ref}" "${word}"; then
      chain_ref=''
      return 1
    fi
    if [[ "${word}" == -* ]]; then
      # A flag's value is never itself in command position, but the word after
      # it is; a flag that takes no value keeps command position directly.
      if tokens::prefix_value_option "${chain_ref}" "${word}"; then
        skip_ref=1
        return 1
      fi
      return 0
    fi
  fi
  if ((operands_ref > 0)); then
    operands_ref="$((operands_ref - 1))"
    return 0
  fi
  chain_ref=''
  return 1
}

# @description True when a token is a shell variable-assignment word (`FOO=bar`, `LC_ALL=C`,
#              `FOO+=bar`, `FOO[1]=bar`, ...).
#              Tested against the raw token rather than its basename: unlike a prefix command, an
#              assignment's value routinely contains a `/` (`PATH=/usr/bin cmd`), and stripping to
#              the basename there would corrupt the match.
# @arg $1 token the token to test
# @exitcode 0 the token is a shell assignment word
# @exitcode 1 it is not
function tokens::is_assignment_word() {
  local -r token="$1"
  [[ "${token}" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=.*$ ]]
}

# @description True when a token is a shell keyword after which the next word is again in
#              command position.
# @arg $1 token the token to test
# @exitcode 0 the token is such a keyword
# @exitcode 1 it is not
function tokens::is_keyword() {
  local -r token="$1"
  local keyword
  for keyword in "${COMMAND_POSITION_KEYWORDS[@]}"; do
    [[ "${token}" == "${keyword}" ]] && return 0
  done
  return 1
}

# @description True when a token is a shell operator that ends a simple command. The backtick
#              counts: the scanner emits it as a standalone token and it restores command position.
# @arg $1 token the token to test
# @exitcode 0 the token is an operator
# @exitcode 1 it is not
function tokens::is_operator() {
  case "$1" in
    ';' | '&' | '|' | '(' | ')' | '{' | '}' | '<NL>' | '`') return 0 ;;
    *) return 1 ;;
  esac
}

# A redirection operator token: an optional file descriptor and then a run of
# `<` and `>` (`>`, `>>`, `<>`, `<<<`, `2>`), or the `<<-` heredoc operator. The
# scanner emits the operator without its target, which is the next token.
readonly REDIRECTION_OPERATOR_RE='^[0-9]*([<>]+|<<-)$'
# The operators an `&` or a `|` can extend (`>&`, `<&`, `>|`): a single `<` or
# `>` with an optional file descriptor.
readonly REDIRECTION_GLUE_RE='^[0-9]*[<>]$'

# @description Advance redirection tracking by one token and report whether that token is part of
#              a redirection -- an operator, the `&` or `|` that extends it, or its target -- and so
#              neither the command word nor an operand. bash allows a redirection anywhere in a
#              simple command, the front included, so a walk that hunts for the command word
#              (`2> /dev/null pkill`) skips what this reports and leaves its command position alone.
#
#              The `&` of `>&` and the `|` of `>|` are tokens of their own (`2>&1` is `2>`, `&`,
#              `1`); this reads one that follows a single `<` or `>` as that operator's tail, even
#              with space between, because `> &` and `> |` are syntax errors anyway. A token that
#              follows an operator but is itself an operator is no target: `<(` and `>(` open a
#              process substitution, so it is reported as not a redirection and the state resets.
# @arg $1 token the raw token
# @arg $2 state name of the caller's variable holding the tracking state: empty outside a
#         redirection, `glue` after a single `<` or `>`, `target` when the target is next. Never
#         pass a variable called token or redir_state_ref.
# @exitcode 0 the token belongs to a redirection and is to be skipped
# @exitcode 1 it does not
function tokens::redirection_step() {
  local -r token="$1"
  local -n redir_state_ref="$2"
  if [[ -n "${redir_state_ref}" ]]; then
    if [[ "${redir_state_ref}" == 'glue' && ("${token}" == '&' || "${token}" == '|') ]]; then
      redir_state_ref='target'
      return 0
    fi
    redir_state_ref=''
    tokens::is_operator "${token}" && return 1
    return 0
  fi
  if [[ "${token}" =~ ${REDIRECTION_OPERATOR_RE} ]]; then
    if [[ "${token}" =~ ${REDIRECTION_GLUE_RE} ]]; then
      redir_state_ref='glue'
    else
      redir_state_ref='target'
    fi
    return 0
  fi
  return 1
}

# @description The backward counterpart of tokens::redirection_step, for a walk that reads the
#              tokens before a command word: how many tokens at the end of the stream up to an index
#              make up one redirection. The token at the index must be a target (not an operator),
#              preceded by an operator, or by an `&` or `|` that extends a single `<` or `>`.
# @arg $1 tokens_var name of the caller's token array
# @arg $2 index index of the last token of the candidate redirection
# @arg $3 span name of the caller's variable that receives the token count: 3 for an operator,
#         its `&` or `|` and a target, 2 for an operator and a target, 0 when the token is no
#         redirection's target. Never pass a variable called toks or span_ref.
function tokens::redirection_span_back() {
  local -n toks="$1"
  local -r index="$2"
  local -n span_ref="$3"
  span_ref=0
  ((index >= 1)) || return 0
  tokens::is_operator "${toks[index]}" && return 0
  # shellcheck disable=SC2034 # the caller reads span_ref through its own variable, which shellcheck cannot follow
  if ((index >= 2)) && [[ "${toks[index - 1]}" == '&' || "${toks[index - 1]}" == '|' ]] \
    && [[ "${toks[index - 2]}" =~ ${REDIRECTION_GLUE_RE} ]]; then
    span_ref=3
  elif [[ "${toks[index - 1]}" =~ ${REDIRECTION_OPERATOR_RE} ]]; then
    span_ref=2
  fi
}

# @description True when the region opened at an index is the value of an assignment word, read
#              from the token array: `FOO=$(true)`, ``FOO=`true` ``, and a chain of regions and
#              words touching it (`FOO=$(true)$(true)`, ``FOO=a`true` ``). The array carries no
#              offsets, so a region or word directly before the opener is taken to touch it.
# @arg $1 tokens_var name of the caller's token array
# @arg $2 openers_var name of the caller's array mapping the index of each token that closes a
#         region to the index of the token that opened it
# @arg $3 opener index of the token that opened the region
# @exitcode 0 an assignment word holds the region
# @exitcode 1 none does
function tokens::region_holds_assignment() {
  local -n toks="$1"
  local -n openers="$2"
  local opener="$3" prev
  while ((opener > 0)); do
    prev="$((opener - 1))"
    case "${toks[opener]}" in
      '(') [[ "${toks[prev]}" == *'$' ]] || return 1 ;;
      '`') ;;
      *) return 1 ;;
    esac
    tokens::is_assignment_word "${toks[prev]}" && return 0
    if [[ -n "${openers[prev]:-}" ]]; then
      opener="${openers[prev]}"
    elif ((prev > 0)) && [[ -n "${openers[prev - 1]:-}" ]]; then
      opener="${openers[prev - 1]}"
    else
      return 1
    fi
  done
  return 1
}

# @description True when the token at an index closes a `$(...)`, `$((...))`, backtick or
#              process-substitution region that ends a word of its simple command, so the word after
#              it is an argument. For a walker over the token array, which has no region state of its
#              own: the closer's entry in the openers array names the token that began the region.
#              A region held by an assignment word (`FOO=$(true)`, ``FOO=`true` ``) is the exception:
#              the assignment leaves command position where it was, so the closer is not one.
# @arg $1 tokens_var name of the caller's token array
# @arg $2 openers_var name of the caller's array mapping the index of each token that closes a
#         region to the index of the token that opened it
# @arg $3 index index of the token to test
# @exitcode 0 the token closes a region that ends a word
# @exitcode 1 it closes none, or the region's word is an assignment
function tokens::is_word_region_close() {
  local -r tokens_var="$1" openers_var="$2" index="$3"
  local -n openers="${openers_var}"
  [[ -n "${openers[index]:-}" ]] || return 1
  tokens::region_holds_assignment "${tokens_var}" "${openers_var}" "${openers[index]}" && return 1
  return 0
}

# @description True when the region opener just stepped by tokens::region_step belongs to an
#              assignment word in front of it: `FOO=$(`, `FOO=$((` or a backtick touching an
#              assignment word (``FOO=` ``, ``FOO=a` ``). The walkers that have no saved command
#              position read it at the opener, to know at the close whether the word leaves
#              command position where it was.
# @arg $1 state name of the caller's associative array passed to tokens::region_step
# @arg $2 kind the opener's kind from tokens::region_step (`P`, `A`, `B` or `S`)
# @arg $3 offset the opener token's byte offset
# @exitcode 0 the word holding the region is an assignment
# @exitcode 1 it is not, or the region is a process substitution
function tokens::region_opens_assignment_value() {
  local -n state_ref="$1"
  local -r kind="$2" offset="$3"
  local -r before="${state_ref[prev_token]:-}"
  case "${kind}" in
    'P' | 'A') [[ "${before}" == *'$' ]] && tokens::is_assignment_word "${before}" ;;
    'B')
      ((${state_ref[prev_end]:--1} == offset)) && tokens::is_assignment_word "${before}"
      ;;
    *) return 1 ;;
  esac
}

# @description Advance region tracking by one token and report whether that token opens or closes
#              a `$(...)`, `$((...))`, backtick or process-substitution region. This is the scanner's
#              own rule, so a reader that works from the token stream sees the regions the scanner
#              saw: a `(` glued to a `$` opens one, and the first `)` closes it, except that inside an
#              arithmetic region (`$((`) a `(` nests, and so does a `(` directly followed by another
#              `(`; a backtick closes a backtick region and opens one anywhere else. A `(` glued to a
#              bare `<` or `>` token opens a process substitution (`<(...)`, `>(...)`), which is one
#              word of the enclosing simple command, and the first `)` closes it. A `(` that is
#              none of those, a subshell, opens no region, and the first `)` after it closes the
#              enclosing one, as the scanner reads it.
#
#              The state is an associative array the caller declares and passes by name, empty at the
#              start of a stream. `kinds` holds one letter per open region, innermost last (`P`
#              parenthesis, `A` arithmetic, `B` backtick, `S` process substitution), so
#              `${#state[kinds]}` is the depth. `closed` holds the letter of the region the token
#              just closed, empty for any other token, so a reader can tell the close of a
#              substitution (the end of a word) from a `)` that closes no region, as a
#              subshell's does (an operator). `end` and `token` describe the token just stepped,
#              and `prev_end` and `prev_token` the one before it.
#              Callers pass only non-empty tokens, as the `{ read offset token }` loops all skip
#              empty ones first.
# @arg $1 command the raw command string, for the byte after a `(`
# @arg $2 offset the token's byte offset in the command
# @arg $3 token the token
# @arg $4 state name of the caller's associative array holding the tracking state. Never pass a
#         variable called command, offset, token, kinds, depth, top, kind_ref or state_ref.
# @arg $5 kind name of the caller's variable that receives the result: empty when the token neither
#         opens nor closes a region, `close` when it closes the innermost one, otherwise the
#         letter of the region it opens (`P`, `A`, `B` or `S`)
# @set state updated as described above
# @set kind the result
# shellcheck disable=SC2034 # kind_ref is the caller's variable, written through the nameref
function tokens::region_step() {
  local -r command="$1" offset="$2" token="$3"
  local -n state_ref="$4"
  local -n kind_ref="$5"
  local -r kinds="${state_ref[kinds]:-}" before="${state_ref[token]:-}"
  local -r depth="${#kinds}"
  local -r glued="$((${state_ref[end]:--1} == offset))"
  local top=''
  if ((depth > 0)); then
    top="${kinds:depth-1:1}"
  fi
  kind_ref=''
  case "${token}" in
    '`')
      if [[ "${top}" == 'B' ]]; then
        kind_ref='close'
      else
        kind_ref='B'
      fi
      ;;
    '(')
      if [[ "${before}" == *'$' ]] && ((glued == 1)); then
        if [[ "${command:offset+1:1}" == '(' ]]; then
          kind_ref='A'
        else
          kind_ref='P'
        fi
      elif [[ "${before}" == '<' || "${before}" == '>' ]] && ((glued == 1)); then
        kind_ref='S'
      elif ((depth > 0)) && [[ "${top}" == 'A' || "${command:offset+1:1}" == '(' ]]; then
        kind_ref='A'
      fi
      ;;
    ')')
      if ((depth > 0)) && [[ "${top}" != 'B' ]]; then
        kind_ref='close'
      fi
      ;;
  esac
  state_ref['closed']=''
  case "${kind_ref}" in
    '') ;;
    'close')
      state_ref['closed']="${top}"
      state_ref[kinds]="${kinds:0:depth-1}"
      ;;
    *) state_ref[kinds]="${kinds}${kind_ref}" ;;
  esac
  state_ref['prev_end']="${state_ref[end]:--1}"
  state_ref['prev_token']="${state_ref[token]:-}"
  state_ref[end]="$((offset + ${#token}))"
  state_ref[token]="${token}"
}
