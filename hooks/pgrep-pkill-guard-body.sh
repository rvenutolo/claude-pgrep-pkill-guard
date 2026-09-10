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

# Resolved by resolve_scanner in lib/scanner.sh, which inspect_command calls
# once, and read from there and from lib/classify.sh. Declared here so `set -u`
# has a definition to see on any path that never resolves it.
# shellcheck disable=SC2034 # set by lib/scanner.sh, read there and in lib/classify.sh
SCANNER=''

# The parts, in load order. An explicit list rather than a glob: a glob's order
# depends on the locale, a stray file dropped into lib/ would be sourced
# unasked, and the fail-open message below needs a name to print. Order does
# not affect correctness -- every part only defines functions and readonly
# constants, and nothing runs until inspect_command or human_mode is called --
# so it is arranged for a reader: low-level helpers first.
readonly -a GUARD_PARTS=(
  'tokens.sh'
  'scanner.sh'
  'loops.sh'
  'messages.sh'
  'consumption.sh'
  'wrappers.sh'
  'repeat.sh'
  'classify.sh'
  'human.sh'
)

# HOOK_DIR and HOOK_NAME are the entry script's: this file runs in its shell.
for guard_part in "${GUARD_PARTS[@]}"; do
  # The `||` is load-bearing beyond the obvious fallback, exactly as it is on
  # the entry script's source of this file: it keeps a failing `source` off
  # the ERR trap, so a missing or corrupt part produces this message rather
  # than the trap's bare `{}`. `exit 0`, not `return 1`: the entry script's
  # own `|| { ... }` around its source of this file would otherwise print a
  # second JSON line, and an exit from a sourced file is what the ERR trap
  # itself does. Fail open, loudly -- the same INACTIVE wording as every other
  # precondition in the guard.
  # shellcheck source=/dev/null # each part is linted on its own as hooks/lib/*.sh
  source "${HOOK_DIR}/lib/${guard_part}" || {
    printf '{"systemMessage":"%s"}\n' \
      "${HOOK_NAME}: lib/${guard_part} is missing or failed to load; the pgrep/pkill guard is INACTIVE for this command."
    exit 0
  }
done
unset guard_part
