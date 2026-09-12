# shellcheck shell=bash
#
# The verdict: classify a command and inspect a payload, sourced by
# hooks/pgrep-pkill-guard-body.sh once the entry script's prefilter has let a
# payload through. Never executed: no shebang, no exec bit, and it must not
# set `set -Eeuo pipefail`, `IFS`, or the ERR trap -- the entry script owns
# all three, and a sourced file that sets them reconfigures its caller. Never
# add `shopt -s inherit_errexit` (invariant 2). POSIX short flags, not GNU
# long options: this runs on BSD userland too (invariant 1).

# A harness task-output file:
# `${TMPDIR:-/tmp}/claude-<uid>/<project-slug>/<session-uuid>/tasks/<task-id>.output`.
# No /tmp anchor, so a relocated TMPDIR still matches; the `/tasks/` segment
# and the `.output` suffix are what tell it from the session scratchpad next
# door. ERE, evaluated unquoted in [[ =~ ]] under LC_ALL=C.
readonly TASK_OUTPUT_PATH_RE='claude-[0-9]+/[^[:space:]]*/tasks/[^[:space:]/]+\.output'

# @description Find a loop -- while, until, or for -- whose termination test reads a harness
#              task-output file (Gap 2, 2026-08-26). The harness re-invokes the model when a task
#              finishes, so a shell loop on that file only wastes the wait, and never exits if the
#              task was killed. The scanner masks quoted text, so every token is examined through
#              its RAW slice of the command -- the same byte-offset contract scanner::pattern_operand
#              relies on -- which is what makes a quoted path visible. A `NAME=<path>` assignment
#              word binds NAME, and a later `$NAME` / `${NAME...}` counts as a reference to that
#              path; a later reassignment of the same NAME to something else is not tracked, so
#              `F=<task>; F=/other; until [ -s "$F" ]; do sleep 5; done` still reports the first
#              path (accepted limit -- rebinding a poll target mid-script to dodge this is not a
#              pattern worth chasing). Only cond position, or body position with a
#              break/exit/return, is a poll: a lone read, a `while read ...; done < <path>` (the
#              path sits after `done`), and an echoed loop (its keywords are masked, so
#              loops::loop_context sees no loop) all report nothing.
# @arg $1 command the raw command string
# @arg $2 tokens the token stream from scanner::scan_command
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
    if tokens::is_assignment_word "${token}"; then
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
      context="$(loops::loop_context "${tokens}" "${idx}")"
      if [[ "${context}" == 'cond' ]] \
        || { [[ "${context}" == 'body' ]] && loops::body_has_terminator "${tokens}" "${idx}"; }; then
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
# @arg $2 tokens the token stream from scanner::scan_command
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
      args="$(scanner::invocation_args "${tokens}" "${idx}")"
      operand="$(scanner::pattern_operand "${command}" "${args}")"
      [[ -z "${operand}" ]] && continue
      key="pgrep:${operand}"
      # Same reasoning as the task-key site above: a state line is
      # `<epoch>\t<key>\n`, so a key carrying either byte would forge one.
      [[ "${key}" == *[$'\n\t']* ]] && continue
      if [[ $'\n'"${keys}" != *$'\n'"${key}"$'\n'* ]]; then
        keys+="${key}"$'\n'
      fi
    done <<< "$(scanner::find_invocations "${tokens}")"
  fi
  printf '%s' "${keys}"
}

# @description Classify one pgrep/pkill invocation the caller has already established carries
#              `--full`: deny for a kill or a loop, warn for a consumed result. `--ignore-ancestors`
#              used to exempt an invocation outright. It excludes ANCESTORS only: a sibling waiter
#              whose command line carries the same literal is still matched, so two waiters for one
#              event deadlock each other (Gap 1, 2026-08-26). It therefore still clears a kill -- the
#              session shell is an ancestor -- and still fixes an inflated count, but it never clears
#              a loop.
# @arg $1 tokens_var name of the command's token array
# @arg $2 command the raw command
# @arg $3 tokens the scanner's token stream for the command
# @arg $4 idx the invocation's token index
# @arg $5 name `pgrep` or `pkill`
# @arg $6 args the invocation's argument tokens (scanner::invocation_args output)
# @stdout `deny:kill<TAB>name`, `deny:loop<TAB>name`, or `warn`
# @exitcode 0 a verdict was printed
# @exitcode 1 the invocation is clean or exempt; nothing printed
function classify_invocation() {
  local -r tokens_var="$1" command="$2" tokens="$3" idx="$4" name="$5" args="$6"
  local operand context ignores_ancestors=0
  scanner::has_flag "${args}" '--ignore-ancestors' 'A' && ignores_ancestors=1
  operand="$(scanner::pattern_operand "${command}" "${args}")"
  scanner::bracket_mitigation_holds "${command}" "${operand}" && return 1
  if [[ "${name}" == 'pkill' ]] || feeds_a_kill "${tokens_var}" "${idx}"; then
    ((ignores_ancestors == 1)) && return 1
    printf 'deny:kill\t%s\n' "${name}"
    return 0
  fi
  context="$(loops::loop_context "${tokens}" "${idx}")"
  case "${context}" in
    cond)
      printf 'deny:loop\t%s\n' "${name}"
      return 0
      ;;
    body)
      if result_is_consumed "${tokens_var}" "${idx}" "${args}" "${command}" "${tokens}" \
        && loops::body_has_terminator "${tokens}" "${idx}"; then
        printf 'deny:loop\t%s\n' "${name}"
        return 0
      fi
      ;;
  esac
  ((ignores_ancestors == 1)) && return 1
  if result_is_consumed "${tokens_var}" "${idx}" "${args}" "${command}" "${tokens}"; then
    printf 'warn\n'
    return 0
  fi
  return 1
}

# @description Classify the code a shell wrapper in this command would run: a `bash -c '...'`
#              payload, or a heredoc body fed to `bash`, gets the same classification the outer
#              command just got. A deny inside wins outright; a warn inside only lifts an allow.
#              Bounded by MAX_PAYLOAD_DEPTH so a payload that wraps a payload cannot recurse forever.
# @arg $1 command the raw command
# @arg $2 tokens the scanner's token stream for the command
# @arg $3 depth the current nesting depth
# @stdout `inactive`, a `deny:...` verdict line, or `warn`
# @exitcode 0 a verdict was printed
# @exitcode 1 no payload changes the outer verdict; nothing printed
function classify_wrapper_payloads() {
  local -r command="$1" tokens="$2" depth="$3"
  ((depth < MAX_PAYLOAD_DEPTH)) || return 1
  local payload payload_verdict lifted=0
  while IFS= read -r -d '' payload; do
    [[ -z "${payload}" ]] && continue
    payload_verdict="$(classify_command "${payload}" "$((depth + 1))")"
    # An untrustworthy inner scan must not be reported as a clean allow.
    if [[ "${payload_verdict}" == inactive* ]]; then
      printf 'inactive\n'
      return 0
    fi
    case "${payload_verdict}" in
      deny:*)
        printf '%s\n' "${payload_verdict}"
        return 0
        ;;
      warn) lifted=1 ;;
    esac
  done < <(shell_wrapper_payloads "${command}" "${tokens}")
  if ((lifted == 1)); then
    printf 'warn\n'
    return 0
  fi
  return 1
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
  # The scanner produced an untrustworthy stream (see the trailer comment in
  # pgrep-scan.awk). Return a verdict rather than printing: this function runs
  # inside a command substitution, so a printf here would be captured, not
  # emitted, and the guard would go silently dead.
  tokens="$(scanner::scan_command "${command}")" || {
    printf 'inactive\n'
    return 0
  }

  # Parsed once and shared by every invocation in this command, instead of
  # each of feeds_a_kill / result_is_consumed / invocation_is_captured
  # re-parsing the full token stream from scratch per invocation. A command
  # with many invocations (a long chain of pgrep calls) made that rescan
  # quadratic; array indexing does not.
  local -a cmd_tokens=()
  local _ raw_token
  while IFS=$'\t' read -r _ raw_token; do
    [[ -z "${raw_token}" ]] && continue
    cmd_tokens+=("${raw_token}")
  done <<< "${tokens}"

  local verdict='allow'
  local idx offset name args invocation_finding
  # The pgrep tier only has work when the command names the tool; the token
  # stream is still needed below for the task-poll tier.
  local invocations=''
  if [[ "${command}" == *pgrep* || "${command}" == *pkill* ]]; then
    invocations="$(scanner::find_invocations "${tokens}")"
  fi
  while IFS=$'\t' read -r idx offset name; do
    [[ -z "${idx}" ]] && continue
    args="$(scanner::invocation_args "${tokens}" "${idx}")"
    scanner::has_flag "${args}" '--full' 'f' || continue
    if invocation_finding="$(classify_invocation cmd_tokens "${command}" "${tokens}" "${idx}" "${name}" \
      "${args}")"; then
      case "${invocation_finding}" in
        deny:*)
          printf '%s\n' "${invocation_finding}"
          return 0
          ;;
        warn) verdict='warn' ;;
      esac
    fi
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

  local payload_finding
  if payload_finding="$(classify_wrapper_payloads "${command}" "${tokens}" "${depth}")"; then
    case "${payload_finding}" in
      warn) verdict='warn' ;;
      *)
        printf '%s\n' "${payload_finding}"
        return 0
        ;;
    esac
  fi

  printf '%s\n' "${verdict}"
}

# @description The guard's runtime preconditions, checked only once a payload has passed the
#              prefilter: a command with no trigger token returns `{}` whether or not `jq` exists, so
#              warning about an inactive guard on those calls would be noise about a call the guard
#              was never going to act on. Without `jq`, `awk` or the scanner the guard would die and
#              the ERR trap would allow silently -- the exact failure this hook exists to prevent --
#              so each failure is reported as INACTIVE, loudly, on stdout.
# @noargs
# @stdout on failure, one `{"systemMessage":...}` line
# @exitcode 0 every precondition holds
# @exitcode 1 one does not; the message is already on stdout
function inspect_preconditions() {
  if ! command -v jq > /dev/null 2>&1; then
    printf '{"systemMessage":"%s"}\n' \
      "${HOOK_NAME}: jq not found on PATH; the pgrep poll-loop guard is INACTIVE for this command."
    return 1
  fi
  if ! command -v awk > /dev/null 2>&1; then
    printf '{"systemMessage":"%s"}\n' \
      "${HOOK_NAME}: awk not found on PATH; the pgrep poll-loop guard is INACTIVE for this command."
    return 1
  fi
  if [[ ! -r "${SCANNER}" ]]; then
    printf '{"systemMessage":"%s"}\n' \
      "${HOOK_NAME}: scanner pgrep-scan.awk is missing; the pgrep poll-loop guard is INACTIVE for this command."
    return 1
  fi
  return 0
}

# @description The stateful tier. Runs only after the stateless tiers have allowed (or warned),
#              only for commands that can carry a probe key, and only with a session id that is a
#              plain file name -- no id, no rule, never a global fallback that would leak across
#              concurrent sessions. It costs a second scanner pass on those commands and nothing on
#              any other.
# @arg $1 command the decoded command
# @arg $2 session_id the hook payload's session id, possibly empty
# @stdout the repeat deny reason, when the rule fires
# @exitcode 0 a reason was printed
# @exitcode 1 the rule does not apply, or did not fire; nothing printed
# @exitcode 2 the rescan failed; the caller reports the scanner as INACTIVE
function repeat_tier_reason() {
  local -r command="$1" session_id="$2"
  [[ "${session_id}" =~ ^[A-Za-z0-9._-]+$ && "${session_id}" != '.' && "${session_id}" != '..' ]] || return 1
  [[ "${command}" == *pgrep* || "${command}" == *.output* ]] || return 1
  local keys rt_tokens reason
  # Split out of the nested substitution deliberately: with the scan inlined
  # into probe_keys' arguments, a scanner failure would be swallowed by the
  # `|| keys=''` below and read as "this command carries no probe key".
  rt_tokens="$(scanner::scan_command "${command}")" || return 2
  keys="$(probe_keys "${command}" "${rt_tokens}")" || keys=''
  [[ -n "${keys}" ]] || return 1
  # The `||` is load-bearing beyond the obvious fallback: it is what keeps this
  # whole command substitution off errexit's radar for its entire dynamic
  # extent, so nothing inside repeat_check can trip the top-level ERR trap. Do
  # not turn this into a plain assignment.
  reason="$(repeat_check "${session_id}" "${keys}")" || reason=''
  [[ -n "${reason}" ]] || return 1
  printf '%s\n' "${reason}"
  return 0
}

# @description Everything the guard does once the prefilter has decided the payload is worth
#              looking at: the preconditions, the jq extraction, the stateless tiers, the
#              stateful repeat tier, and emission. Split out of `main` so the entry script can
#              stay small enough to parse cheaply -- see the header of this file.
# @arg $1 input the raw hook JSON payload, exactly as read from stdin
# @stdout the hook's JSON response
function inspect_command() {
  local -r input="$1"

  # Past the short-circuit the scanner is about to be needed, so resolve it now.
  # This is the first thing below the prefilter because the scanner readability
  # guard a few lines down is one of its two readers.
  scanner::resolve_scanner

  # Below here the guard is actually going to look at the command, so the
  # preconditions matter. These sit AFTER the prefilter on purpose: a command
  # with no trigger token returns `{}` whether or not `jq` exists, so warning
  # about an inactive guard on those calls is noise about a call the guard was
  # never going to act on. The first pgrep loop the user types still warns them.
  inspect_preconditions || return 0

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
  # main owns stdout; classify_command does not, so it hands the condition up as
  # a verdict and the message is emitted here.
  case "${decision}" in
    'inactive')
      printf '{"systemMessage":"%s"}\n' \
        "${HOOK_NAME}: the command scanner tokenized this command incorrectly (incompatible awk?); the pgrep/pkill guard is INACTIVE for this command."
      return 0
      ;;
    deny:*)
      messages::emit_deny "$(messages::deny_message "${decision#deny:}" "${deny_detail}")"
      return 0
      ;;
  esac

  local repeat_reason='' repeat_rc=0
  # `|| repeat_rc=$?` rather than a plain assignment: the `||` keeps the whole
  # substitution -- and repeat_check inside it -- off errexit's radar, and the
  # status tells a rescan failure (2) apart from "no rule fired" (1).
  repeat_reason="$(repeat_tier_reason "${command}" "${session_id}")" || repeat_rc=$?
  if ((repeat_rc == 2)); then
    printf '{"systemMessage":"%s"}\n' \
      "${HOOK_NAME}: the command scanner tokenized this command incorrectly (incompatible awk?); the pgrep/pkill guard is INACTIVE for this command."
    return 0
  fi
  # Only a string shaped like messages::repeat_message's output is treated as a deny
  # reason. If the ERR trap ever fired inside the substitution above despite
  # the guard, it would print emit_allow's `{}` to stdout -- non-empty, but
  # not a reason -- and this check keeps that from being emitted as one.
  if [[ "${repeat_reason}" == "${WRITE_TOOL_LEAD}"* ]]; then
    messages::emit_deny "${repeat_reason}"
    return 0
  fi

  case "${decision}" in
    warn)
      messages::emit_warn "${WARN_MESSAGE}"
      ;;
    *)
      emit_allow
      ;;
  esac
}
