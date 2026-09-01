# pgrep-pkill-guard

[![CI](https://github.com/rvenutolo/claude-pgrep-pkill-guard/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/rvenutolo/claude-pgrep-pkill-guard/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/rvenutolo/claude-pgrep-pkill-guard?sort=semver)](https://github.com/rvenutolo/claude-pgrep-pkill-guard/releases)
[![License: MIT](https://img.shields.io/github/license/rvenutolo/claude-pgrep-pkill-guard)](LICENSE)

A Claude Code `PreToolUse` hook that blocks the `pgrep`/`pkill` command shapes
that make an agent kill its own session or spin forever on a process that can
never exit.

![Claude Code denying a `pkill --full` call. The guard's reason explains that
the pattern matches the invoking `bash -c` shell and would terminate the
session, then lists three fixes: kill by PID, `--ignore-ancestors`, or the
`"[p]attern"` bracket trick.](assets/deny-message.png)

The reason leads with the Write tool on purpose: quoting a denied command in
prose is the one legitimate way that shape reaches the Bash tool, and when that
line trailed the fixes instead of opening the message it went unread.

## Why this exists

An agent runs `pkill --full java` to clean up a stuck JVM, and the session dies
with it. The pattern matched the shell that was running the command, so the
agent killed its own session.

The Bash tool runs every command as `bash -c '<command>'`. The command text is
therefore part of an **ancestor process command line**, and any pattern search
over full command lines finds it.

Two things follow, and both happen in practice:

- `pkill --full java` matches the `bash -c 'pkill --full java'` that is running
  it.
- `until ! pgrep --full myserver; do sleep 5; done` matches the `bash -c` that
  is running the loop. The loop always sees a live process, so it never exits —
  it spins until the tool call times out or a human intervenes.

Before — the agent runs it:

```console
$ pkill --full java
(the session shell is gone)
```

After — the hook denies the call and hands the agent three ways out:

```console
$ jq --null-input --arg cmd 'pkill --full java' \
    '{tool_name:"Bash",tool_input:{command:$cmd}}' \
  | ./hooks/pgrep-pkill-guard.sh \
  | jq -r '.hookSpecificOutput.permissionDecisionReason'
```

```text
If this command WRITES text that contains such an example (a heredoc, `echo`, or `printf` into
a file) rather than running one, use the Write tool instead; this guard only inspects Bash commands.

This matches the invoking shell itself. The Bash tool runs commands as `bash -c ...`,
so the search pattern is part of an ancestor process command line, and killing that match terminates
the session shell.

Three fixes, in order of preference:

1. Kill by PID, not by pattern. Use a PID recorded when the process was started (`kill "$pid"`, a
   PID file), or probe liveness first with `kill -0 "$pid"`. Pattern-matching kills are the root
   cause; the self-match is a symptom.
2. `pkill --ignore-ancestors --full <pattern>` excludes the `bash -c` ancestor.
3. `pkill --full "[p]attern"` hides the needle from its own regex, but only when the bare literal
   appears NOWHERE ELSE in the same command. A second copy in the same call silently defeats it.
```

The reason text is the product, not the denial. Every deny names the mitigation
for its kind, so the agent's next attempt is the correct command rather than a
retry of the same one.

## What it denies

Four deny kinds, plus a warn tier. Everything else is allowed with a bare `{}`.

| Kind | Fires on | Mitigation the reason names |
| --- | --- | --- |
| `kill` | a pattern kill whose pattern matches the invoking shell — `pkill --full java`, `pkill -f java`, `pgrep --full java \| xargs kill` | `--ignore-ancestors`, or a PID, or `"[j]ava"` |
| `loop` | a loop whose termination test is a full-command-line pattern search — `until ! pgrep --full x; do sleep 5; done` | `while kill -0 "$pid"`, or stop polling |
| `task-poll` | a loop whose termination test reads a harness task-output file (`…/tasks/<id>.output`) | stop and wait for the task notification, or `TaskOutput` with `block: true` |
| `repeat` | the third probe of the same target within 300 s, in one session | stop and wait for the task notification, or `TaskOutput` with `block: true` |
| *warn* | a `pgrep --full` whose **result is consumed** but which is not a loop or a kill — `pgrep --full x \| wc -l`, `pgrep --full x && echo up` | allowed, with an `additionalContext` note that the count is inflated by one and exit status 0 does not mean the target is running |

A bare `pgrep --full java` whose result nothing reads is allowed silently: the
inflated match only matters when something acts on it.

`repeat` catches the poll loop an agent writes without a loop — running the same
one-shot check by hand three times, with itself as the `sleep`. It is the only
stateful rule:

- One file per session, `<state-dir>/<session_id>`, of `<epoch>\t<key>` lines.
- Entries older than the 300 s window are pruned on every write.
- A denied command is not recorded, and a request with no `session_id` is never
  recorded at all.
- **Every state failure allows.** No directory, unreadable, not a regular file,
  not owned by us, a symlinked directory, an oversized file — each returns
  quietly and the command proceeds. The state is a heuristic; it is never
  allowed to become a way to fail closed.

## Install

```text
/plugin marketplace add rvenutolo/claude-pgrep-pkill-guard
/plugin install pgrep-pkill-guard@rvenutolo
/reload-plugins
```

The repo is its own marketplace, so there is no separate marketplace to add.
The third line activates the newly installed hook in the running session.

If the install reports that the marketplace is not found, the first line has not
taken effect yet. Run it, then `/reload-plugins`, then retry the install.

The same two steps from the CLI, for scripting a machine or a dotfiles
bootstrap:

```console
claude plugin marketplace add rvenutolo/claude-pgrep-pkill-guard
claude plugin install pgrep-pkill-guard@rvenutolo
```

`claude plugin install` takes `-s`/`--scope` with the values `user`, `project`,
or `local`, and defaults to `user`. `user` records the install for every project
on this machine, `project` records it in the repo for the team, and `local`
records it for this checkout only. `claude plugin marketplace add` takes its own
`--scope`, with the same three values and the same `user` default, but no short
form.

## Compatibility

The guard is bash and awk with no network calls, so "supported" means one thing
here: the shells and awks CI actually runs it under. Every row below is a real
job in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

| Platform | bash | awk | CI job |
| --- | --- | --- | --- |
| Linux, hermetic Nix devShell | the flake's bash, pinned by `flake.lock` | gawk **and** one-true-awk | `gate (ubuntu-latest)` |
| macOS, hermetic Nix devShell | the flake's bash, pinned by `flake.lock` | gawk **and** one-true-awk | `gate (macos-latest)` |
| Linux, ambient distro tools | the runner image's own bash | whatever the image resolves `awk` to | `compat (ubuntu, ambient)` |
| macOS, `brew install bash` | Homebrew bash | stock `/usr/bin/awk` (one-true-awk) | `compat (macos, homebrew bash)` |
| macOS, stock bash 3.2 | 3.2 — the guard reports itself INACTIVE | not reached | `compat (macos, stock bash 3.2)` |

The two `gate` legs run the whole gate — formatting, lints, the governance
checks and the bats suite twice, once under gawk and once under one-true-awk —
inside the flake's devShell, so both the bash and both awks come from
`flake.lock` rather than from the runner. The two ambient `compat` legs run the
test suite only, against the tools the runner ships: `compat (ubuntu, ambient)`
takes the image's own bash, `jq` and `awk`, and prints which awk it got, since
the image may resolve it to either gawk or mawk. `compat (macos, homebrew
bash)` installs bash from Homebrew and nothing else, then asserts that `awk`
still resolves to `/usr/bin/awk` before running the suite. `compat (macos,
stock bash 3.2)` does not run the suite at all; it asserts the property that
matters on a machine below the floor — that the guard says so out loud rather
than quietly doing nothing.

What that reduces to, for the machine you are installing on:

- **bash 4.3 or newer** (the guard uses namerefs)
- **`jq`**
- **`awk`** — any POSIX awk: gawk, mawk, or one-true-awk (the stock `awk` on
  macOS and the BSDs). The scanner depends on nothing awk-specific.
- **Claude Code** — any version with plugin marketplaces and `PreToolUse`
  `permissionDecision` support. There is no verified numeric floor to quote, so
  this README does not invent one; CI validates both plugin manifests against a
  pinned CLI (`2.1.251`, in the `validate` job).

**Linux works out of the box.** Distro bash is 4.3+.

**macOS needs one Homebrew package:**

```console
brew install bash
```

Stock macOS ships bash 3.2 — a decade below the floor. Its awk is fine.

**With bash too old, the guard reports itself INACTIVE rather than guarding
silently wrongly.** Fail-open-loudly is deliberate, and it is the thing to know
how to read. On stock bash, every command gets:

```text
pgrep-pkill-guard: bash 4.3+ required (found 3.2); the pgrep/pkill guard is INACTIVE for this command. On macOS: brew install bash.
```

An in-band integrity trailer in the scanner checks that the awk in use handed
back every byte of the command; if one ever does not, affected commands get:

```text
pgrep-pkill-guard: the command scanner tokenized this command incorrectly (incompatible awk?); the pgrep/pkill guard is INACTIVE for this command.
```

The same shape is emitted when `jq` or `awk` is missing from `PATH`, or when the
scanner file itself cannot be read. **Every one of these allows the command.** A
hook that blocked on its own breakage would be worse than no hook; a hook that
went quiet on its own breakage would be worse still, because you would never
learn you were unprotected.

## Limitations

- **It reads one string.** The guard sees the command text handed to the Bash
  tool and nothing else. `bash script.sh` is opaque to it — the invocation is
  inspected, the file is not, so a `pkill --full java` on line 40 of that script
  is never examined. The same goes for a script written to a file in one tool
  call and run in the next: neither call carries the dangerous shape. Nothing
  from any other tool reaches the guard at all; the hook matches `Bash` only.
- **It stands down rather than guessing.** Every precondition listed under
  [Compatibility](#compatibility) that fails — an old bash, a missing `jq` or
  `awk`, an unreadable scanner, an awk that fails the integrity trailer — makes
  the guard inactive for that command and says so. Any other unexpected failure
  inside the hook is caught by an `ERR` trap that emits a bare allow. No
  precondition failure ever produces a deny.
- **The state rule is best-effort.** `repeat` needs two things it cannot create:
  a `session_id` on the request, and a state directory it owns. Without either
  it returns without a word, and the command proceeds. Unlike the precondition
  failures above, this stand-down is silent — nothing tells you the third probe
  went uncounted.
- **Pattern rules are bypassable by construction.** The guard matches command
  shapes, so a rewrite defeats it, and two of those rewrites are documented
  escapes on purpose. It is a guardrail against a mistake, not a boundary
  against an adversary — see [Security](#security).

## Performance

The guard is a `PreToolUse` hook, so it runs on every Bash tool call. A command
mentioning none of `pgrep`, `kill` or a task-output file is answered before the
hook spawns `jq`, the scanner, or anything else at all — which is what almost
every command in a session does.

On the author's machine — a 12th Gen Intel(R) Core(TM) i9-12900HK running Linux
6.8.0-138-generic x86_64 and bash 5.3.15(1)-release — such a command costs a
median of **2.48 ms**, p95 3.79 ms. Driven by the wider verdicts corpus instead
of a handful of curated ordinary commands, the same path costs 2.52 ms; the two
agreeing is what says the first figure is not an artifact of which commands were
picked. The empty-hook baseline on that same run is 1.57 ms, so the guard now
costs about **0.9 ms** above the bare process-spawn floor.

Getting there took three changes. The prefilter came first and moved an ordinary
command from about 19 ms to somewhere in the 9-12 ms range. Next went the two
helper processes the hook ran before it had looked at anything — a `cat` to read
the payload, a `dirname` to locate the scanner — which took it from about 9 ms
to about 5. What was left in front of it was the script's own parse: bash reads
a script whole before it executes a line of it, at roughly 1.2 us per line, so
2203 lines cost about 2.4 ms of every Bash tool call — four fifths of what
remained. Splitting the file took an ordinary command from about 5.6 ms to about
2.5.

The split is the reason `hooks/` holds two scripts.
`hooks/pgrep-pkill-guard.sh` is the entry script — 152 lines when the split
landed, 185 today — carrying only what an ordinary call actually executes: the
locale, the bash-version guard, the `ERR` trap, `emit_allow`, the
`--help`/`--version` dispatch, the builtin read of stdin, and the prefilter.
Everything the prefilter short-circuits past lives in
`hooks/pgrep-pkill-guard-body.sh`, which the entry script sources only after the
prefilter has failed to decide, and which an ordinary command never reads. Parse cost alone, measured with `bash -n`
over 400 repetitions: an empty script costs 4.12 ms, the entry script 4.25 ms
(+0.13), the old single file 6.49 ms (+2.38). A smaller split was measured and
rejected — moving only `deny_message`, the wrapper recursion and `repeat_check`
leaves about 1700 lines on the fast path and recovers about 0.6 ms.

Like the spawn removal before it, the split was measured as an interleaved
alternation rather than as two runs minutes apart: before, after, before, after,
two rounds each, one machine, `bench/run --reps 15` every time. An ordinary
command went 5.79 to 2.52 ms, then 5.36 to 2.54 — about a 54% cut — and the
corpus-driven variant of the same path moved with it, 5.61 to 2.58 and then 5.48
to 2.49. The control is `baseline`, the empty hook, which sat at 1.67, 1.57,
1.56 and 1.55 ms across the four runs and moved in no direction; that it did not
move is why the comparison is worth quoting.

What is left is not `jq`, not the scanner, not a helper process, and no longer
two thousand lines of parse. About 1.57 ms of the 2.48 is process spawn, which
any hook at all would pay, and the 0.13 ms of parse named above is most of what
the entry script adds on top of it.

Commands that reach the deeper paths cost more, and only they pay it: one the
guard has to look at closely — a `pgrep`/`pkill` shape, a loop, the `repeat`
state file — has a median of 43.80 ms, and a denied command 27.34 ms. Those
figures, and the 24.20 ms alongside them, are for a command the guard actually
inspects — one carrying `pgrep`, `kill` or a task-output path, past the
prefilter and into the `jq` spawn and scanner pass. They come from
`tests/cases/verdicts.tsv`, which exists to be hard on the scanner rather than
to be representative — read them as a ceiling, not as what a session pays.

The benchmark's payloads carry no `cwd` or `transcript_path`, so a real
session's hook payload is longer than any measured here; since the prefilter is
a raw substring test over the whole payload, a longer payload can only help it.
The same test cuts the other way for one shape: a repository path containing
`kill` defeats the short-circuit for every command run inside that tree, and
those calls pay the full `jq`-and-scanner cost whatever the command itself is.

One machine, one moment. The full table, the method and the provenance are in
[bench/RESULTS.md](bench/RESULTS.md); `just bench` regenerates it.

## Opting one command out

Add `--ignore-ancestors`. It is a real `pgrep`/`pkill` flag — it excludes the
ancestors of the calling process, which is exactly the false match — so the
opt-out also fixes the underlying command:

```console
pkill --ignore-ancestors --full java     # allowed
pgrep --ignore-ancestors --full java | wc -l   # allowed, no warning
```

`--ignore-ancestors` does **not** clear a `loop` deny, and that is not an
oversight. It excludes ancestors only, so two sibling waiters for the same event
still match each other and both spin forever. A loop needs a PID, not a better
pattern.

The other escape is the classic bracket trick, `pkill --full "[j]ava"`, which
hides the needle from its own regex. It is accepted, but only when the bare
literal appears nowhere else in the same command — a second copy silently
defeats it, and the guard checks for that.

There is no environment variable or config flag that disables the guard
wholesale. [Uninstall](#uninstall) the plugin if you want it off.

## `PGREP_PKILL_GUARD_STATE_DIR`

Overrides where the `repeat` rule keeps its per-session state. Resolution order:

1. `${PGREP_PKILL_GUARD_STATE_DIR}`
2. `${XDG_RUNTIME_DIR}/pgrep-pkill-guard`
3. `${TMPDIR}/pgrep-pkill-guard`, else `/tmp/pgrep-pkill-guard`

The directory is created mode `0700` and must be owned by the calling user and
not a symlink, or the rule silently stands down. Set it if `XDG_RUNTIME_DIR` is
unset or points somewhere unwritable, or to keep the state out of a shared
`/tmp`. The files are throwaway; deleting them only resets probe counters.

The plugin's own test suite sets this variable, which is the main reason it
exists.

## Uninstall

```text
/plugin uninstall pgrep-pkill-guard@rvenutolo
```

Or from the CLI:

```console
claude plugin uninstall pgrep-pkill-guard@rvenutolo
```

`claude plugin uninstall` takes the same `-s`/`--scope` flag as `install`, with
the same `user` default, so a plugin installed into `project` or `local` has to
be removed with the scope it was installed with.

Removing the marketplace is optional, and leaving it in place costs nothing. If
you want it gone too:

```text
/plugin marketplace remove rvenutolo
```

Nothing else needs cleaning up. The `repeat` rule's state directory lives
outside the plugin directory, so uninstalling leaves it in place; the files in
it are throwaway, and deleting them by hand only resets probe counters. See
[PGREP_PKILL_GUARD_STATE_DIR](#pgrep_pkill_guard_state_dir) for where it lives.

## Reporting a false verdict

A denied command that was actually safe — or a session-killing command that got
through — is a bug worth reporting. Use the **False verdict** option at
[New issue](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/new/choose);
the form asks for the exact command, the verdict you expected, and your bash and
awk versions.

Capture the command and the guard's own output with:

```console
jq --null-input --arg cmd '<your command here>' \
  '{tool_name:"Bash",tool_input:{command:$cmd}}' \
  | "${CLAUDE_PLUGIN_ROOT}"/hooks/pgrep-pkill-guard.sh
```

Paste both verbatim — quoting and whitespace matter, since the guard tokenizes
the string. Every fix lands as a row in `tests/cases/verdicts.tsv`, so a
reported command becomes a permanent regression test.

Include what `"${CLAUDE_PLUGIN_ROOT}"/hooks/pgrep-pkill-guard.sh --version`
prints — one line, `pgrep-pkill-guard <version>`. It names the release you are
running, and a gate asserts it equals `.claude-plugin/plugin.json`, so it cannot
drift from what was published. `--help` restates the recipe above along with the
stdin/stdout contract, so reproducing a verdict needs neither this page nor a
network connection.

## Security

The guard's trust model is in [SECURITY.md](SECURITY.md), which also says what
to report privately. **A command shape that slips past the guard is not one of
those things:** it is a false negative, and it belongs in a public issue, using
the form above.

[Limitations](#limitations) is the short version of that model: what the guard
does not see, and where it stands down.

## Contributing

Contributions are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers the Nix
devShell, the gate, the commit convention and the rules the test suite is held
to; [docs/architecture.md](docs/architecture.md) traces how a command moves
through the guard and records the six design invariants that look like
inconsistencies and are not.

## License

MIT. See [LICENSE](LICENSE).
