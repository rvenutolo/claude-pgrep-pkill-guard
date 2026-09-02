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
readonly HOOK_NAME='pgrep-pkill-guard'

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

# Resolved lazily by resolve_hook_dir, which main calls only once the prefilter
# has let a payload through: it locates both the sourced body and the awk
# scanner, and it costs a `dirname` fork and exec (~1.6 ms, #54) that an
# ordinary Bash call has no reason to pay.
#
# Declared here rather than only inside the function so `set -u` has a
# definition to see on any path that never resolves it.
HOOK_DIR=''

# @description Emit an allow decision.
# @noargs
function emit_allow() {
  printf '{}\n'
}

# @description Resolve the directory this script lives in and freeze it. Called once, from main,
#              after the prefilter. Both consumers -- the sourced body and, through it, the awk
#              scanner -- sit downstream of that short-circuit.
# @set HOOK_DIR the absolute, symlink-resolved directory holding this script
# @noargs
function resolve_hook_dir() {
  # Resolved relative to this script rather than via CLAUDE_CONFIG_DIR, which is not guaranteed
  # to be exported into the hook's environment. POSIX short flags, deliberately: macOS ships BSD
  # userland, whose `dirname` has no long options. The phrase is kept on one line on purpose --
  # docs/architecture.md tells a reader to grep for it, and .ci/check-invariant-markers checks it
  # is here (invariant 1).
  HOOK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  readonly HOOK_DIR
}

# @description Bring in the sourced body: the whole guard past the prefilter, and human_mode with
#              it. Two callers need it -- the human-mode dispatch and the JSON path -- so the
#              resolution and both fail-open branches live here, not twice over (invariant 5).
# @noargs
# @exitcode 0 the body is loaded and its functions are callable
# @exitcode 1 it was missing or would not load; the systemMessage saying so is already on stdout
function load_body() {
  resolve_hook_dir
  local -r body="${HOOK_DIR}/pgrep-pkill-guard-body.sh"

  # Fail open, loudly, the same way the jq/awk/scanner branches inside the body
  # do. A missing or broken sibling would otherwise leave an installed plugin
  # that silently does nothing -- the exact failure this hook exists to prevent.
  if [[ ! -r "${body}" ]]; then
    printf '{"systemMessage":"%s"}\n' \
      "${HOOK_NAME}: pgrep-pkill-guard-body.sh is missing; the pgrep/pkill guard is INACTIVE for this command."
    return 1
  fi
  # The `||` is load-bearing beyond the obvious fallback, exactly as it is on the
  # repeat_check call inside the body: it keeps a failing `source` off the ERR
  # trap, so a corrupt sibling produces this message rather than a bare `{}`.
  # shellcheck source=/dev/null # the sibling is linted on its own as hooks/*.sh; following it
  # from here would re-lint 2100 lines against a context it never sees in isolation.
  source "${body}" || {
    printf '{"systemMessage":"%s"}\n' \
      "${HOOK_NAME}: pgrep-pkill-guard-body.sh failed to load; the pgrep/pkill guard is INACTIVE for this command."
    return 1
  }
  # Explicit, because `source` yields the sourced file's last status and this
  # function's own is now a decision, not a value nobody reads.
  return 0
}

# @description Entry point.
# @noargs
function main() {
  # Human mode. Both tests are builtins, so the fast path pays no fork and
  # nothing measurable to ask them. Claude Code invokes the hook with no
  # arguments (hooks/hooks.json passes none) and with stdin on a pipe, so neither
  # can fire on a real hook call: what reaches human_mode came from a person.
  #
  # Sitting AFTER the bash-version guard is deliberate: on stock macOS bash 3.2
  # `--help` prints that guard's INACTIVE message instead of help. Fixing that
  # needs a third, bash-3.2-safe file in hooks/ -- a large structural price for a
  # message that already names that reader's exact problem. Known limitation.
  if (($# > 0)) || [[ -t 0 ]]; then
    load_body || return 0
    # `|| exit` rather than a bare call plus `return`: human_mode returns 2 on a
    # usage error (its own comment says why that is the one deliberate non-zero
    # exit here), and a plain non-zero command would trip the ERR trap above and
    # be rewritten into an allow. The `||` keeps human_mode off errexit's radar
    # for its whole dynamic extent, the same trick the body's repeat_check call
    # uses; the `exit` is what carries the status out to the shell.
    human_mode "$@" || exit "$?"
    return 0
  fi

  # A builtin read rather than `input="$(cat)"`, which is a fork and an exec on
  # every Bash tool call and measured ~2.4 ms of one (#54). The empty delimiter
  # reads to EOF, so `read` returns 1 having stored the whole payload -- that is
  # the normal case here, not a failure, which is what the `|| :` is for. `IFS=`
  # with an empty delimiter keeps the payload byte for byte: no word splitting,
  # no whitespace trimmed.
  #
  # Two differences from `$(cat)`, both inert. A trailing newline survives
  # rather than being stripped: the prefilter is a substring test and `jq`
  # accepts trailing whitespace. And a raw NUL byte would truncate the payload,
  # which Claude Code's payloads cannot contain -- Node's JSON.stringify escapes
  # it rather than emitting it raw, the same class of assumption invariant 4
  # already rests on.
  local input=''
  IFS= read -r -d '' input || :

  # The prefilter. Everything below this point costs a `jq` spawn and at least
  # one `awk` scanner pass, and on an ordinary Bash call both find nothing:
  # #32 measured 13.12 ms per call against a 1.55 ms spawn floor.
  #
  # This is sound because it is provably weaker than a gate the guard already
  # applies to the parsed command:
  #
  #   - classify_command opens with an early `allow` unless the command
  #     contains `pgrep`, `pkill`, or `.output` -- every stateless deny/warn/
  #     inactive verdict has to pass through that gate on its way out.
  #   - the repeat tier below is separately restricted to commands containing
  #     `pgrep` or `.output` (see the comment above the repeat_check call), so
  #     no verdict can arise from the state file alone either.
  #
  # `pkill` contains `kill`, which is why `pkill` is not in the pattern below
  # and must not be added, and the command is itself a substring of the
  # payload it was extracted from. So this raw-payload check is a strictly
  # weaker version of a gate the hook already runs on the parsed command --
  # it cannot hide a verdict the hook would otherwise reach.
  #
  # Testing the RAW PAYLOAD rather than the parsed command is the whole point.
  # A substring test does not care that `pkill` sits behind `sudo`, inside
  # `bash -c '...'`, or in a heredoc body -- the shapes that made Claude Code's
  # own `if:` handler filter unusable here (#29: 39 of 180 deny rows missed).
  #
  # The test is a superset, so it fails in the safe direction: a payload that
  # matches merely takes today's path at today's cost. A `cwd` or
  # `transcript_path` containing `kill` makes every call in that tree a false
  # positive, which is a performance non-event.
  #
  # The proof assumes the scanner never recognises a name that is not a literal
  # substring of the payload -- true because it does not unquote (#52). If that
  # ever changes, revisit this pattern in the same commit; tests/prefilter.bats
  # is what will catch the drift. It also assumes the payload spells the
  # command's characters out literally rather than escaping them -- true today
  # because Claude Code's payloads come from Node's JSON.stringify, which
  # never \u-escapes ASCII letters.
  #
  # Bash pattern matching, not `printf ... | grep`: a grep would spawn a process
  # and hand back a third of what this saves. `[[ ]]` glob matching is a builtin
  # and costs nothing measurable. In a glob `.` is an ordinary character, so
  # `*.output*` is the literal substring test it looks like.
  if [[ "${input}" != *pgrep* && "${input}" != *kill* && "${input}" != *.output* ]]; then
    emit_allow
    return 0
  fi

  # Past the short-circuit the guard is going to look at the command, so bring in
  # the machinery that does it. Everything below this point lives in the sibling
  # file, which is why an ordinary Bash call parses ~190 lines, not 2200 (#55).
  load_body || return 0

  inspect_command "${input}"
}

main "$@"
