# shellcheck shell=bash
#
# Every message the guard emits: warn and deny envelopes, deny reasons, repeat
# reasons, sourced by hooks/pgrep-pkill-guard-body.sh once the entry script's
# prefilter has let a payload through. Never executed: no shebang, no exec
# bit, and it must not set `set -Eeuo pipefail`, `IFS`, or the ERR trap -- the
# entry script owns all three, and a sourced file that sets them reconfigures
# its caller. Never add `shopt -s inherit_errexit` (invariant 2). POSIX short
# flags, not GNU long options: this runs on BSD userland too (invariant 1).

# @description Allow the command but attach model-visible context.
#              additionalContext is the only PreToolUse field verified to reach
#              the model on an allowed call; systemMessage renders to the user
#              only, and permissionDecisionReason is fed back under deny alone.
# @arg $1 text the message the model should read
function messages::emit_warn() {
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
function messages::emit_deny() {
  local -r text="$1"
  jq --null-input --arg msg "${text}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $msg
    }
  }'
}

# shellcheck disable=SC2016 # backticks are markdown spans in the emitted text
# shellcheck disable=SC2034 # read by lib/classify.sh
readonly WARN_MESSAGE='Note: this `pgrep --full` also matches the process running this very command.
The Bash tool executes commands as `bash -c ...`, so the search pattern appears in an ancestor
process command line and is always found. The result is therefore inflated by one, and an exit status
of 0 does not mean the target process is running. Add `--ignore-ancestors` if the count or the exit
status is being used for anything.'

# Every deny leads with the escape hatch for the one legitimate reason to put a
# denied shape in a Bash command: writing prose that quotes it. It used to
# trail the fixes, where it was read last or not at all.
# shellcheck disable=SC2016 # backticks are markdown spans in the emitted text
readonly WRITE_TOOL_LEAD='If this command WRITES text that contains such an example (a heredoc, `echo`, or `printf` into
a file) rather than running one, use the Write tool instead; this guard only inspects Bash commands.'

# @description Build the deny reason for a deny kind.
# @arg $1 kind loop, kill, or task-poll
# @arg $2 detail the tool for kill (pgrep or pkill; defaults to pgrep), or the polled path for
#         task-poll
# @stdout the reason text: the Write-tool lead, a preamble, and a fixes list
function messages::deny_message() {
  local -r kind="$1"
  local -r detail="${2:-pgrep}"
  local preamble fixes

  case "${kind}" in
    loop)
      # shellcheck disable=SC2016 # backticks are markdown spans in the deny text
      preamble='This loop can never exit. The Bash tool runs commands as `bash -c ...`, so the search
pattern is by construction part of an ancestor process command line. `pgrep --full` matches that
ancestor, the loop always sees a live process, and it spins until something kills it.

`--ignore-ancestors` does not rescue a loop. It excludes ANCESTORS only: a second waiter for the
same event -- a sibling background shell whose command line carries the same literal -- is matched
by the first, and the first by the second, and both spin until killed. Never write two waiters for
one event.'
      # shellcheck disable=SC2016 # `$pid` and backticks are literal deny text
      fixes='Two fixes, in order of preference:

1. Do not poll. A background task re-invokes you with a task notification when it finishes: stop
   here and Read the output path it names. If the result is needed before you can reply, call
   `TaskOutput` with `block: true` on the task id -- one call returns the output and the exit
   code. Polling is the root cause; this loop is a symptom.
2. Poll a PID, not a pattern: `while kill -0 "$pid" 2>/dev/null; do sleep 5; done`, with `$pid`
   recorded when the process was started (`$!`, a PID file). A PID cannot match a sibling.'
      ;;
    kill)
      # shellcheck disable=SC2016 # backticks are markdown spans in the deny text
      preamble='This matches the invoking shell itself. The Bash tool runs commands as `bash -c ...`,
so the search pattern is part of an ancestor process command line, and killing that match terminates
the session shell.'
      # Kill denials get targeting advice, not anti-polling advice, and the
      # examples name the tool that was actually invoked (#152).
      # shellcheck disable=SC2016 # `$pid` and backticks are literal deny text
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
      # shellcheck disable=SC2016 # backticks are markdown spans in the deny text
      preamble='This loop polls a harness task-output file (`'"${detail}"'`). Background tasks are
tracked by the harness itself: when one finishes you are re-invoked with a task notification naming
that path, so polling it from a shell only wastes the wait -- and if the task is killed the file may
never change, so the loop never exits.'
      # shellcheck disable=SC2016 # backticks are markdown spans in the deny text
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

# @description Build the deny reason for a repeat denial. Built here rather than in messages::deny_message
#              because it carries state (the count and the ages of the earlier probes).
# @arg $1 key the probe key, `task:<path>` or `pgrep:<operand>`
# @arg $2 count this probe's ordinal within the window
# @arg $3 ages the earlier probes' ages, e.g. "42 s ago, 15 s ago"
# @stdout the reason text
function messages::repeat_message() {
  local -r key="$1" count="$2" ages="$3"
  local preamble fixes
  preamble="This is probe ${count} of \`${key}\` within ${REPEAT_WINDOW_SECONDS} s (earlier: ${ages}).
Repeating a one-shot check by hand is a poll loop with the model as the \`sleep\`, and it hangs the
session the same way. The limit is ${REPEAT_THRESHOLD} probes per target per ${REPEAT_WINDOW_SECONDS} s, per session."
  case "${key}" in
    task:*)
      # shellcheck disable=SC2016 # backticks are markdown spans in the repeat text
      fixes='Two fixes, in order of preference:

1. Stop here. The task notification names this path when the task finishes; Read it then.
2. If the result is needed before you can reply, call `TaskOutput` with `block: true` on the task
   id -- one call returns the output and the exit code.'
      ;;
    *)
      # shellcheck disable=SC2016 # `$pid` and backticks are literal repeat text
      fixes='Two fixes, in order of preference:

1. Do not poll. If this is a background task, its notification re-invokes you when it finishes --
   stop here, or call `TaskOutput` with `block: true` on the task id for the result now.
2. For any other process, probe a PID, not a pattern: `kill -0 "$pid"` on a PID recorded when it
   started (`$!`, a PID file), inside a loop with a `sleep`, not by hand.'
      ;;
  esac
  printf '%s\n\n%s\n\n%s\n' "${WRITE_TOOL_LEAD}" "${preamble}" "${fixes}"
}
