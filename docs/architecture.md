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

The guard itself. In execution order:

1. `export LC_ALL=C`, before anything else. The scanner emits **byte** offsets
   and this script slices the raw command back out with
   `${command:offset:length}`. Bash string operations are locale-aware, so under
   a UTF-8 locale a single multibyte character earlier in the command shifts
   every later slice and silently voids the bracket mitigation.
2. Precondition guards, each of which stands down loudly: bash older than 4.3,
   `jq` missing from `PATH`, `awk` missing from `PATH`, the scanner file
   unreadable. The bash check comes first because it is the only one that can
   run on a shell too old for the rest of the script.
3. `trap 'emit_allow; exit 0' ERR`. A hook that dies non-zero surfaces an error
   on every Bash call, and exit 2 would block the tool outright.
4. Read the hook JSON from stdin, and extract `tool_name`,
   `tool_input.command` and `session_id` in a **single** `jq ... | @tsv` call —
   one jq spawn, since this runs on every Bash call. `@tsv` escapes literal tabs
   and newlines in the command, which `printf '%b'` then decodes in one
   left-to-right pass. A `tool_name` other than `Bash` allows immediately.
5. `classify_command` runs the stateless tiers and prints a verdict plus a tab
   and the detail its message needs (the invoked tool, or the polled path).
   `main` owns stdout; the classifier hands the verdict up rather than writing
   the decision itself.
6. The stateful `repeat` tier, which runs only after the stateless tiers have
   allowed or warned.
7. Emission. `emit_allow` prints a bare `{}`; `emit_warn` prints an `allow`
   decision carrying `additionalContext`; `emit_deny` prints a `deny` decision
   carrying `permissionDecisionReason`, built by `deny_message` from the kind
   and its detail. `additionalContext` is the only `PreToolUse` field verified
   to reach the model on an allowed call — `systemMessage` renders to the user
   only, and `permissionDecisionReason` is fed back under deny alone.

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
| `inactive` | the scanner failed its integrity trailer; `main` emits the INACTIVE `systemMessage` |

`repeat` is the fifth deny kind and is not one of these: it is decided after
classification, in `main`, because it is the only stateful rule.

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
  asserts the decision plus the mitigation needle that identifies the kind) and
  by `tests/deny-sweep.bats`.
- `messages.tsv` — `<command>\t<field>\t<mode>\t<needle>`, read by
  `tests/messages.bats`, where `field` is `reason`, `context` or `decision` and
  `mode` is `contains`, `lacks` or `equals`. `lacks` asserts absence, which is
  how the tables pin that a `loop` deny does *not* offer `--ignore-ancestors`.

The remaining bats files cover the parts no table can express:
`tests/scanner.bats` (the awk scanner directly), `tests/repeat.bats` (the
stateful tier and its state-directory failure modes) and `tests/manifest.bats`.

## Fail open, loudly

One rule explains most of the code. **Every precondition failure and every
state failure allows the command**, and the ones a user could act on emit a
`systemMessage` saying the guard is INACTIVE for that command.

The loud path covers bash below 4.3, a missing `jq` or `awk`, an unreadable
scanner, and an awk that fails the integrity trailer. The silent path covers
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

## Design invariants

Three rules the code depends on and cannot enforce. Each is repeated as a
comment in the source it constrains; if one changes here, change the comment
too.

### 1. `hooks/` uses POSIX short flags, not GNU long options

The rest of the repo uses GNU long options (`mkdir --parents`, `rm --force`).
`hooks/` is exempt and must use POSIX short flags — `mkdir -p -m 0700`,
`rm -f`, `mv -f`.

**Why:** the hook runs on whatever userland the user's machine ships. macOS
ships BSD coreutils, whose `mkdir` has no long options at all — no `--parents`,
no `--mode=` — and whose `rm` has no `--force`. A long option there is not a
style preference; it is a runtime failure on half the supported platforms.
Everything else in the repo — `.ci/`, `run-all-checks`, `run-tests`,
`.githooks/`, `.justfile`, the workflows — keeps long options, because those run
only inside the hermetic Nix devShell where GNU coreutils is guaranteed.

**Tracked comments:** the two `POSIX short flags, deliberately` comments in
`hooks/pgrep-pkill-guard.sh`, in `repeat_check` and in its write path:

```text
# POSIX short flags, deliberately: macOS ships BSD coreutils, whose mkdir has
# no long options at all (no `parents`, no `mode=`). hooks/ is the one
# directory in this repo exempt from the repo-wide long-options rule, for
# exactly that reason -- the guard has to run on whatever userland ships.
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

Every gate script in the repo sets it. The hook must not, and no one may turn
the assignment below into a plain one.

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
fallback is also why `main` accepts the result as a deny only when it is shaped
like `repeat_message`'s output.

**Tracked comment:** `The || is load-bearing beyond the obvious fallback` in
`hooks/pgrep-pkill-guard.sh`, in `main` directly above that assignment:

```text
# The `||` is load-bearing beyond the obvious fallback: it is what
# keeps this whole command substitution off errexit's radar for its
# entire dynamic extent, so nothing inside repeat_check can trip the
# top-level ERR trap. Do not turn this into a plain assignment.
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

**The one exception** is `hooks/pgrep-scan.awk`, which has its own public
interface: a command on stdin, offset/token records and an integrity trailer on
stdout. `tests/scanner.bats` may drive it directly with `awk -f`, always under
`LC_ALL=C`, because that is precisely how the hook itself calls it.
