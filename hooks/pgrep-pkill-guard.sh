#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# The scanner emits BYTE offsets, and this script slices the raw command back out
# with ${command:offset:length}. Bash string operations are locale-aware, so under
# a UTF-8 locale a single multibyte character earlier in the command shifts every
# later slice and silently voids the bracket mitigation. Force the C locale so the
# two index bases agree.
export LC_ALL=C

# Defined above the version guard below, which needs it: everything else in this
# script is set up after that guard has already run.
readonly HOOK_NAME='block-pgrep-self-match'

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
  # Loud, not silent. A bare `{}` here would leave a coworker on stock macOS
  # bash 3.2 with an installed plugin that quietly does nothing -- the exact
  # failure the jq/awk branches further down spend a systemMessage to prevent.
  printf '{"systemMessage":"%s"}\n' \
    "${HOOK_NAME}: bash 4.3+ required (found ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}); the pgrep/pkill guard is INACTIVE for this command. On macOS: brew install bash."
  exit 0
fi

# Any unexpected failure must still allow the command. A hook that dies non-zero
# surfaces an error on every Bash call; exit 2 would block the tool outright.
trap 'emit_allow; exit 0' ERR

# Resolve the scanner relative to this script rather than via CLAUDE_CONFIG_DIR,
# which is not guaranteed to be exported into the hook's environment.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
readonly SCANNER="${SCRIPT_DIR}/pgrep-scan.awk"

# Keywords after which the next word is in command position.
readonly -a COMMAND_POSITION_KEYWORDS=(
  'do' 'then' 'else' 'elif' 'while' 'until' 'if' 'for' 'select' '!' 'time'
)

# Words that run another command and so preserve command position for the word
# after them. `sudo pkill --full java` is the single most likely session-killing
# form, so the guard must see through the prefix -- and through the prefix's own
# options, which is what prefix_chain_step below is for. `timeout` belongs here
# for the same reason the others do: `timeout 5 pkill --full java` runs the kill.
readonly -a PREFIX_COMMANDS=('sudo' 'doas' 'env' 'nohup' 'command' 'time' 'timeout')

# @description True when a token is a command prefix that keeps the following word in command
#              position.
# @arg $1 token the token to test
# @exitcode 0 the token is a prefix command
# @exitcode 1 it is not
function is_prefix_command() {
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
function prefix_value_option() {
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
function prefix_operand_budget() {
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
#              allow, so completeness here buys much less than it does in prefix_value_option.
# @arg $1 prefix the prefix command
# @arg $2 word the option word to test
# @exitcode 0 the option ends the chain
# @exitcode 1 it does not
function prefix_breaks_chain() {
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
#              find_invocations and shell_wrapper_payloads both need it and a second copy would
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
function prefix_chain_step() {
  local -r token="$1" word="$2" at_cmd="$3"
  # Namerefs must not share a name with the caller's variable, or bash refuses
  # the assignment as a circular reference, so each carries a _ref suffix. The
  # positional locals are equally unsafe as caller names: never pass a variable
  # called token, word, or at_cmd to this function by name.
  local -n chain_ref="$4" skip_ref="$5" operands_ref="$6"
  if is_operator "${token}"; then
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
  if ((at_cmd == 1)) && is_prefix_command "${word}"; then
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
    operands_ref="$(prefix_operand_budget "${word}")"
    return 0
  fi
  if is_keyword "${token}"; then
    chain_ref=''
    skip_ref=0
    operands_ref=0
    return 0
  fi
  if ((at_cmd != 1)); then
    chain_ref=''
    return 1
  fi
  if is_assignment_word "${token}"; then
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
    if prefix_breaks_chain "${chain_ref}" "${word}"; then
      chain_ref=''
      return 1
    fi
    if [[ "${word}" == -* ]]; then
      # A flag's value is never itself in command position, but the word after
      # it is; a flag that takes no value keeps command position directly.
      if prefix_value_option "${chain_ref}" "${word}"; then
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
function is_assignment_word() {
  local -r token="$1"
  [[ "${token}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]
}

# @description True when a token is a shell keyword after which the next word is again in
#              command position.
# @arg $1 token the token to test
# @exitcode 0 the token is such a keyword
# @exitcode 1 it is not
function is_keyword() {
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
function is_operator() {
  case "$1" in
    ';' | '&' | '|' | '(' | ')' | '{' | '}' | '<NL>' | '`') return 0 ;;
    *) return 1 ;;
  esac
}

# @description Tokenize a command, masking quoted regions.
# @arg $1 command the command string
# @stdout offset and token pairs, separated by tab
function scan_command() {
  local -r command="$1"
  printf '%s' "${command}" | LC_ALL=C awk -f "${SCANNER}"
}

# @description Locate pgrep/pkill invocations that sit in command position. A quoted mention such as
#              `grep -r "until ! pgrep --full"` yields nothing, because the scanner masked it. A
#              leading run of prefix words (`sudo`, `command`, ...) keeps command position, and the
#              token is matched on its basename so `/usr/bin/pgrep` counts. A leading run of shell
#              assignment words (`FOO=bar pgrep ...`, `LC_ALL=C env FOO=bar pkill ...`) does too:
#              `NAME=value` in front of a command is ordinary shell, not an argument, and without
#              this the assignment hides the invocation from the whole scan -- not just from the
#              kill/loop tiers -- because `at_cmd` drops to 0 and the pgrep/pkill token itself is
#              never recorded.
# @arg $1 tokens newline-separated "<offset>\t<token>" records from scan_command
# @stdout lines of "<index>\t<offset>\t<basename>"
function find_invocations() {
  local at_cmd=1 idx=0 offset token word chain='' chain_skip=0 chain_operands=0
  local -r tokens="$1"
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    word="${token##*/}"
    if ((at_cmd == 1)) && [[ "${word}" == 'pgrep' || "${word}" == 'pkill' ]]; then
      printf '%s\t%s\t%s\n' "${idx}" "${offset}" "${word}"
    fi
    if prefix_chain_step "${token}" "${word}" "${at_cmd}" chain chain_skip chain_operands; then
      at_cmd=1
    else
      at_cmd=0
    fi
    idx=$((idx + 1))
  done <<< "${tokens}"
}

# @description Collect one invocation's argument tokens: everything after the command name, up to
#              the operator that ends the simple command.
# @arg $1 tokens the token stream from scan_command
# @arg $2 target index of the pgrep/pkill token itself
# @stdout lines of "<offset>\t<token>"
function invocation_args() {
  local -r tokens="$1"
  local -r target="$2"
  local idx=0 offset token
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    if ((idx > target)); then
      is_operator "${token}" && break
      printf '%s\t%s\n' "${offset}" "${token}"
    fi
    idx=$((idx + 1))
  done <<< "${tokens}"
}

# @description True when an invocation's arguments carry a flag, as either the long option or a
#              short cluster containing the letter. A bare -- ends option parsing.
# @arg $1 args newline-separated "<offset>\t<token>" lines
# @arg $2 long the long option, for example --full
# @arg $3 short the short cluster letter, for example f
# @exitcode 0 the flag is present
# @exitcode 1 it is absent
function has_flag() {
  local -r args="$1" long="$2" short="$3"
  local offset token
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    [[ "${token}" == '--' ]] && return 1
    [[ "${token}" == "${long}" ]] && return 0
    if [[ "${token}" == -[a-zA-Z]* && "${token}" != --* && "${token}" == *"${short}"* ]]; then return 0; fi
  done <<< "${args}"
  return 1
}

# Long options that take a separate value, so that value is not the operand.
readonly -a PGREP_VALUE_OPTIONS=(
  '--delimiter' '--parent' '--pgroup' '--session' '--terminal' '--uid' '--euid'
  '--group' '--ns' '--nslist' '--signal' '--older'
)

# @description Extract the search pattern: the last argument that is neither a flag, a flag's value,
#              nor a redirection. Once a bare -- end-of-options terminator is seen, every later token
#              is a pattern candidate regardless of a leading dash -- only an exact redirection
#              operator is still excluded. Sliced out of the raw command by offset so the original
#              quoting survives, then one surrounding quote pair is stripped.
# @arg $1 command the raw command string
# @arg $2 args newline-separated "<offset>\t<token>" lines
# @stdout the operand with surrounding quotes removed, or empty
function pattern_operand() {
  local -r command="$1" args="$2"
  local operand_offset='' operand_length=0 skip=0 past_terminator=0 offset token value_option
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    if ((skip == 1)); then
      skip=0
      continue
    fi
    if ((past_terminator == 1)); then
      if [[ "${token}" == '>' || "${token}" == '<' || "${token}" == '>>' ]]; then
        skip=1
      else
        operand_offset="${offset}"
        operand_length="${#token}"
      fi
      continue
    fi
    if [[ "${token}" == '--' ]]; then
      past_terminator=1
      continue
    fi
    case "${token}" in
      --*)
        for value_option in "${PGREP_VALUE_OPTIONS[@]}"; do
          [[ "${token}" == "${value_option}" ]] && skip=1 && break
        done
        ;;
      -*) : ;;
      *[\<\>]*)
        [[ "${token}" == '>' || "${token}" == '<' || "${token}" == '>>' ]] && skip=1
        ;;
      *)
        operand_offset="${offset}"
        operand_length="${#token}"
        ;;
    esac
  done <<< "${args}"
  [[ -z "${operand_offset}" ]] && return 0
  local raw="${command:operand_offset:operand_length}"
  if [[ "${raw}" == \"*\" || "${raw}" == \'*\' ]]; then raw="${raw:1:${#raw}-2}"; fi
  printf '%s' "${raw}"
}

# @description Decide whether a bracket-class pattern actually defeats self-match. It does only when
#              the de-bracketed literal appears nowhere else in the command line: a single-character
#              class hides the needle from its own regex, but an unbracketed copy elsewhere in the
#              same `bash -c` argument puts it straight back.
# @arg $1 command the raw command string
# @arg $2 operand the pattern operand, quotes already stripped
# @exitcode 0 the mitigation holds
# @exitcode 1 no bracket class, or the bare literal occurs elsewhere
function bracket_mitigation_holds() {
  local -r command="$1" operand="$2"
  [[ -z "${operand}" ]] && return 1
  [[ "${operand}" != *\[?\]* ]] && return 1
  local bare="${operand}"
  local prefix rest
  while [[ "${bare}" == *\[?\]* ]]; do
    prefix="${bare%%\[?\]*}"
    rest="${bare#"${prefix}"}"
    bare="${prefix}${rest:1:1}${rest:3}"
  done
  # A surviving `[` means an unresolved class opener whose literal text cannot be
  # reconstructed. A surviving `]` is just a literal character and is fine.
  [[ "${bare}" == *\[* ]] && return 1
  [[ -z "${bare}" ]] && return 1
  [[ "${command}" == *"${bare}"* ]] && return 1
  return 0
}

# @description Determine whether a token index sits inside a while/until condition, inside any loop
#              body, or outside every loop. A for/select head reports "none": it is evaluated once,
#              so a self-matching pgrep there pins no termination test. `$(`, a backtick, and a plain
#              `(` each push a scope-barrier marker so that a loop entirely inside one cannot pop, or
#              be popped by, a loop spanning the enclosing command: a stray `do`/`done` inside a
#              substitution (whether from a real nested loop or just literal text, such as an echoed
#              "done") is bounded by its own barrier and can never reach past it. The marker is
#              transparent when reading the context AT the target index, though: an invocation that is
#              simply inside a substitution with no loop of its own still belongs to whatever cond/body
#              span encloses that substitution, which is why `until [ -z "$(pgrep --full x)" ]; do ...`
#              still reports `cond` -- the lookup skips barrier markers to find the nearest real span.
# @arg $1 tokens the token stream from scan_command
# @arg $2 target index of the invocation token
# @stdout none, cond, or body
function loop_context() {
  local -r tokens="$1" target="$2"
  local -a stack=()
  local idx=0 at_cmd=1 dollar=0 offset token
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    if ((idx == target)); then
      local i="$((${#stack[@]} - 1))" found='none'
      while ((i >= 0)); do
        case "${stack[i]}" in
          cond)
            found='cond'
            break
            ;;
          body)
            found='body'
            break
            ;;
          head)
            found='none'
            break
            ;;
          *) i=$((i - 1)) ;;
        esac
      done
      printf '%s\n' "${found}"
      return 0
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
        if ((dollar == 1)); then stack+=('capture'); else stack+=('subshell'); fi
        ;;
      ')')
        # Only a `)` that actually closes something pops. A case-pattern `)`
        # terminates a pattern list and has no opener, so popping on it would
        # discard whatever span encloses the `case` -- the loop body itself,
        # for a `case` written inside one (#155 entry 2). Requiring a paren
        # marker on top makes the distinction without parsing `case`/`esac`:
        # a pattern's `)` finds a body/cond/head marker there, or nothing.
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
    if [[ "${token}" == *'$' ]]; then dollar=1; else dollar=0; fi
    if is_operator "${token}" || is_keyword "${token}"; then at_cmd=1; else at_cmd=0; fi
    idx=$((idx + 1))
  done <<< "${tokens}"
  printf 'none\n'
}

# @description True when the loop body enclosing an invocation contains a break, exit or return in
#              command position, which makes a body-position pgrep the effective termination test.
# @arg $1 tokens the token stream from scan_command
# @arg $2 target index of the invocation token
# @exitcode 0 a terminator is present in the enclosing body
# @exitcode 1 no terminator
function body_has_terminator() {
  local -r tokens="$1" target="$2"
  local depth=0 seen=0 at_cmd=1 idx=0 offset token
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    ((idx == target)) && seen=1
    if ((at_cmd == 1)); then
      case "${token}" in
        'do') depth=$((depth + 1)) ;;
        'done')
          ((seen == 1 && depth > 0)) && return 1
          ((depth > 0)) && depth=$((depth - 1))
          ;;
        'break' | 'exit' | 'return') ((depth > 0)) && return 0 ;;
      esac
    fi
    if is_operator "${token}" || is_keyword "${token}"; then at_cmd=1; else at_cmd=0; fi
    idx=$((idx + 1))
  done <<< "${tokens}"
  return 1
}

# @description Emit an allow decision.
# @noargs
function emit_allow() {
  printf '{}\n'
}

# @description Allow the command but attach model-visible context.
#              additionalContext is the only PreToolUse field verified to reach
#              the model on an allowed call; systemMessage renders to the user
#              only, and permissionDecisionReason is fed back under deny alone.
# @arg $1 text the message the model should read
function emit_warn() {
  local -r text="$1"
  jq --null-input --arg msg "${text}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      additionalContext: $msg
    }
  }'
}

# @description Emit a deny decision.
# @arg $1 text the reason shown to the model
function emit_deny() {
  local -r text="$1"
  jq --null-input --arg msg "${text}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $msg
    }
  }'
}

# @description True when the do/done body belonging to the `for`/`select`/`while`/`until` head at
#              head_idx contains `kill` in command position. Covers two idioms where `kill` is not
#              adjacent to the invocation in the token stream at all, so the rest of this guard's
#              kill detection (which looks for `kill` next to or piped from the invocation) cannot
#              see it: `for pid in $(pgrep -f java); do kill "$pid"; done` (head_idx is the `in`
#              token, invoked from the backward scan) and `pgrep -f java | while read -r p; do kill
#              "$p"; done` (head_idx is the `while` token itself, invoked from the forward pipeline
#              scan). Either way this walks forward past the head's condition/iterable list to find
#              the matching `do`, then scans that body (respecting nested do/done depth, the way
#              body_has_terminator does) for a command-position `kill`. A loop whose body never
#              kills (`for f in $(pgrep -f java); do echo "$f"; done`) must return 1 so the caller
#              falls through to the ordinary warn path.
# @arg $1 tokens_var name of the caller's token array
# @arg $2 head_idx index of the `in`/`while`/`until` token whose body's `do` follows
# @exitcode 0 the loop body kills
# @exitcode 1 it does not, or no body was found
function loop_body_has_kill() {
  local -n toks="$1"
  local -r head_idx="$2"
  local idx=$((head_idx + 1)) token found_do=0 body_depth=1 at_cmd=1
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
      idx=$((idx + 1))
      break
    fi
    idx=$((idx + 1))
  done
  ((found_do == 1)) || return 1

  while ((idx < ${#toks[@]})); do
    token="${toks[idx]}"
    if ((at_cmd == 1)); then
      case "${token}" in
        'do') body_depth=$((body_depth + 1)) ;;
        'done')
          body_depth=$((body_depth - 1))
          ((body_depth == 0)) && return 1
          ;;
        'kill') return 0 ;;
      esac
    fi
    if is_operator "${token}" || is_keyword "${token}"; then at_cmd=1; else at_cmd=0; fi
    idx=$((idx + 1))
  done
  return 1
}

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
function is_xargs_value_option() {
  local -r token="$1"
  local option
  for option in "${XARGS_VALUE_OPTIONS[@]}"; do
    [[ "${token}" == "${option}" ]] && return 0
  done
  return 1
}

# @description True when an invocation's output is piped into a kill, or when the invocation is
#              itself substituted into a kill's argument list (`kill $(pgrep ...)` and the backtick
#              equivalent). The forward pipeline scan requires `kill` to head a pipeline segment, or
#              to follow an `xargs` that heads one, with flags and prefix words allowed in between:
#              `pgrep --full x | grep -i kill` merely searches for the word and kills nothing. A
#              pipeline segment headed by `while`/`until` (`pgrep -f java | while read -r p; do kill
#              "$p"; done`) defers to loop_body_has_kill rather than being written off as `other`. The
#              backward scan's `(` check also excludes an array literal (`arr=(kill $(...))`): the
#              `(` there opens a list of words rather than a subshell, so `kill` inside it is never
#              invoked. Its `in` case defers to loop_body_has_kill the same way, for `for pid in
#              $(pgrep -f java); do kill "$pid"; done` -- but only once it confirms the `in` actually
#              heads a for/select construct, so an unrelated argument word `in` (`echo in $(...)`)
#              cannot be mistaken for one and misattribute a later, unrelated loop's kill.
# @arg $1 tokens_var name of the caller's token array (built once by classify_command; every
#              invocation in the same command reuses it rather than re-parsing the token stream)
# @arg $2 target index of the invocation token
# @exitcode 0 output feeds a kill
# @exitcode 1 it does not
function feeds_a_kill() {
  local -n toks="$1"
  local -r target="$2"
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
            if [[ "${word}" == 'kill' ]]; then
              return 0
            elif [[ "${word}" == 'xargs' ]]; then
              segment='xargs'
              xargs_skip=0
            elif [[ "${word}" == 'while' || "${word}" == 'until' ]]; then
              loop_body_has_kill "$1" "${idx}" && return 0
              segment='other'
            elif ! is_prefix_command "${word}"; then
              segment='other'
            fi
            ;;
          xargs)
            if ((xargs_skip == 1)); then
              # Value word belonging to the option before it, not a command.
              xargs_skip=0
            elif [[ "${word}" == 'kill' ]]; then
              return 0
            elif [[ "${word}" == '{' || "${word}" == '}' ]]; then
              : # `-I{}` placeholder braces, not a new command word
            elif is_xargs_value_option "${word}"; then
              xargs_skip=1
            elif [[ "${word}" != -* ]] && ! is_prefix_command "${word}"; then
              segment='other'
            fi
            ;;
        esac
        ;;
    esac
  done

  # Backward form: `kill $(pgrep ...)`, `kill -9 $(pgrep ...)`, and the backtick
  # equivalent. Here `kill` precedes the invocation, so the forward scan cannot
  # see it. Skip the substitution punctuation and any flags on the way back, then
  # require the `kill` to be in command position -- otherwise `echo kill $(...)`,
  # where `kill` is merely an argument word, would be denied. A value word that
  # belongs to a preceding `-s`/`--signal` (`kill -s TERM $(pgrep ...)`) is also
  # skipped rather than treated as an unrecognized stop word: it is recognized by
  # peeking at the token immediately before it, since scanning backward means the
  # value is reached before its flag. Walking further back past `kill` to confirm
  # command position also accepts a shell assignment word (`FOO=bar kill $(...)`),
  # matching find_invocations's forward treatment of the same prefix.
  local k=$((target - 1)) m
  while ((k >= 0)); do
    word="${toks[k]##*/}"
    case "${word}" in
      '$' | '(' | '`') ;;
      -*) ;;
      'kill')
        m=$((k - 1))
        while ((m >= 0)); do
          if is_prefix_command "${toks[m]##*/}" || is_assignment_word "${toks[m]}"; then
            m=$((m - 1))
            continue
          fi
          # `(` restores command position for a real subshell or grouping
          # construct, but `name=(...)` is an array literal: the `(` merely
          # opens a list of words, and a `kill` immediately inside it is
          # never invoked. The token right before the `(` ending in `=` is
          # what tells the two apart.
          if [[ "${toks[m]}" == '(' ]] && ((m > 0)) && [[ "${toks[m - 1]}" == *= ]]; then
            return 1
          fi
          if is_operator "${toks[m]}" || is_keyword "${toks[m]}"; then return 0; fi
          return 1
        done
        return 0
        ;;
      'in')
        # A bare `in` is only a for/select head -- and thus worth deferring to
        # loop_body_has_kill -- when the token two back (past the loop
        # variable) is actually `for`/`select`. Otherwise `in` is just an
        # ordinary argument word (`echo in $(...)`), and the forward walk to
        # a `do` in loop_body_has_kill could cross into an unrelated later
        # loop's body and misattribute its kill to this invocation.
        if ((k >= 2)) && { [[ "${toks[k - 2]}" == 'for' ]] || [[ "${toks[k - 2]}" == 'select' ]]; }; then
          loop_body_has_kill "$1" "${k}" && return 0
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

# @description True when an invocation sits inside a command substitution, so its output is captured
#              rather than printed. Counted as a depth over the token stream: a substring test on the
#              raw command prefix cannot tell an enclosing `$(` from an unrelated one that has
#              already closed, which made `for i in $(seq 1 5); do pgrep -af java; ...; done` read as
#              a capture. `$` is not an operator token, so the opener is recognised as any token
#              ending in `$` immediately followed by `(`, which also covers `p=$(...)`.
# @arg $1 tokens_var name of the caller's token array, built once by classify_command
# @arg $2 target index of the invocation token
# @exitcode 0 the invocation is inside a command substitution
# @exitcode 1 it is not
function invocation_is_captured() {
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
        if ((dollar == 1)); then stack+=('capture'); else stack+=('subshell'); fi
        ;;
      ')')
        if ((${#stack[@]} > 0)); then unset 'stack[${#stack[@]}-1]'; fi
        ;;
      '`')
        if ((${#stack[@]} > 0)) && [[ "${stack[${#stack[@]} - 1]}" == 'backtick' ]]; then
          unset 'stack[${#stack[@]}-1]'
        else
          stack+=('backtick')
        fi
        ;;
    esac
    if [[ "${token}" == *'$' ]]; then dollar=1; else dollar=0; fi
  done
  return 1
}

# @description True when the command immediately after an invocation, in the same list, reads `$?`.
#              That is a consumption of the exit status exactly like `&&` or an enclosing `if`, and
#              the forward scan in result_is_consumed cannot see it because it stops at the `;` or
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
# @arg $2 tokens the token stream from scan_command
# @arg $3 target index of the invocation token
# @exitcode 0 the following command reads the exit status
# @exitcode 1 it does not
function next_command_reads_status() {
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
#              command in the list reading `$?`, which next_command_reads_status handles. A
#              redirection target is not consumption: `2>&1` tokenizes as `2>`, `&`, `1`, and a lone
#              trailing `&` is backgrounding rather than a boolean operator.
# @arg $1 tokens_var name of the caller's token array, built once by classify_command
# @arg $2 target index of the invocation token
# @arg $3 args the invocation's argument lines
# @arg $4 command the raw command string, for the `$?` check
# @arg $5 tokens the token stream from scan_command, for the `$?` check
# @exitcode 0 the result is consumed
# @exitcode 1 the result is only displayed
function result_is_consumed() {
  local -n toks="$1"
  local -r target="$2" args="$3" command="$4" tokens="$5"
  local offset token
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    [[ "${token}" == '--count' ]] && return 0
    if [[ "${token}" == -[a-zA-Z]* && "${token}" != --* && "${token}" == *c* ]]; then return 0; fi
  done <<< "${args}"

  # An enclosing `if` / `elif`, or a negation, reads the exit status as a boolean.
  # Walk back over prefix words so `if sudo pgrep --full x` still counts.
  local k=$((target - 1)) word
  while ((k >= 0)); do
    word="${toks[k]##*/}"
    case "${word}" in
      'if' | 'elif' | '!') return 0 ;;
      *) is_prefix_command "${word}" || break ;;
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
      # As in feeds_a_kill: a newline right after a trailing `|` continues the
      # pipeline, so `| wc -l` on the next line is still consumption.
      '<NL>') [[ "${prev}" == '|' ]] || break ;;
      *) amp=0 ;;
    esac
    prev="${token}"
  done

  # `p=$(pgrep ...)`: the output is captured rather than printed.
  invocation_is_captured "$1" "${target}" && return 0

  # `pgrep --full x; rc=$?`: the status is read by the next command in the list.
  next_command_reads_status "${command}" "${tokens}" "${target}" && return 0
  return 1
}

# shellcheck disable=SC2016
readonly WARN_MESSAGE='Note: this `pgrep --full` also matches the process running this very command.
The Bash tool executes commands as `bash -c ...`, so the search pattern appears in an ancestor
process command line and is always found. The result is therefore inflated by one, and an exit status
of 0 does not mean the target process is running. Add `--ignore-ancestors` if the count or the exit
status is being used for anything.'

# Every deny leads with the escape hatch for the one legitimate reason to put a
# denied shape in a Bash command: writing prose that quotes it. It used to
# trail the fixes, where it was read last or not at all.
# shellcheck disable=SC2016
readonly WRITE_TOOL_LEAD='If this command WRITES text that contains such an example (a heredoc, `echo`, or `printf` into
a file) rather than running one, use the Write tool instead; this guard only inspects Bash commands.'

# @description Build the deny reason for a deny kind.
# @arg $1 kind loop, kill, or task-poll
# @arg $2 detail the tool for kill (pgrep or pkill; defaults to pgrep), or the polled path for
#         task-poll
# @stdout the reason text: the Write-tool lead, a preamble, and a fixes list
function deny_message() {
  local -r kind="$1"
  local -r detail="${2:-pgrep}"
  local preamble fixes

  case "${kind}" in
    loop)
      # shellcheck disable=SC2016
      preamble='This loop can never exit. The Bash tool runs commands as `bash -c ...`, so the search
pattern is by construction part of an ancestor process command line. `pgrep --full` matches that
ancestor, the loop always sees a live process, and it spins until something kills it.

`--ignore-ancestors` does not rescue a loop. It excludes ANCESTORS only: a second waiter for the
same event -- a sibling background shell whose command line carries the same literal -- is matched
by the first, and the first by the second, and both spin until killed. Never write two waiters for
one event.'
      # shellcheck disable=SC2016
      fixes='Two fixes, in order of preference:

1. Do not poll. A background task re-invokes you with a task notification when it finishes: stop
   here and Read the output path it names. If the result is needed before you can reply, call
   `TaskOutput` with `block: true` on the task id -- one call returns the output and the exit
   code. Polling is the root cause; this loop is a symptom.
2. Poll a PID, not a pattern: `while kill -0 "$pid" 2>/dev/null; do sleep 5; done`, with `$pid`
   recorded when the process was started (`$!`, a PID file). A PID cannot match a sibling.'
      ;;
    kill)
      # shellcheck disable=SC2016
      preamble='This matches the invoking shell itself. The Bash tool runs commands as `bash -c ...`,
so the search pattern is part of an ancestor process command line, and killing that match terminates
the session shell.'
      # Kill denials get targeting advice, not anti-polling advice, and the
      # examples name the tool that was actually invoked (#152).
      # shellcheck disable=SC2016
      fixes='Three fixes, in order of preference:

1. Kill by PID, not by pattern. Use a PID recorded when the process was started (`kill "$pid"`, a
   PID file), or probe liveness first with `kill -0 "$pid"`. Pattern-matching kills are the root
   cause; the self-match is a symptom.
2. `__TOOL__ --ignore-ancestors --full <pattern>` excludes the `bash -c` ancestor.
3. `__TOOL__ --full "[p]attern"` hides the needle from its own regex, but only when the bare literal
   appears NOWHERE ELSE in the same command. A second copy in the same call silently defeats it.'
      fixes="${fixes//__TOOL__/${detail}}"
      ;;
    task-poll)
      # The path is interpolated by concatenation so the backticks stay literal.
      # shellcheck disable=SC2016
      preamble='This loop polls a harness task-output file (`'"${detail}"'`). Background tasks are
tracked by the harness itself: when one finishes you are re-invoked with a task notification naming
that path, so polling it from a shell only wastes the wait -- and if the task is killed the file may
never change, so the loop never exits.'
      # shellcheck disable=SC2016
      fixes='Two fixes, in order of preference:

1. Stop here. Read the file when the task notification arrives; nothing you run before then can
   make it arrive sooner.
2. If the result is needed before you can reply, call `TaskOutput` with `block: true` on the task
   id -- one call returns the output and the exit code.

A single `cat`, `grep`, or `test` of the file is fine; a loop on it is not.'
      ;;
    *)
      # Unreachable stub: every kind classify_command can emit (loop, kill,
      # task-poll, repeat) has its own arm above, and tests/deny-sweep.bats
      # fails the build on an unknown kind. Kept so an unmatched kind still
      # produces a message instead of an unbound `case` fallthrough, and
      # `fixes` is non-empty so the output never has a trailing empty block.
      preamble='This pgrep matches its own ancestor process.'
      fixes='(no fixes: unknown deny kind)'
      ;;
  esac

  printf '%s\n\n%s\n\n%s\n' "${WRITE_TOOL_LEAD}" "${preamble}" "${fixes}"
}

# Wrappers that run their `-c` payload as code ON THIS MACHINE, in this process
# tree, so the payload's `bash -c ...` ancestor is the same one a pgrep inside it
# would match. `ssh`, `docker exec`, `kubectl exec`, `watch` and friends are
# deliberately absent: their payload runs somewhere else (or under a different
# ancestor), and the scanner's masking of it is correct rather than a gap. That
# distinction -- who runs the payload -- is the whole content of this feature;
# "is it quoted" is not the question (#155 entry 4).
readonly -a LOCAL_SHELL_WRAPPERS=('bash' 'sh' 'zsh' 'dash' 'ksh')

# The same, for the user-switching wrappers. `su -c` and `runuser -c` hand the
# payload to a shell here, under this process tree, so a pgrep inside one matches
# the same ancestor. They are listed apart from the shells only because of the
# operand budget below.
readonly -a LOCAL_USER_SWITCH_WRAPPERS=('su' 'runuser')

# How many wrapper payloads deep to follow. `bash -c 'bash -c "..."'` resolves at
# 2; the limit is a runaway backstop, not a judgement about nesting.
readonly MAX_PAYLOAD_DEPTH=4

# @description How many non-flag operands may precede a wrapper's `-c` before the wrapper stops
#              owning the option. This is the whole difference between the two wrapper families.
#
#              A shell's own options end at its first operand: past that word it is running a
#              SCRIPT, and a `-c` among the words after it is an argument being handed to that
#              script. `bash deploy.sh -c '...'` runs deploy.sh; nothing executes the string, so
#              reading it as a payload is a false deny. Budget 0.
#
#              `su`/`runuser` take the user name as an operand and still parse a `-c` after it --
#              `su - user -c '...'` is the ordinary spelling and does run the payload. Exactly one,
#              though: past the user name the words are arguments to the login shell, so a `-c`
#              among them is not su's either. Budget 1. A bare `-` needs no budget, being already
#              spelled like a flag.
# @arg $1 token the token to test, already reduced to its basename
# @stdout the operand budget, when the token names a local wrapper
# @exitcode 0 the token is a local wrapper
# @exitcode 1 it is not
function wrapper_operand_budget() {
  local -r token="$1"
  local wrapper
  for wrapper in "${LOCAL_SHELL_WRAPPERS[@]}"; do
    if [[ "${token}" == "${wrapper}" ]]; then
      printf '0'
      return 0
    fi
  done
  for wrapper in "${LOCAL_USER_SWITCH_WRAPPERS[@]}"; do
    if [[ "${token}" == "${wrapper}" ]]; then
      printf '1'
      return 0
    fi
  done
  return 1
}

# @description The text a pass-through producer on the left of a pipe hands to the wrapper on the
#              right, for the producers whose output is knowable from the command line alone.
#              `cat` is not one of them here -- what it passes through is a heredoc body, which
#              the caller resolves through the scanner's `<HD:len>` marker instead.
#
#              `echo` prints its operands, so a single literal operand IS the script. `-n`, `-e`
#              and `-E` are the only flags it has and are skipped; any other dash word is printed
#              literally, and counting it as a flag would hand the recursion a script the shell
#              never sees. More than one operand is skipped rather than reconstructed: the
#              separator is a space only because IFS says so, and a wrong reconstruction is a
#              false deny.
#
#              `printf` takes its format first, so one operand means the format itself is the
#              script (`printf 'cmd\n' | bash`) and two mean the format is a pass-through and the
#              second operand is (`printf '%s\n' 'cmd' | bash`). Three or more is a format applied
#              repeatedly, which cannot be reconstructed here either.
# @arg $1 name the producer's basename
# @arg $@ words its operand words, already unquoted
# @stdout the payload text, when there is one
# @exitcode 0 a payload was printed
# @exitcode 1 this producer hands the wrapper nothing knowable
function pipe_producer_payload() {
  local -r name="$1"
  shift
  local -a literals=()
  local word
  case "${name}" in
    echo)
      for word in "$@"; do
        [[ "${word}" =~ ^-[neE]+$ ]] && continue
        literals+=("${word}")
      done
      ((${#literals[@]} == 1)) || return 1
      printf '%s' "${literals[0]}"
      ;;
    printf)
      for word in "$@"; do
        [[ "${word}" == '--' ]] && continue
        literals+=("${word}")
      done
      case "${#literals[@]}" in
        1) printf '%s' "${literals[0]}" ;;
        2) printf '%s' "${literals[1]}" ;;
        *) return 1 ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# @description Find the payloads of local shell wrappers and print each one's raw text,
#              NUL-terminated, with any surrounding quotes stripped.
#
#              A `-c` payload counts only when all three hold: the wrapper is in command position
#              (so `ssh host bash -c ...` and a bare `echo bash -c ...` are both skipped, since
#              neither runs the payload here); a `-c` precedes it, in the same simple command,
#              within the wrapper's operand budget (see wrapper_operand_budget -- this is what
#              keeps `bash deploy.sh -c '...'`, where the `-c` belongs to the script, from being
#              read as a payload); and the raw slice is a single fully quoted word. That last
#              condition is what keeps the recursion honest -- a double-quoted payload containing
#              a command substitution is NOT one opaque token, because the scanner deliberately
#              re-enters code context inside `$(...)`, and the outer scan can already see the
#              substitution for itself. Slicing a fragment of such a payload and recursing on it
#              would classify text that is not a command.
#
#              A heredoc feeding the wrapper's stdin (`bash <<'EOF'`, `sudo sh <<EOF`, `0<<EOF
#              bash`) is a payload too: the body is the script the wrapper runs, here (#184). A
#              heredoc operator may carry an explicit fd like any other redirection (`0<<EOF`,
#              `3<<-EOF`); only fd 0 -- explicit or, far more commonly, the implicit default --
#              feeds the wrapper's stdin, so `bash 3<<EOF` is skipped: it redirects a different fd,
#              not the one the wrapper reads its script from. A heredoc counts when its operator is
#              seen in the wrapper's simple command with no `-c` before it and the simple command
#              then ends without an operand spending the budget -- an operand makes the body that
#              script's stdin instead, unless a `-s` in a short flag cluster already said stdin IS
#              the script, in which case the operands are its positional parameters and the body
#              still runs here -- and, once `-s` has taken an operand, so is a later `-c`, which is
#              then just another positional word and starts no payload.
#
#              Any other redirection in the same simple command (`bash <<EOF >
#              /tmp/log`, `bash <<EOF 2>&1`) is neither an operand nor a flag: it leaves both the
#              budget and the pending heredoc alone.
#
#              A redirection may precede the command word it attaches to
#              (`<<EOF bash`, `sudo <<EOF bash`), so a stdin heredoc seen while still hunting for
#              the command word is remembered and, once that word turns out to be a wrapper,
#              counted as its payload exactly as one written after the word would be. Both
#              delimiter forms count: the body text is what runs either way, and a `$(...)` inside
#              an unquoted body is seen by the outer scan and the recursion alike. The scanner
#              announces each body with a `<HD:len>` marker at the body's first byte, in operator
#              order, so a heredoc's ordinal among all `<<` tokens -- fd-prefixed or not -- is its
#              body's ordinal among the markers.
#
#              A payload piped into the wrapper counts too (#186). The wrapper reads its script
#              from stdin, so the left of the pipe is what it runs -- but only when that side hands
#              the text through unchanged: `cat` with no operand but `-`, and no redirection of its
#              own, passes a heredoc body through, and `echo` / `printf` pass a literal operand (see
#              pipe_producer_payload). A filter may emit something other than what it was given, so
#              `sed <<EOF | bash` is not read as a payload -- denying on text that never reaches the
#              wrapper is a false deny. The wrapper must be the pipe's very NEXT stage, since an
#              intermediate one (`cat <<EOF | tee f | bash`) can change the text on the way. Past the
#              pipe nothing else changes: the payload is handed to the same machinery, so an operand
#              still displaces stdin, a `-c` still claims the payload instead, `-s` still keeps stdin
#              as the script, and the prefix chain is still followed.
#
#              Still not covered: content that is not on the command line at all
#              (`printf '%s' "${script}" | bash`, `curl ... | bash`), and a here-string fed to a
#              wrapper (`bash <<< 'script'`).
#
#              Payloads are NUL-terminated because a heredoc body is usually several lines and
#              has to reach classify_command as one command.
#
#              Command position is tracked exactly as find_invocations tracks it, including the
#              prefix-word chain, so `sudo bash -c ...` is reached.
# @arg $1 command the raw command string
# @arg $2 tokens the token stream from scan_command
# @stdout one payload per NUL, quotes stripped; nothing if there are none
function shell_wrapper_payloads() {
  local -r command="$1" tokens="$2"
  local at_cmd=1 in_wrapper=0 saw_c=0 saw_s=0 saw_s_operand=0 operands=0
  local offset token word next_at_cmd raw budget
  # shellcheck disable=SC2034 # written through prefix_chain_step's namerefs, which shellcheck cannot follow
  local chain='' chain_skip=0 chain_operands=0
  local heredoc_seq=0 body_seq=0 pending='' leading_pending='' wanted=' ' expect_delim=0 len fd
  local expect_redir_target=0
  # The pipeline carry (#186). `seg_*` is the simple command being read right
  # now; `pipe_*` is what an ended segment left behind for the next one, which
  # only the very next command word may claim. `pending_text` is the wrapper's
  # claimed literal payload, held until its simple command ends the same way a
  # heredoc ordinal is.
  local seg_cmd='' seg_heredoc='' seg_redir=0 seg_ok payload w
  local -a seg_words=()
  local pipe_heredoc='' pipe_text='' pipe_text_set=0 last_pipe_offset=-1
  local pending_text='' pending_text_set=0
  # A `<<` heredoc operator may carry a leading fd (`0<<`, `3<<-`), which is
  # ordinary redirection syntax; only fd 0 (empty or explicit `0`) feeds the
  # wrapper's stdin. `<<<` (and an fd-prefixed `0<<<`) is a here-string, not a
  # heredoc, so the next byte after `<<` must not itself be `<`. ERE,
  # evaluated unquoted in [[ =~ ]].
  local -r heredoc_re='^([0-9]*)<<([^<]|$)' bare_heredoc_re='^[0-9]*<<-?$'
  # Any other redirection: an optional fd, then `>`/`<`, `>>`/`<>`, or `&>`.
  # Two other token shapes match it and must therefore stay ABOVE it: a `<<`
  # heredoc operator, and a `<HD:5>` body marker -- both branches above
  # `continue`, so neither ever reaches here. The newline token `<NL>` matches
  # too and cannot be handled that way, since it is an operator that has to
  # reach the flush below, so it is excluded by name.
  # `redir_bare_re` says the operator carries no attached target (`> f` rather
  # than `>f`), in which case the next token is the target and is not an
  # operand either.
  local -r redir_re='^[0-9]*(&?[<>]|[<>]{2})' redir_bare_re='^[0-9]*[<>&|]+$'
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    word="${token##*/}"

    # Heredoc bookkeeping. A bare `<<` / `<<-` token, fd-prefixed or not, is
    # followed by its delimiter as a separate word, which must not be spent
    # as an operand.
    if ((expect_delim == 1)); then
      expect_delim=0
      continue
    fi
    if [[ "${token}" =~ ${bare_heredoc_re} ]]; then
      expect_delim=1
    fi
    if [[ "${token}" =~ ${heredoc_re} ]]; then
      heredoc_seq=$((heredoc_seq + 1))
      fd="${BASH_REMATCH[1]}"
      if [[ -z "${fd}" || "${fd}" == '0' ]]; then
        # Remembered for the pipeline carry whoever owns it: bash applies the
        # LAST stdin heredoc of a simple command, so a later one replaces it.
        seg_heredoc="${heredoc_seq}"
        if ((in_wrapper == 1 && saw_c == 0)); then
          pending="${heredoc_seq}"
        elif ((at_cmd == 1)); then
          # Still hunting for the command word: remember this stdin heredoc
          # in case that word turns out to be a wrapper.
          leading_pending="${heredoc_seq}"
        fi
      fi
      continue
    fi
    if [[ "${token}" == '<HD:'*'>' ]]; then
      body_seq=$((body_seq + 1))
      if [[ "${wanted}" == *" ${body_seq} "* ]]; then
        len="${token#<HD:}"
        len="${len%>}"
        printf '%s\0' "${command:offset:len}"
      fi
      continue
    fi

    # An ordinary redirection on the wrapper's own simple command (`bash <<EOF
    # > /tmp/log`, `bash <<EOF 2>&1`) is neither an operand nor a flag: it
    # neither spends the budget nor ends the wrapper, so a heredoc already
    # pending stays pending. Left to the operand branch below it exhausted a
    # zero budget and dropped the payload, and bash ran the body unclassified.
    if ((expect_redir_target == 1)); then
      # The tokenizer splits `2>&1` into `2>`, `&`, `1`, so the token after a
      # bare operator can be an operator rather than the target. It ends the
      # simple command and must reach the flush below like any other.
      expect_redir_target=0
      is_operator "${token}" || continue
    fi
    if [[ "${token}" != '<NL>' && "${token}" =~ ${redir_re} ]]; then
      [[ "${token}" =~ ${redir_bare_re} ]] && expect_redir_target=1
      # A producer whose own output is redirected sends the wrapper nothing:
      # in `cat > f <<EOF | bash` the body lands in the file and bash reads an
      # empty pipe. Disqualify the segment rather than guess which fd it was.
      seg_redir=1
      continue
    fi

    if ((in_wrapper == 1)); then
      # `-s` in a short cluster says stdin IS the script, so the operands after
      # it are that script's positional parameters ($1...) rather than a script
      # to run in the body's place.
      if [[ "${word}" == -*s* && "${word}" != --* ]]; then
        saw_s=1
      fi
      if is_operator "${token}"; then
        [[ -n "${pending}" ]] && wanted+="${pending} "
        ((pending_text_set == 1)) && printf '%s\0' "${pending_text}"
        in_wrapper=0
        saw_c=0
        saw_s=0
        saw_s_operand=0
        pending=''
        pending_text=''
        pending_text_set=0
      elif ((saw_c == 1)) && [[ "${word}" != -* ]]; then
        raw="${command:offset:${#token}}"
        if [[ ("${raw}" == \"*\" || "${raw}" == \'*\') && ${#raw} -ge 2 ]]; then
          printf '%s\0' "${raw:1:${#raw}-2}"
        fi
        in_wrapper=0
        saw_c=0
        saw_s=0
        saw_s_operand=0
        pending=''
        pending_text=''
        pending_text_set=0
      elif [[ "${word}" == -*c* && "${word}" != --* ]] && ((saw_s_operand == 0)); then
        # A short cluster, so `bash -lc '...'` counts as well as `bash -c '...'`.
        # Once `-s` has taken an operand the wrapper's own option list is over:
        # in `bash -s arg -c '...'` the `-c` and the string after it are $2 and
        # $3 of the body, and nothing here runs that string.
        saw_c=1
      elif [[ "${word}" != -* ]]; then
        # An operand before any `-c`. Spend one from the budget, and once it is
        # gone the wrapper no longer owns the options that follow -- unless
        # `-s` already said stdin is the script, in which case no operand ever
        # displaces the body.
        if ((saw_s == 1)); then
          saw_s_operand=1
        fi
        if ((operands > 0)); then
          operands=$((operands - 1))
        elif ((saw_s == 0)); then
          in_wrapper=0
          saw_c=0
          pending=''
          pending_text=''
          pending_text_set=0
        fi
      fi
    fi

    # The segment's operand words, kept in case it turns out to be a producer
    # on the left of a pipe. A word still in command position is the command
    # itself or a prefix's own option, neither of which the producer prints.
    if ((at_cmd == 0)) && ! is_operator "${token}" && ! is_keyword "${token}"; then
      raw="${command:offset:${#token}}"
      if [[ ("${raw}" == \"*\" || "${raw}" == \'*\') && ${#raw} -ge 2 ]]; then
        seg_words+=("${raw:1:${#raw}-2}")
      else
        seg_words+=("${raw}")
      fi
    fi

    if is_operator "${token}"; then
      if [[ "${token}" == '|' ]] && ((last_pipe_offset != offset - 1)); then
        pipe_heredoc=''
        pipe_text=''
        pipe_text_set=0
        seg_ok=1
        ((seg_redir == 1)) && seg_ok=0
        for w in ${seg_words[@]+"${seg_words[@]}"}; do
          [[ "${w}" == '-' ]] || seg_ok=0
        done
        if ((seg_ok == 1)) && [[ "${seg_cmd}" == 'cat' && -n "${seg_heredoc}" ]]; then
          pipe_heredoc="${seg_heredoc}"
        elif ((seg_redir == 0)) \
          && payload="$(pipe_producer_payload "${seg_cmd}" ${seg_words[@]+"${seg_words[@]}"})"; then
          pipe_text="${payload}"
          pipe_text_set=1
        fi
        last_pipe_offset="${offset}"
      elif [[ "${token}" == '|' ]]; then
        # The second `|` of a `||`, which is a conditional list and not a pipe:
        # nothing crosses it, so drop what the first `|` armed.
        pipe_heredoc=''
        pipe_text=''
        pipe_text_set=0
        last_pipe_offset="${offset}"
      elif [[ "${token}" == '&' ]] && ((last_pipe_offset == offset - 1)); then
        # `|&` extends the pipe it follows, so the carry it armed stands.
        last_pipe_offset="${offset}"
      else
        pipe_heredoc=''
        pipe_text=''
        pipe_text_set=0
      fi
      seg_cmd=''
      seg_heredoc=''
      seg_redir=0
      seg_words=()
      leading_pending=''
    elif is_keyword "${token}"; then
      leading_pending=''
    fi
    if prefix_chain_step "${token}" "${word}" "${at_cmd}" chain chain_skip chain_operands; then
      next_at_cmd=1
    else
      next_at_cmd=0
    fi
    if ((at_cmd == 1 && next_at_cmd == 0)); then
      seg_cmd="${word}"
    fi
    if ((at_cmd == 1)) && budget="$(wrapper_operand_budget "${word}")"; then
      in_wrapper=1
      saw_c=0
      saw_s=0
      saw_s_operand=0
      operands="${budget}"
      pending="${leading_pending}"
      leading_pending=''
      pending_text=''
      pending_text_set=0
      # A heredoc written on the wrapper's own simple command is the one bash
      # applies; the pipe only supplies stdin when nothing else did.
      if [[ -z "${pending}" && -n "${pipe_heredoc}" ]]; then
        pending="${pipe_heredoc}"
      fi
      if ((pipe_text_set == 1)); then
        pending_text="${pipe_text}"
        pending_text_set=1
      fi
      pipe_heredoc=''
      pipe_text=''
      pipe_text_set=0
    elif ((at_cmd == 1 && next_at_cmd == 0)); then
      # A command word that is not a local wrapper: whatever the pipe carried is
      # this command's input, and nothing here runs it as a script.
      pipe_heredoc=''
      pipe_text=''
      pipe_text_set=0
    fi
    at_cmd="${next_at_cmd}"
  done <<< "${tokens}"

  # A wrapper whose simple command runs to the end of the input (`echo 'x' |
  # bash`) meets no operator to flush on. A heredoc payload needs no such
  # flush: its body marker always follows the <NL> that ended that command.
  if ((pending_text_set == 1)); then
    printf '%s\0' "${pending_text}"
  fi
}

# A harness task-output file:
# `${TMPDIR:-/tmp}/claude-<uid>/<project-slug>/<session-uuid>/tasks/<task-id>.output`.
# No /tmp anchor, so a relocated TMPDIR still matches; the `/tasks/` segment
# and the `.output` suffix are what tell it from the session scratchpad next
# door. ERE, evaluated unquoted in [[ =~ ]] under LC_ALL=C.
readonly TASK_OUTPUT_PATH_RE='claude-[0-9]+/[^[:space:]]*/tasks/[^[:space:]/]+\.output'

# The repeat rule (Gap 3, 2026-08-26): the first read of a target is always
# legitimate, the second is defensible, the third inside the window is a poll
# loop with the model as the sleep. Per session, per target.
readonly REPEAT_THRESHOLD=3
readonly REPEAT_WINDOW_SECONDS=300
# The hook has a 5 s timeout budget; a state file large enough to read line by
# line can blow it on its own (measured: 200,000 lines took 19.2 s), and a
# deny returns before the write that would otherwise prune it, so an oversized
# file can never heal itself past this point. Bail out (allow) instead of
# reading past this many lines in one call.
readonly REPEAT_MAX_ENTRIES=5000

# @description Find a loop -- while, until, or for -- whose termination test reads a harness
#              task-output file (Gap 2, 2026-08-26). The harness re-invokes the model when a task
#              finishes, so a shell loop on that file only wastes the wait, and never exits if the
#              task was killed. The scanner masks quoted text, so every token is examined through
#              its RAW slice of the command -- the same byte-offset contract pattern_operand
#              relies on -- which is what makes a quoted path visible. A `NAME=<path>` assignment
#              word binds NAME, and a later `$NAME` / `${NAME...}` counts as a reference to that
#              path; a later reassignment of the same NAME to something else is not tracked, so
#              `F=<task>; F=/other; until [ -s "$F" ]; do sleep 5; done` still reports the first
#              path (accepted limit -- rebinding a poll target mid-script to dodge this is not a
#              pattern worth chasing). Only cond position, or body position with a
#              break/exit/return, is a poll: a lone read, a `while read ...; done < <path>` (the
#              path sits after `done`), and an echoed loop (its keywords are masked, so
#              loop_context sees no loop) all report nothing.
# @arg $1 command the raw command string
# @arg $2 tokens the token stream from scan_command
# @stdout the polled path, starting at `claude-`, when one is found
# @exitcode 0 a poll loop on a task-output file was found
# @exitcode 1 none
function task_poll_detected() {
  local -r command="$1" tokens="$2"
  local -a bound_names=() bound_paths=()
  local idx=0 offset token raw path name i context is_ref ref_re
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    raw="${command:offset:${#token}}"
    path=''
    is_ref=0
    if is_assignment_word "${token}"; then
      if [[ "${raw}" =~ ${TASK_OUTPUT_PATH_RE} ]]; then
        bound_names+=("${token%%=*}")
        bound_paths+=("${BASH_REMATCH[0]}")
      fi
    elif [[ "${raw}" =~ ${TASK_OUTPUT_PATH_RE} ]]; then
      path="${BASH_REMATCH[0]}"
      is_ref=1
    else
      for i in "${!bound_names[@]}"; do
        name="${bound_names[i]}"
        ref_re='\$\{?'"${name}"'([^A-Za-z0-9_]|$)'
        if [[ "${raw}" =~ ${ref_re} ]]; then
          path="${bound_paths[i]}"
          is_ref=1
          break
        fi
      done
    fi
    if ((is_ref == 1)); then
      context="$(loop_context "${tokens}" "${idx}")"
      if [[ "${context}" == 'cond' ]] \
        || { [[ "${context}" == 'body' ]] && body_has_terminator "${tokens}" "${idx}"; }; then
        printf '%s\n' "${path}"
        return 0
      fi
    fi
    idx=$((idx + 1))
  done <<< "${tokens}"
  return 1
}

# @description The targets a command probes, one key per line, deduplicated in first-seen order:
#              `task:<path>` for every harness task-output path in the raw command (quoted or
#              not -- raw slices, as in task_poll_detected; the key starts at `claude-`, so a
#              /tmp and a $TMPDIR spelling of one file share a key), and `pgrep:<operand>` for
#              every pgrep in command position that has a pattern operand -- any pgrep, not only
#              --full. pkill is a kill, not a probe. Wrapper payloads are not descended.
# @arg $1 command the raw command string
# @arg $2 tokens the token stream from scan_command
# @stdout the keys, newline-terminated; nothing when there are none
function probe_keys() {
  local -r command="$1" tokens="$2"
  local keys='' offset token raw key idx name args operand
  if [[ "${command}" == *.output* ]]; then
    while IFS=$'\t' read -r offset token; do
      [[ -z "${token}" ]] && continue
      raw="${command:offset:${#token}}"
      [[ "${raw}" =~ ${TASK_OUTPUT_PATH_RE} ]] || continue
      key="task:${BASH_REMATCH[0]}"
      # A state line is `<epoch>\t<key>\n`; a key carrying either byte would
      # forge a line boundary or field boundary once written.
      [[ "${key}" == *[$'\n\t']* ]] && continue
      if [[ $'\n'"${keys}" != *$'\n'"${key}"$'\n'* ]]; then
        keys+="${key}"$'\n'
      fi
    done <<< "${tokens}"
  fi
  if [[ "${command}" == *pgrep* ]]; then
    while IFS=$'\t' read -r idx offset name; do
      [[ -z "${idx}" || "${name}" != 'pgrep' ]] && continue
      args="$(invocation_args "${tokens}" "${idx}")"
      operand="$(pattern_operand "${command}" "${args}")"
      [[ -z "${operand}" ]] && continue
      key="pgrep:${operand}"
      # Same reasoning as the task-key site above: a state line is
      # `<epoch>\t<key>\n`, so a key carrying either byte would forge one.
      [[ "${key}" == *[$'\n\t']* ]] && continue
      if [[ $'\n'"${keys}" != *$'\n'"${key}"$'\n'* ]]; then
        keys+="${key}"$'\n'
      fi
    done <<< "$(find_invocations "${tokens}")"
  fi
  printf '%s' "${keys}"
}

# @description Build the deny reason for a repeat denial. Built here rather than in deny_message
#              because it carries state (the count and the ages of the earlier probes).
# @arg $1 key the probe key, `task:<path>` or `pgrep:<operand>`
# @arg $2 count this probe's ordinal within the window
# @arg $3 ages the earlier probes' ages, e.g. "42 s ago, 15 s ago"
# @stdout the reason text
function repeat_message() {
  local -r key="$1" count="$2" ages="$3"
  local preamble fixes
  preamble="This is probe ${count} of \`${key}\` within ${REPEAT_WINDOW_SECONDS} s (earlier: ${ages}).
Repeating a one-shot check by hand is a poll loop with the model as the \`sleep\`, and it hangs the
session the same way. The limit is ${REPEAT_THRESHOLD} probes per target per ${REPEAT_WINDOW_SECONDS} s, per session."
  case "${key}" in
    task:*)
      # shellcheck disable=SC2016
      fixes='Two fixes, in order of preference:

1. Stop here. The task notification names this path when the task finishes; Read it then.
2. If the result is needed before you can reply, call `TaskOutput` with `block: true` on the task
   id -- one call returns the output and the exit code.'
      ;;
    *)
      # shellcheck disable=SC2016
      fixes='Two fixes, in order of preference:

1. Do not poll. If this is a background task, its notification re-invokes you when it finishes --
   stop here, or call `TaskOutput` with `block: true` on the task id for the result now.
2. For any other process, probe a PID, not a pattern: `kill -0 "$pid"` on a PID recorded when it
   started (`$!`, a PID file), inside a loop with a `sleep`, not by hand.'
      ;;
  esac
  printf '%s\n\n%s\n\n%s\n' "${WRITE_TOOL_LEAD}" "${preamble}" "${fixes}"
}

# @description The per-session repeat rule. State is one file per session,
#              `<dir>/<session_id>`, of `<epoch>\t<key>` lines, where <dir> is
#              BLOCK_PGREP_STATE_DIR, else $XDG_RUNTIME_DIR/block-pgrep-self-match, else the same
#              under $TMPDIR or /tmp. It is read and rewritten only by commands that carry a key,
#              entries older than the window (or unparsable) are dropped on every write, and a
#              denied command is not recorded. This is the one stateful rule in the guard, so it
#              fails open harder than the rest: every filesystem step is guarded, and any failure
#              -- no dir, unreadable, not a regular file, unwritable, not owned by us, a symlinked
#              dir, or an oversized file -- returns silently (allow) without reaching the ERR
#              trap. The /tmp fallback can be a directory shared with other local users:
#              `mkdir -p` on an EXISTING dir changes neither its owner nor its mode, so `dir` and
#              `file` must both be independently confirmed as ours (a co-tenant who pre-creates
#              or replaces either could otherwise plant state that forces a false deny, or point
#              the write somewhere they control), and the write itself goes through `mktemp`
#              rather than a predictable `${file}.$$` name so a planted symlink at the temp name
#              can't turn it into a truncate-and-write-elsewhere primitive.
# @arg $1 session_id the session id, already validated as a plain file name
# @arg $2 keys the probe keys from probe_keys
# @stdout the deny reason when a key reaches the threshold; nothing otherwise
# @exitcode 0 always
function repeat_check() {
  local -r session_id="$1" keys="$2"
  local -r dir="${BLOCK_PGREP_STATE_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/block-pgrep-self-match}"
  local -r file="${dir}/${session_id}"
  local now
  # POSIX short flags, deliberately: macOS ships BSD coreutils, whose mkdir has
  # no long options at all (no `parents`, no `mode=`). hooks/ is the one
  # directory in this repo exempt from the repo-wide long-options rule, for
  # exactly that reason -- the guard has to run on whatever userland ships.
  # shellcheck disable=SC2174 # -m only binds the deepest dir; the only
  # intermediate ever missing here is a hand-set BLOCK_PGREP_STATE_DIR /
  # TMPDIR, which the caller owns the mode of.
  if ! mkdir -p -m 0700 "${dir}" 2> /dev/null; then return 0; fi
  # `mkdir -p` on a dir that already exists changes neither its owner nor its
  # mode, so under the /tmp fallback another local user who pre-creates this
  # directory (or replaces it with a symlink to one they control) would
  # otherwise be trusted just as much as one we created ourselves.
  [[ -O "${dir}" && ! -L "${dir}" ]] || return 0
  if ! printf -v now '%(%s)T' -1 2> /dev/null; then return 0; fi
  if [[ -e "${file}" && ! -f "${file}" ]]; then return 0; fi
  # Same reasoning as the dir check above, one level down: a pre-planted file
  # we don't own is not state we can trust to prune, count, or overwrite.
  if [[ -f "${file}" && ! -O "${file}" ]]; then return 0; fi

  local kept='' epoch key content
  if [[ -f "${file}" ]]; then
    if [[ ! -r "${file}" ]]; then return 0; fi
    # Read via `cat`, not a `<` redirect (and deliberately not the `$(< file)`
    # builtin fast path): a failed open inside `$(< file)` is a word-expansion
    # error that bash treats as fatal to the shell that hits it, NOT as an
    # ordinary nonzero exit status -- `if !`/`||` cannot absorb it, so it
    # still reaches the ERR trap despite looking guarded (confirmed empirically:
    # `bash -c 'set -Eeuo pipefail; trap "echo TRAP" ERR; f=/nonexistent;
    # if ! c="$(< "$f")" 2>/dev/null; then echo guarded; fi; echo after'`
    # prints only the open-failure diagnostic and exits 1 -- neither "guarded"
    # nor "after" is reached). `cat` forks its own process, so its failure is
    # an ordinary exit status the `if !` below can absorb, and `2> /dev/null`
    # on the `cat` invocation itself (not tacked onto the assignment) applies
    # before that process's own open() attempt, so a TOCTOU race (the file
    # removed between the -r check above and this read) is fully silenced,
    # not just made non-fatal.
    if ! content="$(cat "${file}" 2> /dev/null)"; then return 0; fi
    # `<<<` appends exactly one newline regardless of whether the file (and
    # therefore `content`, which command substitution already stripped
    # trailing newlines from) had one, so every line -- including a
    # newline-less last line -- is delivered to `read` with a terminator; no
    # `|| [[ -n ... ]]` fallback is needed here the way the write-side loops
    # need one for a raw `<` redirect.
    # A leading-zero epoch (`08`) would otherwise pass this regex and then
    # trip `(( ))`'s octal parser on the arithmetic test below, so the
    # anchor excludes it: a valid epoch never starts with 0.
    local read_count=0
    while IFS=$'\t' read -r epoch key; do
      # REPEAT_MAX_ENTRIES caps the work this call can do: a file large
      # enough to read line by line can blow the hook's own timeout on its
      # own, and a deny (or even an allow that falls through to the write
      # below) never happens once we bail here, so an oversized file is left
      # exactly as it was rather than processed at all -- it cannot prune or
      # heal itself past this point, but it also never wedges a real probe.
      read_count=$((read_count + 1))
      ((read_count > REPEAT_MAX_ENTRIES)) && return 0
      [[ "${epoch}" =~ ^[1-9][0-9]{0,11}$ && -n "${key}" ]] || continue
      ((epoch <= now && now - epoch <= REPEAT_WINDOW_SECONDS)) || continue
      kept+="${epoch}"$'\t'"${key}"$'\n'
    done <<< "${content}"
  fi

  local probe_key count ages
  while IFS= read -r probe_key; do
    [[ -z "${probe_key}" ]] && continue
    count=0
    ages=''
    while IFS=$'\t' read -r epoch key; do
      [[ -z "${epoch}" || "${key}" != "${probe_key}" ]] && continue
      count=$((count + 1))
      ages+="$((now - epoch)) s ago, "
    done <<< "${kept}"
    if ((count >= REPEAT_THRESHOLD - 1)); then
      repeat_message "${probe_key}" "$((count + 1))" "${ages%, }"
      return 0
    fi
    kept+="${now}"$'\t'"${probe_key}"$'\n'
  done <<< "${keys}"

  # POSIX short flags in the `rm` and `mv` calls below, deliberately: macOS
  # ships BSD coreutils, where `--force` does not exist. hooks/ is the one
  # directory in this repo exempt from the repo-wide long-options rule, for
  # exactly that reason.
  if [[ -z "${kept}" ]]; then
    # `|| true` so a bare rm failure (e.g. the directory lost write
    # permission after the mkdir check above) can never trip errexit here --
    # this line is not itself guarded by an enclosing if/||, unlike every
    # other filesystem step in this function. `--` guards a session id that
    # happens to start with `-`.
    rm -f -- "${file}" 2> /dev/null || true
    return 0
  fi
  local tmp
  # `mktemp`, not a hand-rolled `${file}.$$` name: a predictable temp name in
  # a shared /tmp lets another local user pre-plant a symlink there, turning
  # the write below into a truncate-and-write-through-the-symlink primitive.
  # mktemp both picks an unpredictable name and creates the file itself
  # (it will not follow an existing symlink at that name), so there is
  # nothing left for a planted symlink to redirect.
  tmp="$(mktemp "${file}.XXXXXX" 2> /dev/null)" || return 0
  # `2> /dev/null` sits before `>` so a failed open reports nothing: with the
  # reverse order bash still applies `>` first, so the open failure prints
  # to the ORIGINAL stderr before the stderr redirect ever takes effect.
  if ! printf '%s' "${kept}" 2> /dev/null > "${tmp}"; then
    rm -f -- "${tmp}" 2> /dev/null
    return 0
  fi
  if ! mv -f -- "${tmp}" "${file}" 2> /dev/null; then
    # Last command of this if-body, so unlike the sibling rm above its exit
    # status would otherwise become the if's status -- `|| true` for the
    # same reason.
    rm -f -- "${tmp}" 2> /dev/null || true
  fi
  return 0
}

# @description Classify a Bash command string.
# @arg $1 command the command string
# @arg $2 depth wrapper-payload recursion depth, 0 for the command the user actually ran
# @stdout allow, warn, or deny:loop / deny:kill / deny:task-poll followed by a tab and the invoked
#         tool (or, for task-poll, the polled path)
function classify_command() {
  local -r command="$1" depth="${2:-0}"
  if [[ "${command}" != *pgrep* && "${command}" != *pkill* && "${command}" != *.output* ]]; then
    printf 'allow\n'
    return 0
  fi
  local tokens
  tokens="$(scan_command "${command}")"

  # Parsed once and shared by every invocation in this command, instead of
  # each of feeds_a_kill / result_is_consumed / invocation_is_captured
  # re-parsing the full token stream from scratch per invocation. A command
  # with many invocations (a long chain of pgrep calls) made that rescan
  # quadratic; array indexing does not.
  local -a CMD_TOKENS=()
  local _ raw_token
  while IFS=$'\t' read -r _ raw_token; do
    [[ -z "${raw_token}" ]] && continue
    CMD_TOKENS+=("${raw_token}")
  done <<< "${tokens}"

  local verdict='allow'
  local idx offset name args operand context
  # The pgrep tier only has work when the command names the tool; the token
  # stream is still needed below for the task-poll tier.
  local invocations=''
  if [[ "${command}" == *pgrep* || "${command}" == *pkill* ]]; then
    invocations="$(find_invocations "${tokens}")"
  fi
  while IFS=$'\t' read -r idx offset name; do
    [[ -z "${idx}" ]] && continue
    args="$(invocation_args "${tokens}" "${idx}")"
    has_flag "${args}" '--full' 'f' || continue
    # `--ignore-ancestors` used to exempt an invocation outright. It excludes
    # ANCESTORS only: a sibling waiter whose command line carries the same
    # literal is still matched, so two waiters for one event deadlock each
    # other (Gap 1, 2026-08-26). It therefore still clears a kill -- the
    # session shell is an ancestor -- and still fixes an inflated count, but
    # it never clears a loop.
    local ignores_ancestors=0
    has_flag "${args}" '--ignore-ancestors' 'A' && ignores_ancestors=1
    operand="$(pattern_operand "${command}" "${args}")"
    bracket_mitigation_holds "${command}" "${operand}" && continue
    if [[ "${name}" == 'pkill' ]] || feeds_a_kill CMD_TOKENS "${idx}"; then
      ((ignores_ancestors == 1)) && continue
      printf 'deny:kill\t%s\n' "${name}"
      return 0
    fi
    context="$(loop_context "${tokens}" "${idx}")"
    case "${context}" in
      cond)
        printf 'deny:loop\t%s\n' "${name}"
        return 0
        ;;
      body)
        if result_is_consumed CMD_TOKENS "${idx}" "${args}" "${command}" "${tokens}" \
          && body_has_terminator "${tokens}" "${idx}"; then
          printf 'deny:loop\t%s\n' "${name}"
          return 0
        fi
        ;;
    esac
    ((ignores_ancestors == 1)) && continue
    result_is_consumed CMD_TOKENS "${idx}" "${args}" "${command}" "${tokens}" && verdict='warn'
  done <<< "${invocations}"

  # A loop on a harness task-output file is denied whatever the pgrep tier
  # thought of the command; a pgrep deny above has already returned.
  if [[ "${command}" == *.output* ]]; then
    local polled
    if polled="$(task_poll_detected "${command}" "${tokens}")"; then
      printf 'deny:task-poll\t%s\n' "${polled}"
      return 0
    fi
  fi

  # A `bash -c '...'` payload, or a heredoc body fed to `bash`, is code that
  # runs here, so it gets the same classification the outer command just got.
  # A deny inside wins outright; a warn inside only lifts an allow, so an
  # outer warn is never downgraded.
  if ((depth < MAX_PAYLOAD_DEPTH)); then
    local payload payload_verdict
    while IFS= read -r -d '' payload; do
      [[ -z "${payload}" ]] && continue
      payload_verdict="$(classify_command "${payload}" "$((depth + 1))")"
      case "${payload_verdict}" in
        deny:*)
          printf '%s\n' "${payload_verdict}"
          return 0
          ;;
        warn) verdict='warn' ;;
      esac
    done < <(shell_wrapper_payloads "${command}" "${tokens}")
  fi

  printf '%s\n' "${verdict}"
}

# @description Entry point.
# @noargs
function main() {
  if ! command -v jq > /dev/null 2>&1; then
    printf '{"systemMessage":"%s"}\n' \
      "${HOOK_NAME}: jq not found on PATH; the pgrep poll-loop guard is INACTIVE for this command."
    return 0
  fi

  # Without these two the scanner call dies, the ERR trap allows, and the guard is
  # silently dead -- which is the exact failure mode this hook exists to prevent.
  # Fail open loudly, the same way the jq branch does.
  if ! command -v awk > /dev/null 2>&1; then
    printf '{"systemMessage":"%s"}\n' \
      "${HOOK_NAME}: awk not found on PATH; the pgrep poll-loop guard is INACTIVE for this command."
    return 0
  fi

  if [[ ! -r "${SCANNER}" ]]; then
    printf '{"systemMessage":"%s"}\n' \
      "${HOOK_NAME}: scanner pgrep-scan.awk is missing; the pgrep poll-loop guard is INACTIVE for this command."
    return 0
  fi

  local input
  input="$(cat)"

  # One jq spawn instead of two, since it runs on every Bash call. The command
  # can contain literal tabs and newlines, which @tsv escapes as `\t` / `\n`
  # rather than emitting them raw -- raw newlines would split a single TSV
  # record across lines, and a raw tab would be indistinguishable from the
  # field separator. `printf '%b'` decodes exactly that escape set (`\\`,
  # `\t`, `\n`, `\r`) as a single left-to-right pass, which is what makes it
  # safe: every backslash jq emits is already paired, so there is no separate
  # unescape step that could reinterpret a decoded literal backslash.
  # session_id rides along in the same @tsv record.
  local tsv_line
  tsv_line="$(jq --raw-output \
    '[(.tool_name // ""), (.tool_input.command // ""), (.session_id // "")] | @tsv' <<< "${input}")"
  local tool_name command_escaped session_id
  IFS=$'\t' read -r tool_name command_escaped session_id <<< "${tsv_line}"
  if [[ "${tool_name}" != 'Bash' ]]; then
    emit_allow
    return 0
  fi

  local command
  command="$(printf '%b' "${command_escaped}")"

  local decision deny_detail
  IFS=$'\t' read -r decision deny_detail <<< "$(classify_command "${command}")"
  if [[ "${decision}" == deny:* ]]; then
    emit_deny "$(deny_message "${decision#deny:}" "${deny_detail}")"
    return 0
  fi

  # The stateful tier runs only after the stateless tiers have allowed (or
  # warned), only for commands that can carry a probe key, and only with a
  # session id that is a plain file name -- no id, no rule, never a global
  # fallback that would leak across concurrent sessions. It costs a second
  # scanner pass on those commands and nothing on any other.
  local repeat_reason=''
  if [[ "${session_id}" =~ ^[A-Za-z0-9._-]+$ && "${session_id}" != '.' && "${session_id}" != '..' ]] \
    && [[ "${command}" == *pgrep* || "${command}" == *.output* ]]; then
    local keys
    keys="$(probe_keys "${command}" "$(scan_command "${command}")")" || keys=''
    if [[ -n "${keys}" ]]; then
      # The `||` is load-bearing beyond the obvious fallback: it is what
      # keeps this whole command substitution off errexit's radar for its
      # entire dynamic extent, so nothing inside repeat_check can trip the
      # top-level ERR trap. Do not turn this into a plain assignment.
      repeat_reason="$(repeat_check "${session_id}" "${keys}")" || repeat_reason=''
    fi
  fi
  # Only a string shaped like repeat_message's output is treated as a deny
  # reason. If the ERR trap ever fired inside the substitution above despite
  # the guard, it would print emit_allow's `{}` to stdout -- non-empty, but
  # not a reason -- and this check keeps that from being emitted as one.
  if [[ "${repeat_reason}" == "${WRITE_TOOL_LEAD}"* ]]; then
    emit_deny "${repeat_reason}"
    return 0
  fi

  case "${decision}" in
    warn)
      emit_warn "${WARN_MESSAGE}"
      ;;
    *)
      emit_allow
      ;;
  esac
}

main "$@"
