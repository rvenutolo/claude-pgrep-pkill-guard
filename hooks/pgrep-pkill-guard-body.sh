# shellcheck shell=bash
#
# The pgrep/pkill guard's body: everything an ordinary Bash tool call never
# reaches. hooks/pgrep-pkill-guard.sh sources this file from `main`, AFTER the
# prefilter has decided the payload is worth looking at, and then calls
# inspect_command. This file is now only the loader -- it declares the two
# globals the parts share and sources the parts themselves.
#
# The split exists for one reason: bash parses ~1.2 us per line before it runs
# any of them (#55), and at 2200-odd lines that was 2.4 ms on every Bash call
# in every session, four fifths of what the guard cost. Keeping this file out of
# the fast path is the whole point -- do not move anything here into the entry
# script, and see invariant 5 in docs/architecture.md for the ceiling that
# enforces it. The logic itself lives in hooks/lib/, one file per concern,
# sourced from the list below.
#
# This file is SOURCED, never executed: no shebang, not executable, and it must
# not set `set -Eeuo pipefail`, `IFS`, or the ERR trap. The entry script owns
# all four, and re-setting them here would change the caller's shell. Invariant
# 2 applies unchanged: never add `shopt -s inherit_errexit`. Invariant 1 applies
# unchanged too -- POSIX short flags, deliberately, not GNU long options, here
# and in every part under lib/.

# The version `--version` reports. A literal rather than a runtime read of
# .claude-plugin/plugin.json: that would need path resolution up out of hooks/, a
# `jq` spawn, and its own fail-open story for a missing or unparsable manifest --
# all to print a string that is fixed at release time.
#
# The `x-release-please-version` annotation must stay ON THIS LINE. The generic
# updater rewrites the semver on an annotated line; the preceding-line form is
# the `x-release-please-start-version` / `-end` block syntax, which this is not.
# .ci/check-versions-in-sync asserts this equals .claude-plugin/plugin.json's
# .version, with no BOOTSTRAP_VERSION escape hatch -- that exemption is scoped to
# .release-please-manifest.json, because a WRONG version in a bug report is worse
# than a missing one.
# shellcheck disable=SC2034 # read inline by human_mode in lib/human.sh, sourced below
readonly HOOK_VERSION='1.1.0' # x-release-please-version

# Resolved by scanner::resolve_scanner in lib/scanner.sh, which inspect_command calls
# once, and read from there and from lib/classify.sh. Declared here so `set -u`
# has a definition to see on any path that never resolves it.
# shellcheck disable=SC2034 # set by lib/scanner.sh, read there and in lib/classify.sh
SCANNER=''

# The parts, in load order, each paired with one function it must define. An
# explicit list rather than a glob: a glob's order depends on the locale, a
# stray file dropped into lib/ would be sourced unasked, and the fail-open
# message below needs a name to print. Order does not affect correctness --
# every part only defines functions and readonly constants, and nothing runs
# until inspect_command or human_mode is called -- so it is arranged for a
# reader: low-level helpers first.
#
# The paired function is how the loop below tells a part that loaded from one
# that did not. `source` yields the status of the sourced file's LAST top-level
# command, so its status alone cannot: a part that ended in a `[[ ... ]]` or a
# `grep` returning non-zero would look exactly like a missing one and stand the
# guard down on every call (#147). A function that was defined is the proof
# that the file was found, parsed to the end, and ran.
readonly -a GUARD_PARTS=(
  'tokens.sh:tokens::is_keyword'
  'scanner.sh:scanner::resolve_scanner'
  'loops.sh:loops::loop_context'
  'messages.sh:messages::emit_deny'
  'consumption.sh:consumption::result_is_consumed'
  'wrappers.sh:wrappers::shell_wrapper_payloads'
  'repeat.sh:repeat::repeat_check'
  'classify.sh:inspect_command'
  'human.sh:human_mode'
)

# HOOK_DIR and HOOK_NAME are the entry script's: this file runs in its shell.
for guard_part in "${GUARD_PARTS[@]}"; do
  # The `||` is load-bearing beyond the obvious fallback, exactly as it is on
  # the entry script's source of this file: it keeps a failing `source` off
  # the ERR trap, so a missing or corrupt part reaches the check below rather
  # than the trap's bare `{}`. The status itself is discarded on purpose -- see
  # the list above for why it cannot be trusted -- and `declare -F` is the
  # verdict. Both are builtins: no fork on the path that already paid for jq.
  # `exit 0`, not `return 1`: the entry script's own `|| { ... }` around its
  # source of this file would otherwise print a second JSON line, and an exit
  # from a sourced file is what the ERR trap itself does. Fail open, loudly --
  # the same INACTIVE wording as every other precondition in the guard.
  # shellcheck source=/dev/null # each part is linted on its own as hooks/lib/*.sh
  source "${HOOK_DIR}/lib/${guard_part%%:*}" || : # source yields the part's last command status, not load success
  declare -F "${guard_part#*:}" > /dev/null || {
    # Two messages, because the two causes send a reader to different places
    # and the file's own readability is the only thing that separates them.
    # An unreadable part is an install problem. A part that IS there but did
    # not define its paired name is either a parse error inside it or a
    # GUARD_PARTS row naming a function that no longer exists -- the rename
    # hazard .ci/check-guard-parts exists to catch at lint time. The old
    # single message said "missing or failed to load" for both, which for a
    # stale row is simply false: the file loaded perfectly well.
    #
    # `source`'s own status cannot tell them apart -- it yields the status of
    # the part's LAST top-level command, which is the whole reason this loop
    # judges by `declare -F` (#147) -- so readability is the test.
    if [[ -r "${HOOK_DIR}/lib/${guard_part%%:*}" ]]; then
      printf '{"systemMessage":"%s"}\n' \
        "${HOOK_NAME}: lib/${guard_part%%:*} did not define ${guard_part#*:}; it either failed to parse or its GUARD_PARTS row names the wrong function. The pgrep/pkill guard is INACTIVE for this command."
    else
      printf '{"systemMessage":"%s"}\n' \
        "${HOOK_NAME}: lib/${guard_part%%:*} is missing or unreadable; the pgrep/pkill guard is INACTIVE for this command."
    fi
    exit 0
  }
done
unset guard_part
