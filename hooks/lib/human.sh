# shellcheck shell=bash
#
# Human mode: --help and --version, sourced by hooks/pgrep-pkill-guard-body.sh
# once the entry script's prefilter has let a payload through. Never executed:
# no shebang, no exec bit, and it must not set `set -Eeuo pipefail`, `IFS`, or
# the ERR trap -- the entry script owns all three, and a sourced file that
# sets them reconfigures its caller. Never add `shopt -s inherit_errexit`
# (invariant 2). POSIX short flags, not GNU long options: this runs on BSD
# userland too (invariant 1).

# @description Print the human-facing help on stdout.
# @noargs
# @stdout the help text
function print_help() {
  # A quoted heredoc, so nothing in the body is expanded and the probe recipe can
  # carry `${CLAUDE_PLUGIN_ROOT}` and `$cmd` verbatim -- it is meant to be copied
  # into a shell, not resolved here. The version is printed by --version rather
  # than interpolated into this text, which is what keeps the heredoc inert.
  cat << 'EOF'
Usage: pgrep-pkill-guard.sh [-h | --help] [--version]

A Claude Code PreToolUse hook for the Bash tool. It reads the command an agent is
about to run and blocks the two shapes that cost a session: a pattern-matching
kill that also matches the agent's own `bash -c` process, and a pgrep poll loop
waiting on a process that can never exit. Claude Code runs this script; you
normally never invoke it yourself.

Input and output:
  Reads one PreToolUse hook JSON object on stdin and writes one JSON object on
  stdout. `{}` allows the command. A `hookSpecificOutput` carries either
  `permissionDecision: deny` with a `permissionDecisionReason` naming the match
  and the rewrites that avoid it, or an `additionalContext` warning about a shape
  that is risky but not certain. A `systemMessage` means the guard stood down for
  this command -- no jq, no awk, an awk that tokenizes differently, an unreadable
  body -- and said so rather than failing silently.

Options:
  -h, --help    Print this help on stdout and exit. Wins over every other
                argument: `--help --anything` still prints help.
      --version Print the program name and version on stdout and exit.

Asking the guard about one command:

  jq --null-input --arg cmd '<your command here>' \
    '{tool_name:"Bash",tool_input:{command:$cmd}}' \
    | "${CLAUDE_PLUGIN_ROOT}"/hooks/pgrep-pkill-guard.sh

  Paste that command and the JSON it prints into a false-verdict report. Quoting
  and whitespace matter: the guard tokenizes the string it is given.

Environment:
  PGREP_PKILL_GUARD_STATE_DIR
      Where the repeat rule keeps its per-session probe counters. Resolved in
      this order:
        1. $PGREP_PKILL_GUARD_STATE_DIR
        2. $XDG_RUNTIME_DIR/pgrep-pkill-guard
        3. $TMPDIR/pgrep-pkill-guard, else /tmp/pgrep-pkill-guard
      The directory is created mode 0700 and must be owned by the calling user
      and not be a symlink, or the repeat rule stands down. The files are
      throwaway; deleting them only resets probe counters.

Exit status:
  0   on every hook call. The guard fails open, so even an internal error allows
      the command rather than blocking it, and says so in a systemMessage.
  0   for --help and --version.
  2   for an unrecognized argument, or for a bare run with stdin on a terminal.

Home page and issue tracker:
  https://github.com/rvenutolo/claude-pgrep-pkill-guard
EOF
}

# @description The human-facing surface: --help, --version, and usage errors. Reached only from the
#              entry script's dispatch, which fires when the script was given arguments or when
#              stdin is a terminal -- neither of which Claude Code ever does.
#
#              This is the ONE path in the guard that deliberately returns non-zero, and the
#              caveat is worth stating where a maintainer will read it. A PreToolUse hook exiting
#              2 means "block the tool call". Arguments can only reach this script from a person,
#              because hooks/hooks.json passes none, so in practice the 2 lands in a terminal. If
#              someone hand-edited hooks/hooks.json to pass an argument, every Bash call would be
#              blocked with a loud stderr message rather than failing open -- the right outcome
#              for a broken configuration, but the one place here that does not fail open.
# @arg $@ args the script's arguments, forwarded verbatim
# @stdout the help text, or the version line
# @stderr one error line plus a `--help` hint, on a usage error
# @exitcode 0 --help or --version was handled
# @exitcode 2 an unrecognized argument, or a bare run with stdin on a terminal
function human_mode() {
  # --help wins over everything, including arguments this script does not know:
  # `--help --bogus` and `--bogus --help` both print help and succeed (clig.dev).
  # So scan ALL arguments for it before deciding anything else.
  local arg
  for arg in "$@"; do
    if [[ "${arg}" == '-h' || "${arg}" == '--help' ]]; then
      print_help
      return 0
    fi
  done

  # Only as the lone argument. `--version --anything` is a usage error, not a
  # request to print the version and silently drop the rest.
  if (($# == 1)) && [[ "$1" == '--version' ]]; then
    # GNU style: program name, then version, one line, no trailing prose. It is
    # what a bug report gets pasted into, so nothing else belongs on it.
    printf '%s %s\n' "${HOOK_NAME}" "${HOOK_VERSION}"
    return 0
  fi

  # No arguments means the dispatch fired on `[[ -t 0 ]]`: somebody ran the hook
  # by hand, and the read further up would otherwise block on an EOF a terminal
  # never sends until they find Ctrl-D. Say what the script wants instead of
  # hanging (clig.dev).
  if (($# == 0)); then
    printf '%s: reads a PreToolUse hook JSON object on stdin, and stdin is a terminal.\n' \
      "${HOOK_NAME}" >&2
    printf "try '%s.sh --help' for the input contract and a ready-made probe recipe.\n" \
      "${HOOK_NAME}" >&2
    return 2
  fi

  # Name the argument that actually broke. With `--version --bogus` the offending
  # word is the second one, and an error naming the first sends the reader
  # looking in the wrong place.
  local offender="$1"
  for arg in "$@"; do
    if [[ "${arg}" != '--version' ]]; then
      offender="${arg}"
      break
    fi
  done
  printf '%s: unrecognized option: %s\n' "${HOOK_NAME}" "${offender}" >&2
  printf "try '%s.sh --help'\n" "${HOOK_NAME}" >&2
  return 2
}
