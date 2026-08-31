# Architecture

This document is for contributors. It traces the path a command takes through
the guard and records the decisions that the code cannot explain on its own —
in particular three invariants defined by absence, where a reasonable-looking
cleanup breaks the plugin on half the platforms it supports. The user-facing
documentation is [the README](../README.md); nothing here is needed to install
or use the plugin.

## Codemap

### `hooks/hooks.json`

Registers exactly one hook: a `PreToolUse` entry with the matcher `Bash` and a
5 s timeout. That is the plugin's entire surface — no other event, no other
tool. The timeout is generous on purpose: the hook is bash and awk with no
network, so anything slower is a bug, and letting the call proceed is the right
failure mode.

### `hooks/pgrep-pkill-guard.sh`

The entry script, and the only file `hooks/hooks.json` names. It holds the work
an ordinary Bash tool call has to pay for, and nothing else. Bash parses a whole
script before it executes a line of it, at roughly 1.2 us per line, and this
hook runs on every Bash call in every session — so the file's length is a
latency tax paid even by the commands the guard has no opinion about. At 2203
lines that was ~2.4 ms of pure parse per call, four fifths of what the guard
cost, almost all of it spent on code the call would never reach. Everything past
the prefilter therefore lives in the sibling below (#55), and invariant 5 is the
ceiling that keeps it there.

In execution order:

1. `export LC_ALL=C`, before anything else. The scanner emits **byte** offsets
   and the guard slices the raw command back out with
   `${command:offset:length}`. Bash string operations are locale-aware, so under
   a UTF-8 locale a single multibyte character earlier in the command shifts
   every later slice and silently voids the bracket mitigation. Exported rather
   than merely set, so it also covers the sourced body and the awk that body
   spawns.
2. `readonly HOOK_NAME`, which sits this high only because the version guard
   below names it. Every other constant is in the body.
3. The bash-version guard: bash older than 4.3 prints the INACTIVE
   `systemMessage` and exits immediately. It runs before everything else
   because it is the one guard that has to: the rest of the guard leans on
   4.3+ features, so nothing after this point is safe to run on an older
   shell. It is also the only loud failure that fires ahead of the prefilter.
4. `trap 'emit_allow; exit 0' ERR`. A hook that dies non-zero surfaces an error
   on every Bash call, and exit 2 would block the tool outright. The trap is
   installed once, here; the body is sourced into this same shell and inherits
   it rather than setting one of its own (invariant 2).
5. `main` reads the hook JSON from stdin into `input` with the `read` builtin —
   `IFS= read -r -d '' input || :` — rather than the `input="$(cat)"` it used
   to, which was a fork and an exec on every Bash tool call before the guard
   had looked at anything. The empty delimiter reads to EOF, so `read` returns
   1 having stored the whole payload; the `|| :` is what makes that normal case
   a success rather than an `ERR` trip. Two differences from `$(cat)`, both
   inert: a trailing newline now survives, which neither the prefilter's
   substring test nor `jq` cares about, and a raw NUL would truncate the
   payload — which Claude Code's payloads, serialized by Node's
   `JSON.stringify`, cannot contain.
6. The prefilter: `input` is tested for the raw substrings `pgrep`, `kill` and
   `.output`, and a payload carrying none of them returns `{}` immediately,
   before `jq` or the awk scanner ever spawn — and, since everything downstream
   is in the sibling, having parsed and executed nothing beyond this file. See
   invariant 4 below for why a raw-payload substring test cannot suppress a
   verdict the rest of the guard would otherwise reach.
7. Past the prefilter, `resolve_hook_dir` freezes `HOOK_DIR`: one `dirname`
   fork and exec, which locates both the sibling and — through the sibling's
   `resolve_scanner` — the awk scanner, so no path pays a second process for
   the second lookup. Two branches then stand down loudly, exactly as the
   precondition guards inside the body do: the sibling missing or unreadable,
   and the `source` itself failing. The `||` on that `source` is what keeps a
   corrupt sibling off the `ERR` trap, which would otherwise answer a broken
   install with a bare `{}`. With the body loaded, `main` calls
   `inspect_command "${input}"`.

### `hooks/pgrep-pkill-guard-body.sh`

The rest of the guard: every constant except `HOOK_NAME`, every function except
`emit_allow`, `resolve_hook_dir` and `main`, and `inspect_command`, which is
what used to be the second half of `main`. A call the prefilter short-circuits
never parses a line of it, which is the entire reason the file exists.

It is **sourced, never executed** — no shebang, no exec bit — and it sets no
`set -Eeuo pipefail`, no `IFS` and no `ERR` trap, because it runs in the entry
script's shell and would be reconfiguring its caller rather than itself
(invariant 2).

Picking up where step 7 above left off, `inspect_command`:

1. `resolve_scanner`, then the precondition guards, each of which stands down
   loudly: `jq` missing from `PATH`, `awk` missing from `PATH`, the scanner file
   unreadable. These run only once the prefilter has let a payload through,
   since a payload the prefilter would have returned `{}` for was never going to
   reach `jq` or the scanner either way. `resolve_scanner` costs no process of
   its own: it reads the `HOOK_DIR` the entry script resolved before sourcing
   this file, and declares the global `readonly` once it sets it, so the path is
   frozen for the rest of the call.
2. Extract `tool_name`, `tool_input.command` and `session_id` in a **single**
   `jq ... | @tsv` call — one jq spawn, since this runs on every payload that
   survives the prefilter. `@tsv` escapes literal tabs and newlines in the
   command, which `printf '%b'` then decodes in one left-to-right pass. A
   `tool_name` other than `Bash` allows immediately.
3. `classify_command` runs the stateless tiers and prints a verdict plus a tab
   and the detail its message needs (the invoked tool, or the polled path).
   `inspect_command` owns stdout; the classifier hands the verdict up rather
   than writing the decision itself.
4. The stateful `repeat` tier, which runs only after the stateless tiers have
   allowed or warned.
5. Emission. `emit_allow` — which lives in the entry script, because the
   prefilter needs it there — prints a bare `{}`; `emit_warn` prints an `allow`
   decision carrying `additionalContext`; `emit_deny` prints a `deny`
   decision carrying `permissionDecisionReason`, built by `deny_message` from
   the kind and its detail. `additionalContext` is the only `PreToolUse`
   field verified to reach the model on an allowed call — `systemMessage`
   renders to the user only, and `permissionDecisionReason` is fed back under
   deny alone.

### `hooks/pgrep-scan.awk`

Called from `scan_command` as `printf '%s\n' "${command}" | LC_ALL=C awk -f`.
In one linear pass it masks the regions that are text rather than code — single
and double quoted strings, comments, heredoc bodies — while letting a command
substitution re-enter code context even inside double quotes, which is what
makes `until [ -z "$(pgrep --full x)" ]` visible. It then emits one
`<byte offset>\t<token>` record per token, with `<NL>` for a newline and a
`<HD:len>` marker at the first byte of each heredoc body.

The last line is the **integrity trailer**, `\t<SCAN:n>`, where `n` is the byte
count of the command the scanner reassembled. `scan_command` requires that to
equal `${#command}` before it trusts a single offset, and strips the trailer
before returning the stream. The check catches any awk that strips, splits or
reshapes bytes on the way through and would otherwise desync every offset while
still producing plausible output. It is in-band rather than an `exit 1` because
the hook calls the scanner inside a command substitution, where a non-zero exit
is swallowed by the `ERR` trap and turns into a silent allow. The scanner
depends on nothing awk-specific: it reads with `getline` under the default `RS`
so gawk, mawk and one-true-awk all behave identically, and the caller
terminates its input with exactly one newline because POSIX awk cannot
otherwise tell `foo` from `foo\n` at end of input.

### Verdict kinds

`classify_command` prints one of:

| Verdict | Meaning |
| --- | --- |
| `deny:kill` | a pattern kill whose pattern matches the invoking shell |
| `deny:loop` | a loop whose termination test is a full-command-line pattern search |
| `deny:task-poll` | a loop whose termination test reads a harness task-output file |
| `warn` | a `pgrep --full` whose result is consumed but which is neither a loop nor a kill |
| `allow` | everything else |
| `inactive` | the scanner failed its integrity trailer; `inspect_command` emits the INACTIVE `systemMessage` |

`repeat` is the fifth deny kind and is not one of these: it is decided after
classification, in `inspect_command`, because it is the only stateful rule.

### The per-session state file

`repeat` — and only `repeat` — touches the filesystem. `repeat_check` resolves
the state directory as `${PGREP_PKILL_GUARD_STATE_DIR}`, else
`${XDG_RUNTIME_DIR}/pgrep-pkill-guard`, else `${TMPDIR}/pgrep-pkill-guard`,
else `/tmp/pgrep-pkill-guard`, and keeps one file per session named for the
`session_id` (validated as a plain file name first, so no id means no rule and
never a shared fallback). The file holds `<epoch>\t<key>` lines; entries older
than the 300 s window are pruned on every write, the threshold is 3 probes per
key per window, and the rewrite goes through `mktemp` plus `mv` rather than a
predictable `${file}.$$` name. The directory and the file must both be owned by
the caller and not symlinks. Every one of those checks `return 0` — see below.

### `tests/cases/`

Two tab-separated tables drive most of the suite, both with shell-visible
strings stored as JSON so quoting and whitespace survive:

- `verdicts.tsv` — `<command>\t<verdict>`, read by `tests/classify.bats` (which
  asserts the decision plus the mitigation needle that identifies the kind),
  by `tests/deny-sweep.bats`, and by `tests/prefilter.bats`, which asserts that
  every non-`allow` row carries one of the prefilter's trigger tokens and that
  the three-token set is minimal (dropping any one leaves some row uncovered).
- `messages.tsv` — `<command>\t<field>\t<mode>\t<needle>`, read by
  `tests/messages.bats`, where `field` is `reason`, `context` or `decision` and
  `mode` is `contains`, `lacks` or `equals`. `lacks` asserts absence, which is
  how the tables pin that a `loop` deny does *not* offer `--ignore-ancestors`.

Of the remaining bats files, the ones that exercise the guard cover the parts
no table can express: `tests/scanner.bats` (the awk scanner directly),
`tests/repeat.bats` (the stateful tier and its state-directory failure modes)
and `tests/manifest.bats`. `tests/issue-forms.bats` is unrelated to the guard
entirely — it drives `.ci/check-issue-forms` against fixture issue templates,
not anything in `hooks/`.

## Fail open, loudly

One rule explains most of the code. **Every precondition failure and every
state failure allows the command**, and the ones a user could act on emit a
`systemMessage` saying the guard is INACTIVE for that command.

The loud path covers bash below 4.3, a missing or unloadable
`hooks/pgrep-pkill-guard-body.sh`, a missing `jq` or `awk`, an unreadable
scanner, and an awk that fails the integrity trailer. The two sibling branches
are the split's own contribution to the list: an entry script that could not
find or load its body would otherwise be an installed plugin that quietly does
nothing.

The bash-version guard is the only one of those that runs before the payload
prefilter. Every other loud warning fires only for commands that carry a
trigger token. A command mentioning neither `pgrep`, nor `kill`, nor a
task-output file returns `{}` whether or not `jq` is installed, so warning
about an inactive guard on that call describes a decision the guard was never
going to make. The user still learns they are unprotected the first
time they type something the guard would have looked at, which is the moment
the warning is worth anything.

The silent path covers
the `repeat` rule's state: no directory, unreadable, not a regular file, not
owned by the caller, a symlinked directory, an oversized file — each returns
quietly and the command proceeds, because the state is a heuristic and is never
allowed to become a way to fail closed.

A hook that blocked on its own breakage would be worse than no hook: it would
turn an installed plugin into an outage on every Bash call. A hook that went
quiet on its own breakage would be worse still, because the user would never
learn they were unprotected. That trade-off is why the `ERR` trap allows, why
the scanner's integrity check is in-band, and why `repeat_check` is written as
a long sequence of `|| return 0` guards rather than as assertions.

## Known limitations

Behaviour the guard does not have, recorded deliberately rather than left to be
rediscovered. Each entry is pinned by rows in `tests/cases/verdicts.tsv`, so the
limitation is a tested decision rather than an accident, and closing one means
changing a recorded verdict on purpose.

### Quote-split command names are not recognised

The scanner compares a command-name token against the literal strings `pgrep`,
`pkill` and `kill`. It does not unquote, so any shell quoting that survives into
the token makes the comparison fail and the command is allowed. Every form below
is a valid invocation of `pkill`, and `zzznoproc` matches no process, so the
rows that pin them can be run without killing anything:

| command | verdict |
| --- | --- |
| `pkill --full zzznoproc` | `deny:kill` |
| `"pkill" --full zzznoproc` | `allow` |
| `$'pkill' --full zzznoproc` | `allow` |
| `p'k'ill --full zzznoproc` | `allow` |
| `'pk''ill' --full zzznoproc` | `allow` |
| `pk\ill --full zzznoproc` | `allow` |
| `PATH=/bin p\kill --full zzznoproc` | `allow` |

This is intended, on the threat model. The guard exists for an agent that does
not realise a pattern-kill will match the session running it — not for an
adversary trying to slip a kill past it. None of these forms is something a
model writes by accident; each is deliberate obfuscation, and anyone typing
`pk\ill` has already decided to bypass the guard, which they could do more
easily by disabling the plugin.

It is not free to close. The prefilter's soundness argument in invariant 4
depends on this exact property: every token the scanner recognises is a literal
substring of the raw payload. A scanner that unquoted could recognise `pk\ill`
in a payload containing no `kill` substring, so teaching it to unquote means
revisiting the prefilter's token set in the same change.
`tests/prefilter.bats` is what would catch that being forgotten.

Filed as #52.

## Design invariants

Five rules the code depends on and cannot enforce. Each is repeated as a
comment in the source it constrains; if one changes here, change the comment
too.

### 1. `hooks/` uses POSIX short flags, not GNU long options

The rest of the repo uses GNU long options (`mkdir --parents`, `rm --force`).
`hooks/` is exempt and must use POSIX short flags — `mkdir -p -m 0700`,
`rm -f`, `mv -f`. The exemption covers both halves of the split guard: the entry
script and the body it sources ship to the same machines and run in the same
shell.

**Why:** the hook runs on whatever userland the user's machine ships. macOS
ships BSD coreutils, whose `mkdir` has no long options at all — no `--parents`,
no `--mode=` — and whose `rm` has no `--force`. A long option there is not a
style preference; it is a runtime failure on half the supported platforms.
Everything else in the repo — `.ci/`, `run-all-checks`, `run-tests`,
`.githooks/`, `.justfile`, the workflows — keeps long options, because those run
only inside the hermetic Nix devShell where GNU coreutils is guaranteed.

**Tracked comments:** the two `POSIX short flags, deliberately` comments in
`hooks/pgrep-pkill-guard-body.sh`, in `repeat_check` and in its write path:

```text
# POSIX short flags, deliberately: macOS ships BSD coreutils, whose mkdir has
# no long options at all (no `parents`, no `mode=`). hooks/ is the one
# directory in this repo exempt from the repo-wide long-options rule, for
# exactly that reason -- the guard has to run on whatever userland ships.
```

and a third in `resolve_hook_dir` in `hooks/pgrep-pkill-guard.sh`, which is the
entry script's one and only external command:

```text
# Resolved relative to this script rather than via CLAUDE_CONFIG_DIR, which is
# not guaranteed to be exported into the hook's environment. POSIX short flags,
# deliberately: macOS ships BSD userland, whose `dirname` has no long options.
```

**Same cause, different scope:** `tests/*.bats` and `tests/test_helper/` carry
the same exemption. The three ambient compat CI legs — `compat (ubuntu,
ambient)`, `compat (macos, homebrew bash)` and `compat (macos, stock bash 3.2)`
— run against the tools the runner ships rather than against the devShell, and
the first two of those run the bats suite. A `--parents` in a `.bats` file
passes locally in the devShell and reddens a macOS job. `run-tests` itself keeps
long options: it is the gate entrypoint and runs under the devShell bash. The
tracked counterpart is the `POSIX short flags on purpose` comment above
`make_manifest_fixture` in `tests/manifest.bats`.

### 2. `hooks/` never sets `shopt -s inherit_errexit`

Every gate script in the repo sets it. Neither of the hook's two files may, and
no one may turn the assignment below into a plain one.

```bash
repeat_reason="$(repeat_check "${session_id}" "${keys}")" || repeat_reason=''
```

**Why:** the trailing `||` is what keeps that entire command substitution off
errexit's radar for its whole dynamic extent, so nothing inside `repeat_check`
— the guard's one stateful, filesystem-touching rule — can trip the top-level
`ERR` trap. `inherit_errexit` pushes errexit back inside the substitution and
reintroduces exactly the failure path the guard exists to avoid: a transient
filesystem condition becoming a trapped error on an unrelated command. The
`||` is load-bearing well beyond its visible role as a fallback, and the
fallback is also why `inspect_command` accepts the result as a deny only when it
is shaped like `repeat_message`'s output.

**And the body sets none of the four.** `hooks/pgrep-pkill-guard-body.sh` is
sourced into the entry script's shell rather than run in one of its own, so on
top of `inherit_errexit` it must never set `set -Eeuo pipefail`, `IFS`, or the
`ERR` trap either. The entry script owns all four and they are already in force
by the time the `source` runs; a sourced file that sets them is not configuring
itself, it is reconfiguring its caller. That is also why the body carries no
shebang and no executable bit — it is not a script that can be run.

**Tracked comment:** `The || is load-bearing beyond the obvious fallback`, which
now appears twice. In `hooks/pgrep-pkill-guard-body.sh`, in `inspect_command`
directly above that assignment:

```text
# The `||` is load-bearing beyond the obvious fallback: it is what
# keeps this whole command substitution off errexit's radar for its
# entire dynamic extent, so nothing inside repeat_check can trip the
# top-level ERR trap. Do not turn this into a plain assignment.
```

And in `hooks/pgrep-pkill-guard.sh`, above the `source` of the body, where the
same construct does the same job for a corrupt sibling:

```text
# The `||` is load-bearing beyond the obvious fallback, exactly as it is on the
# repeat_check call inside the body: it keeps a failing `source` off the ERR
# trap, so a corrupt sibling produces this message rather than a bare `{}`.
```

### 3. No test sources the hook or calls an internal function

Tests drive the hook **only as a subprocess with hook JSON on stdin**, and
assert on the JSON it writes to stdout. `tests/test_helper/common.bash` is the
whole interface: `hook_json`, `run_hook`, then `decision_of`, `reason_of` and
`context_of` over the response. No `source`, no calling `classify_command` or
any other internal directly.

**Why:** the JSON contract is the only thing Claude Code actually depends on. A
test that reaches inside pins an implementation detail and blocks refactoring —
and the roughly 1450 lines of embedded self-test that this suite replaced did
exactly that.

`hooks/pgrep-pkill-guard-body.sh` is not a loophole in this. It exists to be
sourced, but that is the entry script's business alone — no test may source it
either. The two tests that cover the split, in `tests/scanner.bats`, copy the
entry script into a temporary directory and run it there with no sibling beside
it, and then with a deliberately broken one; both assert on the INACTIVE JSON
the subprocess writes, and neither sources anything.

**The one exception** is `hooks/pgrep-scan.awk`, which has its own public
interface: a command on stdin, offset/token records and an integrity trailer on
stdout. `tests/scanner.bats` may drive it directly with `awk -f`, always under
`LC_ALL=C`, because that is precisely how the hook itself calls it.

### 4. The prefilter's token set is `pgrep`, `kill`, `.output` — and is a proof

`main` returns `{}` without spawning `jq` or `awk` when the raw hook payload
contains none of those three substrings. The proof is containment, not
enumeration. `classify_command` itself opens with an early `allow` unless the
COMMAND contains `pgrep`, `pkill`, or `.output`, and every stateless `deny`,
`warn`, or `inactive` verdict has to pass through that gate on its way out.
`inspect_command` separately restricts the stateful repeat tier to commands
containing `pgrep` or `.output`, so no verdict can arise from the per-session
state file alone either. The guard, in other words, already prefilters on the parsed
command before this prefilter ever runs. The new check applies the identical
predicate to the raw payload, with `pkill` widened to `kill`. Since `pkill` is
a substring of `kill`, and the command is itself a substring of the payload it
was extracted from, this prefilter is provably weaker than a gate the hook
already applies — it cannot suppress a verdict the hook would otherwise
reach.

**Why the test states the list instead of reading it.**
`tests/prefilter.bats` hardcodes the same three tokens. That duplication is the
point: a test that extracted the list from the hook would agree with it by
construction and assert nothing. Instead two independent assertions close the
loop — `tests/prefilter.bats` pins corpus against specification, and the 311
rows of `tests/classify.bats` pin the hook against the corpus. Neither reaches
inside the hook, so invariant 3 still holds.

**The assumptions it rests on.** The proof needs every token the scanner
recognises to be a literal substring of the payload. That is true only because
the scanner does not unquote — see **Quote-split command names are not
recognised** above for the seven forms this allows and why that is intended. If
that limitation is ever closed by teaching the scanner to unquote, this token
set must be revisited in the same change — an unquoting scanner could
recognise `pk\ill` in a payload containing no `kill` substring.
`tests/prefilter.bats` is what catches it.

A second assumption sits alongside the first: the prefilter matches raw
payload bytes, so it also assumes the payload spells the command's characters
out literally. A serializer that `\u`-escaped ASCII letters could hide a
trigger token from it — a payload spelling `pgrep` as `\u0070grep` would
return `{}` where the pre-change hook still denied. This is not reachable in
practice: Claude Code's payloads come from Node's `JSON.stringify`, which
never escapes ASCII letters, and reaching it would additionally require the
model to obfuscate its own command. It is recorded here because it is an
assumption the prefilter makes, not because it is a live risk.

**Why not Claude Code's own `if:` handler filter.** Because it matches a
parsed command tree. Measured against this corpus, an `if:` of `Bash(pgrep *)`
plus `Bash(pkill *)` misses 39 of 180 non-`allow` rows: `sudo` is not in
Claude Code's stripped-wrapper list, `bash -c '…'` is not descended into, and
the `deny:task-poll` shapes contain no matchable command name at all. A
substring test over the raw payload sees all three. See issue #29 for the
probe matrix.

Tracked counterpart: the prefilter comment block in `main`.

### 5. The entry script stays under 200 lines

`hooks/pgrep-pkill-guard.sh` must stay under 200 lines.
`.ci/check-fast-path-size` enforces it, and `run-all-checks` runs that gate
with the rest.

**Why:** bash parses a whole script before it executes any of it, at roughly
1.2 us per line, and this hook runs on every Bash tool call in every session —
including the overwhelming majority the guard has no opinion about. Measured
with `bash -n` over valid prefixes of the pre-split 2203-line guard (400 reps,
`env -u BASH_ENV`): 4426 us for an empty script, 4559 at 120 lines, 5096 at
300, 5807 at 1100, and 7099 at 2203. That last figure is ~2.4 ms of pure parse
on every call, four fifths of what the guard cost, and it is why #55 split the
file in two.

**The ceiling is the point, not an obstacle to it.** A new helper belongs in
`hooks/pgrep-pkill-guard-body.sh`, which the fast path never parses; raising the
number spends those milliseconds again, a few dozen microseconds at a time. The
win is invisible to every other check in this repo, so without the gate it would
regress one helper at a time and nobody would notice. The gate also fails on a
zero-line count: an empty read is a broken measurement, not a very fast hook.

**Tracked comments:** the header of `.ci/check-fast-path-size`, which carries
the measurement above, and the header of `hooks/pgrep-pkill-guard-body.sh`,
which points back to this invariant.
