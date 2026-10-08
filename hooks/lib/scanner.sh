# shellcheck shell=bash
#
# The awk scanner interface: run it, walk its invocations, read their flags and
# operands, sourced by hooks/pgrep-pkill-guard-body.sh whenever the entry
# script loads the body -- in human mode, or once the prefilter has let a
# payload through. Never executed: no shebang, no exec bit, and it must not set
# `set -Eeuo pipefail`, `IFS`, or the ERR trap -- the entry script owns them
# all, and a sourced file that sets them reconfigures its caller. Never add
# `shopt -s inherit_errexit` (invariant 2). Long options only where the BSD
# tool has them: this runs on BSD userland too (invariant 1).

# Long options that take a separate value, so that value is not the operand.
readonly -a PGREP_VALUE_OPTIONS=(
  '--delimiter' '--parent' '--pgroup' '--session' '--terminal' '--uid' '--euid'
  '--group' '--ns' '--nslist' '--signal' '--older'
)

# @description Resolve the path to the awk scanner and freeze it. Called once, from
#              classify::inspect_command. HOOK_DIR was resolved by the entry script before it sourced this
#              file, so this costs no process of its own -- see resolve_hook_dir over there.
# @set SCANNER the absolute path to pgrep-scan.awk, or the test override
# @noargs
function scanner::resolve_scanner() {
  # Test seam: lets the suite point the hook at a deliberately broken scanner to
  # prove the integrity check deactivates the guard loudly. Production never sets
  # it; the default is resolved relative to the entry script.
  SCANNER="${PGREP_GUARD_SCANNER_OVERRIDE:-${HOOK_DIR}/pgrep-scan.awk}"
  # `readonly` inside a function still freezes the GLOBAL, so SCANNER cannot be
  # reassigned once resolved.
  readonly SCANNER
}

# @description Tokenize a command, masking quoted regions, and verify the
#              scanner's integrity trailer before handing the stream back. See
#              the trailer comment at the foot of pgrep-scan.awk for what the
#              check catches and why it is in-band rather than an `exit 1`.
# @arg $1 command the command string
# @stdout offset and token pairs, separated by tab, trailer stripped
# @exitcode 0 the stream is trustworthy
# @exitcode 1 the scanner failed to run or exited non-zero, or it tokenized the
#             command incorrectly; the caller must deactivate the guard rather
#             than trust the stream
function scanner::scan_command() {
  local -r command="$1"
  local raw expected
  # The scanner reads lines and reassembles them, so the input MUST end with
  # exactly one newline: that terminator is how it distinguishes a command
  # ending in a newline from one that does not, and it is dropped on the way
  # in. `printf '%s'` here would silently shorten every command ending in a
  # newline by one byte and trip the trailer below.
  raw="$(printf '%s\n' "${command}" | LC_ALL=C awk -f "${SCANNER}")" || return 1
  # Every byte accounted for.
  expected=$'\t'"<SCAN:${#command}>"
  [[ "${raw}" == *"${expected}"* ]] || return 1
  printf '%s' "${raw%"${expected}"*}"
}

# @description Locate pgrep/pkill invocations that sit in command position. A quoted mention such as
#              `grep -r "until ! pgrep --full"` yields nothing, because the scanner masked it. A
#              leading run of prefix words (`sudo`, `command`, ...) keeps command position, and the
#              token is matched on its basename so `/usr/bin/pgrep` counts. A leading run of shell
#              assignment words (`FOO=bar pgrep ...`, `LC_ALL=C env FOO=bar pkill ...`) does too:
#              `NAME=value` in front of a command is ordinary shell, not an argument, and without
#              this the assignment hides the invocation from the whole scan -- not just from the
#              kill/loop tiers -- because `at_cmd` drops to 0 and the pgrep/pkill token itself is
#              never recorded. A redirection anywhere in front of the command word
#              (`2> /dev/null pkill ...`, `sudo >f pkill ...`, `FOO=1 >f pkill ...`) is skipped
#              with its target, by tokens::redirection_step, for the same reason.
#
#              A process substitution (`<(...)`, `>(...)`) is one word of the simple command around
#              it, so `cat <(echo x) pkill --full X` has no invocation: `pkill` is `cat`'s argument.
#              Its body is a command list of its own, and does have invocations. The `)` that
#              closes it gives the state back as it stood at the opener, after one word, found by
#              tokens::region_step.
# @arg $1 command the raw command string
# @arg $2 tokens newline-separated "<offset>\t<token>" records from scanner::scan_command
# @stdout lines of "<index>\t<offset>\t<basename>"
function scanner::find_invocations() {
  local -r command="$1" tokens="$2"
  # shellcheck disable=SC2034 # written through tokens::prefix_chain_step's namerefs, which shellcheck cannot follow
  local at_cmd=1 idx=0 offset token word chain='' chain_skip=0 chain_operands=0 redir='' kind
  local -a saved=()
  local -A region=()
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    tokens::region_step "${command}" "${offset}" "${token}" region kind
    # A process substitution is one word of the simple command around it. Its body is a command
    # list of its own, which the `(` starts, and the `)` that ends it hands the state back as it
    # stood at the opener, after that one word.
    if [[ "${kind}" == 'S' ]]; then
      saved+=("${at_cmd}:${chain}:${chain_skip}:${chain_operands}")
    elif [[ "${kind}" == 'close' && "${region[closed]}" == 'S' ]]; then
      IFS=':' read -r at_cmd chain chain_skip chain_operands <<< "${saved[-1]}"
      unset 'saved[-1]'
      if tokens::prefix_chain_step 'procsub' 'procsub' "${at_cmd}" chain chain_skip chain_operands; then
        at_cmd=1
      else
        at_cmd=0
      fi
      redir=''
      idx="$((idx + 1))"
      continue
    fi
    # A redirection is neither the command word nor a prefix's word, wherever it sits: it leaves
    # command position, the chain and a pending option value exactly as they were.
    if tokens::redirection_step "${token}" redir; then
      idx="$((idx + 1))"
      continue
    fi
    word="${token##*/}"
    if ((at_cmd == 1)) && [[ "${word}" == 'pgrep' || "${word}" == 'pkill' ]]; then
      printf '%s\t%s\t%s\n' "${idx}" "${offset}" "${word}"
    fi
    if tokens::prefix_chain_step "${token}" "${word}" "${at_cmd}" chain chain_skip chain_operands; then
      at_cmd=1
    else
      at_cmd=0
    fi
    idx="$((idx + 1))"
  done <<< "${tokens}"
}

# @description Collect one invocation's argument tokens: everything after the command name, up to
#              the operator that ends the simple command. A redirection (operator, the `&` or `|` of
#              `>&` and `>|`, and target) is not an argument and is dropped, so `2>&1 -f java` keeps
#              `-f` and `java`, and `<<-EOF` leaves no `EOF` to be read as the pattern. Which tokens
#              belong to a redirection is tokens::redirection_step's call.
#
#              A `$(...)`, `$((...))` or backtick region after the command name is a word of this
#              simple command, not the end of it: `pkill $(true) --full X` keeps `--full` and `X`.
#              The region's own tokens are dropped and the `$` word it hangs off stays. A process
#              substitution (`<(...)`, `>(...)`) is a word of the simple command too and is dropped
#              whole, so `pkill <(echo x) --full X` keeps `--full` and `X`. A token glued directly
#              behind the close (the `x` of `$(true)x`) belongs to that same word and is dropped.
#              The regions are the scanner's, found by tokens::region_step. An invocation that sits
#              inside a region (`$(pgrep ...)`) ends at that region's own close.
# @arg $1 command the raw command string
# @arg $2 tokens the token stream from scanner::scan_command
# @arg $3 target index of the pgrep/pkill token itself
# @stdout lines of "<offset>\t<token>"
function scanner::invocation_args() {
  local -r command="$1" tokens="$2" target="$3"
  # shellcheck disable=SC2034 # written through tokens::redirection_step's nameref, which shellcheck cannot follow
  local idx=0 offset token redir='' kind skip base=0 glue_at=-1
  local -A region=()
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    tokens::region_step "${command}" "${offset}" "${token}" region kind
    skip=0
    # The `<` or `>` before a process substitution's `(` set the redirection state; the region
    # is skipped whole, so nothing else would clear it and the next word would read as a target.
    [[ "${kind}" == 'S' ]] && redir=''
    if ((idx == target)); then
      base="${#region[kinds]}"
    elif ((idx > target)); then
      if [[ "${kind}" == 'close' ]]; then
        ((${#region[kinds]} < base)) && break
        glue_at="$((offset + 1))"
        skip=1
      elif [[ -n "${kind}" ]] || ((${#region[kinds]} > base)); then
        skip=1
      elif ((offset == glue_at)) && ! tokens::is_operator "${token}" \
        && [[ "${token}" != '<'* && "${token}" != *'>'* ]]; then
        skip=1
      fi
      if ((skip == 0)); then
        tokens::redirection_step "${token}" redir || {
          tokens::is_operator "${token}" && break
          printf '%s\t%s\n' "${offset}" "${token}"
        }
      fi
    fi
    idx="$((idx + 1))"
  done <<< "${tokens}"
}

# @description True when an invocation's arguments carry a flag, as either the long option or a
#              short cluster containing the letter. A bare -- ends option parsing.
# @arg $1 args newline-separated "<offset>\t<token>" lines
# @arg $2 long the long option, for example --full
# @arg $3 short the short cluster letter, for example f
# @exitcode 0 the flag is present
# @exitcode 1 it is absent
function scanner::has_flag() {
  local -r args="$1" long="$2" short="$3"
  local offset token
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    case "${token}" in
      '--') return 1 ;;
      # Quoted, so the long option matches literally rather than as a pattern.
      "${long}") return 0 ;;
      --*) ;;
      -[a-zA-Z]*)
        if [[ "${token}" == *"${short}"* ]]; then
          return 0
        fi
        ;;
    esac
  done <<< "${args}"
  return 1
}

# @description Extract the search pattern: the last argument that is neither a flag nor the separate
#              value of a long option in PGREP_VALUE_OPTIONS. A short flag's separate value is not
#              recognised and counts as a candidate. Once a bare -- end-of-options terminator is
#              seen, every later token is a pattern candidate regardless of a leading dash. The
#              arguments carry no redirection (scanner::invocation_args drops it). Sliced out of the
#              raw command by offset so the original quoting survives, then one surrounding quote pair
#              is stripped.
# @arg $1 command the raw command string
# @arg $2 args newline-separated "<offset>\t<token>" lines
# @stdout the operand with surrounding quotes removed, or empty
function scanner::pattern_operand() {
  local -r command="$1" args="$2"
  local operand_offset='' operand_length=0 skip=0 past_terminator=0 offset token value_option
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    if ((skip == 1)); then
      skip=0
      continue
    fi
    if ((past_terminator == 1)); then
      operand_offset="${offset}"
      operand_length="${#token}"
      continue
    fi
    case "${token}" in
      '--')
        past_terminator=1
        continue
        ;;
      --*)
        for value_option in "${PGREP_VALUE_OPTIONS[@]}"; do
          [[ "${token}" == "${value_option}" ]] && skip=1 && break
        done
        ;;
      -*) : ;;
      *)
        operand_offset="${offset}"
        operand_length="${#token}"
        ;;
    esac
  done <<< "${args}"
  [[ -z "${operand_offset}" ]] && return 0
  local raw="${command:operand_offset:operand_length}"
  if [[ "${raw}" == \"*\" || "${raw}" == \'*\' ]]; then
    raw="${raw:1:${#raw}-2}"
  fi
  printf '%s' "${raw}"
}

# @description Decide whether a bracket-class pattern actually defeats self-match. It does only when
#              the de-bracketed literal appears nowhere else in the command line: a single-character
#              class hides the needle from its own regex, but an unbracketed copy elsewhere in the
#              same `bash -c` argument puts it straight back.
# @arg $1 command the raw command string
# @arg $2 operand the pattern operand, quotes already stripped
# @exitcode 0 the mitigation holds
# @exitcode 1 no bracket class, a class that cannot be reduced to a bare literal, or the
#             bare literal occurs elsewhere
function scanner::bracket_mitigation_holds() {
  local -r command="$1" operand="$2"
  case "${operand}" in
    *\[?\]*) ;;
    *) return 1 ;;
  esac
  local bare="${operand}"
  local prefix rest
  while [[ "${bare}" == *\[?\]* ]]; do
    prefix="${bare%%\[?\]*}"
    rest="${bare#"${prefix}"}"
    bare="${prefix}${rest:1:1}${rest:3}"
  done
  # A surviving `[` means an unresolved class opener whose literal text cannot be
  # reconstructed. A surviving `]` is just a literal character and is fine.
  case "${bare}" in
    '' | *\[*) return 1 ;;
  esac
  [[ "${command}" == *"${bare}"* ]] && return 1
  return 0
}
