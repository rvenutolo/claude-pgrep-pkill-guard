# Architecture

This document is for contributors. It traces the path a command takes through
the guard and records the decisions that the code cannot explain on its own —
in particular the six design invariants — three of them defined by absence,
where a reasonable-looking cleanup breaks the plugin on half the platforms it
supports. The user-facing
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
5. The human-mode dispatch, `main`'s first act: `if (($# > 0)) || [[ -t 0 ]]`,
   which loads the body and hands the arguments to `human_mode` — `--help`,
   `--version` and the usage errors, none of which live here, because fifty
   lines of help text on the fast path is fifty lines of parse on every call
   that will never read them. Both tests are builtins, so an ordinary call pays
   no fork and nothing measurable to ask them, and neither can fire on a real
   hook call: `hooks/hooks.json` passes no arguments and Claude Code hands the
   hook stdin on a pipe, so anything reaching `human_mode` came from a person.
   Without the dispatch, running the script by hand hangs on the `read` at
   step 6, waiting for an EOF a terminal does not send until the user finds
   Ctrl-D (#34).

   The call is written `human_mode "$@" || exit "$?"`, not as a bare call
   followed by `return`. `human_mode` returns 2 on a usage error, and a bare
   non-zero command is exactly what the `ERR` trap at step 4 catches: probed
   with a reduced copy of this script, the bare form turned that 2 into
   `emit_allow; exit 0`, so the guard answered a mistyped flag with `{}` and a
   success. The `||` keeps `human_mode` off errexit's radar for its whole
   dynamic extent — the same construct invariant 2 protects on the
   `repeat_check` call — and the `exit` is what carries the status out to the
   shell.

   Sitting after the version guard at step 3 is deliberate, and it costs
   `--help` on bash below 4.3; see **Known limitations** below.
6. `main` reads the hook JSON from stdin into `input` with the `read` builtin —
   `IFS= read -r -d '' input || :` — rather than the `input="$(cat)"` it used
   to, which was a fork and an exec on every Bash tool call before the guard
   had looked at anything. The empty delimiter reads to EOF, so `read` returns
   1 having stored the whole payload; the `|| :` is what makes that normal case
   a success rather than an `ERR` trip. Two differences from `$(cat)`, both
   inert: a trailing newline now survives, which neither the prefilter's
   substring test nor `jq` cares about, and a raw NUL would truncate the
   payload — which Claude Code's payloads, serialized by Node's
   `JSON.stringify`, cannot contain.
7. The prefilter: `input` is tested for the raw substrings `pgrep`, `kill` and
   `.output`, and a payload carrying none of them returns `{}` immediately,
   before `jq` or the awk scanner ever spawn — and, since everything downstream
   is in the sibling, having parsed and executed nothing beyond this file. See
   invariant 4 below for why a raw-payload substring test cannot suppress a
   verdict the rest of the guard would otherwise reach.
8. Past the prefilter, `main` calls `load_body` — the same function step 5
   calls. It runs `resolve_hook_dir` to freeze `HOOK_DIR`: one `dirname` fork
   and exec, which locates both the sibling and — through the sibling's
   `resolve_scanner` — the awk scanner, so no path pays a second process for
   the second lookup. Two branches then stand down loudly, exactly as the
   precondition guards inside the body do: the sibling missing or unreadable,
   and the `source` itself failing. The `||` on that `source` is what keeps a
   corrupt sibling off the `ERR` trap, which would otherwise answer a broken
   install with a bare `{}`. It is a function rather than the inline block it
   was before #34 because two call sites now need it, and a second copy of
   ~15 lines would spend the fast-path budget invariant 5 exists to protect.
   Both callers read it as `load_body || return 0`: the `systemMessage` is
   already on stdout by then, so the caller's only remaining job is to stop.
   With the body loaded, `main` calls `inspect_command "${input}"`.

### `hooks/pgrep-pkill-guard-body.sh`

The rest of the guard: every constant except `HOOK_NAME`, every function except
`emit_allow`, `resolve_hook_dir`, `load_body` and `main`, and `inspect_command`,
which is what used to be the second half of `main`. A call the prefilter
short-circuits never parses a line of it, which is the entire reason the file
exists.

It is **sourced, never executed** — no shebang, no exec bit — and it sets no
`set -Eeuo pipefail`, no `IFS` and no `ERR` trap, because it runs in the entry
script's shell and would be reconfiguring its caller rather than itself
(invariant 2).

Three of its members sit off the hook's path entirely, reached only from the
dispatch at step 5. `print_help` holds the help text as a single quoted heredoc
— usage, the stdin/stdout contract, the options, the `jq --null-input` probe
recipe the README also carries, `PGREP_PKILL_GUARD_STATE_DIR` and its
resolution order, the exit codes, and the project URL. `human_mode` is what the
dispatch actually calls: it scans **every** argument for `-h` or `--help` first
and prints help whatever else was passed (clig.dev, so `--bogus --help` still
helps), accepts `--version` only as the lone argument, answers a bare run on a
terminal by naming stdin rather than blocking on it, and otherwise writes one
error line plus a `--help` hint to stderr and returns 2. `HOOK_VERSION` is the
literal `--version` prints, as `pgrep-pkill-guard <version>` — GNU style,
one line, nothing else on it, because that line is what gets pasted into a bug
report.

A literal rather than a runtime read of `.claude-plugin/plugin.json`: reading
it would need path resolution up out of `hooks/`, a `jq` spawn and its own
fail-open story for an unparsable manifest, all to print a string fixed at
release time. Two things outside this file keep the literal honest. Its
`# x-release-please-version` comment must stay on the same line as the value —
that is the form release-please's generic updater rewrites, not the
`x-release-please-start-version` block syntax — and `release-please-config.json`
names the body as a third `extra-files` entry of `type: "generic"`, so a release
bumps it alongside `plugin.json` and `marketplace.json`.
`.ci/check-versions-in-sync` then reads it as a fourth version source, failing
loudly if the line is missing, unannotated or not semver-shaped, and asserts it
equals `plugin.json`'s `.version`. That assertion has **no `BOOTSTRAP_VERSION`
exemption**, unlike the `.release-please-manifest.json` arm beside it: the
exemption exists because an unreleased repo legitimately reports `0.0.0`, and
extending it here would let `--version` print a confidently wrong number into a
bug report. A missing version is an inconvenience; a wrong one sends the
maintainer to the wrong commit.

Picking up where step 8 above left off, `inspect_command`:

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

**There is exactly one exception, and it is on argv.** `human_mode` returns 2
for an unrecognized argument and for a bare run with stdin on a terminal, and
the entry script's `human_mode "$@" || exit "$?"` is written precisely so that
2 survives the `ERR` trap and becomes the process's exit status. A `PreToolUse`
hook exiting 2 means *block the tool call*, so this is the one path in the repo
that does not fail open. It is safe because arguments cannot reach the script
from Claude Code: `hooks/hooks.json` passes none, so the 2 lands in a terminal
next to the stderr line explaining it. Someone who hand-edited
`hooks/hooks.json` to pass an argument would have every Bash call blocked with
a loud message rather than silently unguarded — the right answer for a broken
configuration, and the reason the exception is acceptable rather than merely
tolerated (#34).

## Known limitations

Behaviour the guard does not have, recorded deliberately rather than left to be
rediscovered. Where the limitation is about a command shape it is pinned by rows
in `tests/cases/verdicts.tsv`, so the limitation is a tested decision rather than
an accident, and closing one means changing a recorded verdict on purpose.

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

### `--help` and `--version` are unavailable on bash below 4.3

The human-mode dispatch sits after the bash-version guard, so on stock macOS
bash 3.2 both flags get that guard's `bash 4.3+ required … INACTIVE`
`systemMessage` and exit 0 — the guard answers the install question rather than
the question that was asked. `.ci/check-inactive-on-old-bash`, the stock-bash
compat leg, pins the guard answering first on that shell; the flags take the
same branch by construction, since the version guard runs before `main` is ever
called.

Answering the asked question would mean a third file in `hooks/`, written
bash-3.2-safe, sourced ahead of the version guard, carrying its own codemap
entry here and its own two fail-open branches for being missing or unloadable —
a large structural price on the one file whose length is a per-call latency tax
(invariant 5). And it would buy little: the message that reader already gets
names their exact problem and its exact fix, `brew install bash`, which beats
both help for a guard that is not running and a version number for one.
Declined on that trade, deliberately.

Recorded as part of #34.

## Design invariants

Six rules the code depends on that are not evident from reading any single
file. Each is repeated as a comment in the source it constrains; if one changes
here, change the comment too. Invariants 5 and 6 additionally have a gate
behind them (`.ci/check-fast-path-size`, `.ci/check-err-trap-hygiene`); the
other four rest on the comments and on review.

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
with the rest. It is **185 lines** today: 152 immediately after the #55 split,
plus the human-mode dispatch and the `load_body` extraction from #34.

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
number spends those milliseconds again, a few dozen microseconds at a time. #34
is the worked example: the dispatch and the `load_body` extraction cost the
entry script 33 lines because they have to sit there, and the 140 lines of help
text, version constant and usage handling they dispatch to went to the body. The
win is invisible to every other check in this repo, so without the gate it would
regress one helper at a time and nobody would notice. The gate also fails on a
zero-line count: an empty read is a broken measurement, not a very fast hook.

**Tracked comments:** the header of `.ci/check-fast-path-size`, which carries
the measurement above, and the header of `hooks/pgrep-pkill-guard-body.sh`,
which points back to this invariant.

### 6. A deliberate non-zero `return` is preceded by `trap - ERR`

In every gate script that installs the `ERR` trap, a deliberate non-zero
`return` from `main` must be preceded by `trap - ERR`.
`.ci/check-err-trap-hygiene` enforces it, and `run-all-checks` runs that gate
with the rest. #43 fixed **19 such returns across 12 files**; counting the
gate's own two, it polices **21 returns across 13 files** today.

**Why:** the trap is there to report *unexpected* failure, and a gate
announcing its own verdict is the one thing it must not report as a crash.
Before #43, a real `.ci/check-manifest-invariants` failure ended like this:

```text
FAIL: I9: marketplace plugins[0] source contains a path traversal (..): ../../etc
FAIL: I8: marketplace plugins[0] source "../../etc" has no vendored .../plugin.json
[check-manifest-invariants] ERROR: line 225 (exit 1): return "${rc}"
```

The first two lines are the answer. The third sends the reader hunting for a
bug at line 225, where there is none — and line 225 is not even the `return`
the message quotes: `LINENO` in that report is the `main "$@"` line at the
bottom of the file. The trap fires once, at the top-level call, whatever
returned non-zero underneath it. So the one line of the three that looks like a
stack pointer is the one line that points nowhere.

**Why not `main "$@" || exit "$?"`.** It silences the report too, and it is a
correctness bug rather than a style preference. The trailing `||` suppresses
errexit and the `ERR` trap for the entire dynamic extent of `main`. Probed on a
script with a nonexistent command partway through `main`:

```text
$ bash d.sh
d.sh: line 6: nonexistent_command_xyz: command not found
REACHED-AFTER-ERROR
exit=0
```

The failed command is swallowed, execution carries on past it, and the gate
exits **0** — a gate that can pass while broken. `trap - ERR` at the return
gives up exactly one report, the one nobody wanted; the `||` gives up every
report `main` could ever have produced.

**The same construct, wanted, one directory over.** Invariant 2 depends on that
suppression deliberately: `repeat_reason="$(repeat_check …)" || repeat_reason=''`
is what keeps the guard's one stateful, filesystem-touching rule off the trap's
radar, so a transient filesystem condition cannot surface as a trapped error.
Load-bearing there, silent gate failure here. The mechanic is identical and only
the intent differs — whether the suppression is the thing you want. That is the
contrast to hold on to before copying either line into the other place.

**Scope.** The rule binds the gate family: `run-all-checks`, `run-tests` and the
`.ci/check-*` and `.ci/run-*` scripts. Four scripts sit outside it, verified
rather than assumed:

- `bench/run` — its `main` never returns non-zero. Bad input goes through
  `die`, and `exit` does not fire an `ERR` trap. It also swaps the `ERR` trap
  for an `EXIT` cleanup trap partway through `main`.
- `.ci/in-devshell` — `main` ends in `exec`, and its failure paths call
  `exit 1`.
- `.ci/activate-githooks` — installs no `ERR` trap.
- `.ci/check-inactive-on-old-bash` — POSIX `sh` with `set -eu`, no trap.

`return 0` sites are exempt, because a zero return never fires the trap. So are
returns in helper functions: every helper is called as `helper || rc=1`, and the
`||` already keeps it off the trap's radar.

**Why a gate and not a convention.** #43's own file list was wrong in both
directions. It predicted `bench/run` as an eleventh affected file, and it missed
`run-tests`, `.ci/check-fast-path-size` and `.ci/check-issue-forms` — all three
of which joined the family after the issue was filed, and every one of which
reintroduced the pattern without anyone noticing. That drift is the argument for
enforcing this from the tree rather than trusting a list: a new `.ci/check-*` is
covered the day it lands.

**The one `ERR` trap this rule must never touch.** `.ci/check-err-trap-hygiene`
derives its candidate set from the tree, so it also sees
`hooks/pgrep-pkill-guard.sh` — which installs `trap 'emit_allow; exit 0' ERR`.
That is a *fail-open* trap, not a reporting one: its whole job is to make any
unexpected failure emit an allow verdict rather than block the user's command,
which is invariant 2's discipline. Applying this rule there would be actively
wrong — a `trap - ERR` before a return in the hook's `main` would hand the user
a broken guard instead of an open one. The hook has no such return today, so
the gate would be quiet either way; the exemption is written down so that it
stays the right answer if one is ever added. It keys off what the handler
**does** — exits 0 — rather than off a path, so a second fail-open script is
covered without editing the gate, and the gate says so on every green run:

```text
ok: 15 scripts install a reporting ERR trap; 21 deliberate non-zero returns all clear it
ok: 1 fail-open ERR trap(s) not policed by this rule: hooks/pgrep-pkill-guard.sh
```

**Tracked comments:** the `A gate reporting its own verdict is not a crash`
comment at each of the 19 sites, worded to the diagnostics it follows:

```text
# A gate reporting its own verdict is not a crash: drop the ERR trap so the
# diagnostics above are the last thing the reader sees (#43, invariant 6).
```

and the `@description` header of `.ci/check-err-trap-hygiene`, which carries the
rule it enforces and points back here.
