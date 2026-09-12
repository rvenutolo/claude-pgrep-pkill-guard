# shellcheck shell=bash
#
# The awk scanner interface: run it, walk its invocations, read their flags
# and operands, sourced by hooks/pgrep-pkill-guard-body.sh once the entry
# script's prefilter has let a payload through. Never executed: no shebang, no
# exec bit, and it must not set `set -Eeuo pipefail`, `IFS`, or the ERR trap
# -- the entry script owns all three, and a sourced file that sets them
# reconfigures its caller. Never add `shopt -s inherit_errexit` (invariant 2).
# POSIX short flags, not GNU long options: this runs on BSD userland too
# (invariant 1).

# @description Resolve the path to the awk scanner and freeze it. Called once, from
#              inspect_command. HOOK_DIR was resolved by the entry script before it sourced this
#              file, so this costs no process of its own -- see resolve_hook_dir over there.
# @set SCANNER the absolute path to pgrep-scan.awk, or the test override
# @noargs
function scanner::resolve_scanner() {
  # Test seam: lets the suite point the hook at a deliberately broken scanner to
  # prove the integrity check deactivates the guard loudly. Production never sets
  # it; the default is resolved relative to the entry script.
  SCANNER="${PGREP_GUARD_SCANNER_OVERRIDE:-${HOOK_DIR}/pgrep-scan.awk}"
  # `readonly` inside a function still freezes the GLOBAL, which is what keeps
  # the immutability this had when it was a top-level `readonly SCANNER=...`.
  readonly SCANNER
}
# @description Tokenize a command, masking quoted regions, and verify the
#              scanner's integrity trailer before handing the stream back. See
#              the trailer comment at the foot of pgrep-scan.awk for what the
#              check catches and why it is in-band rather than an `exit 1`.
# @arg $1 command the command string
# @stdout offset and token pairs, separated by tab, trailer stripped
# @exitcode 0 the stream is trustworthy
# @exitcode 1 the scanner tokenized the command incorrectly; the caller must
#             deactivate the guard rather than trust the stream
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
#              never recorded.
# @arg $1 tokens newline-separated "<offset>\t<token>" records from scanner::scan_command
# @stdout lines of "<index>\t<offset>\t<basename>"
function scanner::find_invocations() {
  # shellcheck disable=SC2034 # written through tokens::prefix_chain_step's namerefs in lib/tokens.sh
  local at_cmd=1 idx=0 offset token word chain='' chain_skip=0 chain_operands=0
  local -r tokens="$1"
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    word="${token##*/}"
    if ((at_cmd == 1)) && [[ "${word}" == 'pgrep' || "${word}" == 'pkill' ]]; then
      printf '%s\t%s\t%s\n' "${idx}" "${offset}" "${word}"
    fi
    if tokens::prefix_chain_step "${token}" "${word}" "${at_cmd}" chain chain_skip chain_operands; then
      at_cmd=1
    else
      at_cmd=0
    fi
    idx=$((idx + 1))
  done <<< "${tokens}"
}

# @description Collect one invocation's argument tokens: everything after the command name, up to
#              the operator that ends the simple command.
# @arg $1 tokens the token stream from scanner::scan_command
# @arg $2 target index of the pgrep/pkill token itself
# @stdout lines of "<offset>\t<token>"
function scanner::invocation_args() {
  local -r tokens="$1"
  local -r target="$2"
  local idx=0 offset token
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    if ((idx > target)); then
      tokens::is_operator "${token}" && break
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
function scanner::has_flag() {
  local -r args="$1" long="$2" short="$3"
  local offset token
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    [[ "${token}" == '--' ]] && return 1
    [[ "${token}" == "${long}" ]] && return 0
    if [[ "${token}" == -[a-zA-Z]* && "${token}" != --* && "${token}" == *"${short}"* ]]; then
      return 0
    fi
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
# @exitcode 1 no bracket class, or the bare literal occurs elsewhere
function scanner::bracket_mitigation_holds() {
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
