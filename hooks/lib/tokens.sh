# shellcheck shell=bash
#
# Command-position and prefix-command token helpers, sourced by
# hooks/pgrep-pkill-guard-body.sh once the entry script's prefilter has let a
# payload through. Never executed: no shebang, no exec bit, and it must not
# set `set -Eeuo pipefail`, `IFS`, or the ERR trap -- the entry script owns
# all three, and a sourced file that sets them reconfigures its caller. Never
# add `shopt -s inherit_errexit` (invariant 2). POSIX short flags, not GNU
# long options: this runs on BSD userland too (invariant 1).

# Keywords after which the next word is in command position.
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
#              command behind it (#188). The eleven `sudo` entries are its whole synopsis, checked
#              against the man page rather than recalled. That leak is the fail-open
#              direction, and it is the deliberate trade: an operand budget generous enough to
#              swallow an unknown option's value would read the `pkill` of `sudo deploy.sh pkill x`
#              as a command and deny one bash never runs.
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
#              scanner::find_invocations and shell_wrapper_payloads both need it and a second copy would
#              drift -- the bare-word version was already duplicated when it was wrong (#188).
#
#              An operator or keyword restores command position and clears the chain. A prefix word
#              opens one. Inside a chain, the prefix's own flags keep command position for what
#              follows, a flag's value is skipped without ever being in command position itself
#              (`env -u pkill cmd` unsets a variable, it does not run one), `--` ends the flags, and
#              the operands the prefix is entitled to are spent one per word. The first word that is
#              none of those IS the command, so the chain ends there. An option that makes the
#              prefix run nothing ends it too.
# @arg $1 token the raw token
# @arg $2 word the token reduced to its basename
# @arg $3 at_cmd 1 when this token is itself in command position
# @arg $4 chain name of the caller's variable holding the prefix in effect, empty when none
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
    # own still starts a command where the reserved word is legal.
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
    # second case work. A path spelling (`/usr/bin/time`) is never the reserved
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
    # runs `-k`, not a kill-after option. The chain stays open because the
    # operands the prefix is entitled to still come first: `timeout -- 5 cmd`
    # runs cmd. The sentinel matches no arm of either table.
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
    operands_ref=$((operands_ref - 1))
    return 0
  fi
  chain_ref=''
  return 1
}

# @description True when a token is a shell variable-assignment word (`FOO=bar`, `LC_ALL=C`, ...).
#              Tested against the raw token rather than its basename: unlike a prefix command, an
#              assignment's value routinely contains a `/` (`PATH=/usr/bin cmd`), and stripping to
#              the basename there would corrupt the match.
# @arg $1 token the token to test
# @exitcode 0 the token is a shell assignment word
# @exitcode 1 it is not
function tokens::is_assignment_word() {
  local -r token="$1"
  [[ "${token}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]
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
