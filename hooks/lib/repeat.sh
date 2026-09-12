# shellcheck shell=bash
#
# The stateful repeat tier: per-session probe counting, sourced by
# hooks/pgrep-pkill-guard-body.sh once the entry script's prefilter has let a
# payload through. Never executed: no shebang, no exec bit, and it must not
# set `set -Eeuo pipefail`, `IFS`, or the ERR trap -- the entry script owns
# all three, and a sourced file that sets them reconfigures its caller. Never
# add `shopt -s inherit_errexit` (invariant 2). POSIX short flags, not GNU
# long options: this runs on BSD userland too (invariant 1).

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

# @description The per-session repeat rule. State is one file per session,
#              `<dir>/<session_id>`, of `<epoch>\t<key>` lines, where <dir> is
#              PGREP_PKILL_GUARD_STATE_DIR, else $XDG_RUNTIME_DIR/pgrep-pkill-guard, else the same
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
function repeat::repeat_check() {
  local -r session_id="$1" keys="$2"
  local -r dir="${PGREP_PKILL_GUARD_STATE_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/pgrep-pkill-guard}"
  local -r file="${dir}/${session_id}"
  local now
  # POSIX short flags, deliberately: macOS ships BSD coreutils, whose mkdir has
  # no long options at all (no `parents`, no `mode=`). hooks/ is the one
  # directory in this repo exempt from the repo-wide long-options rule, for
  # exactly that reason -- the guard has to run on whatever userland ships.
  # shellcheck disable=SC2174 # -m only binds the deepest dir; the only
  # intermediate ever missing here is a hand-set PGREP_PKILL_GUARD_STATE_DIR /
  # TMPDIR, which the caller owns the mode of.
  if ! mkdir -p -m 0700 "${dir}" 2> /dev/null; then
    return 0
  fi
  # `mkdir -p` on a dir that already exists changes neither its owner nor its
  # mode, so under the /tmp fallback another local user who pre-creates this
  # directory (or replaces it with a symlink to one they control) would
  # otherwise be trusted just as much as one we created ourselves.
  [[ -O "${dir}" && ! -L "${dir}" ]] || return 0
  if ! printf -v now '%(%s)T' -1 2> /dev/null; then
    return 0
  fi
  if [[ -e "${file}" && ! -f "${file}" ]]; then
    return 0
  fi
  # Same reasoning as the dir check above, one level down: a pre-planted file
  # we don't own is not state we can trust to prune, count, or overwrite.
  if [[ -f "${file}" && ! -O "${file}" ]]; then
    return 0
  fi

  local kept='' epoch key content
  if [[ -f "${file}" ]]; then
    if [[ ! -r "${file}" ]]; then
      return 0
    fi
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
    if ! content="$(cat "${file}" 2> /dev/null)"; then
      return 0
    fi
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
      messages::repeat_message "${probe_key}" "$((count + 1))" "${ages%, }"
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
