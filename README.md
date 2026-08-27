# pgrep-pkill-guard

A Claude Code `PreToolUse` hook that blocks the `pgrep`/`pkill` command shapes
that make an agent kill its own session or spin forever on a process that can
never exit.

## What it prevents

The Bash tool runs every command as `bash -c '<command>'`. The command text is
therefore part of an **ancestor process command line**, and any pattern search
over full command lines finds it.

Two things follow, and both happen in practice:

- `pkill --full java` matches the `bash -c 'pkill --full java'` that is running
  it. The agent kills its own session.
- `until ! pgrep --full myserver; do sleep 5; done` matches the `bash -c` that
  is running the loop. The loop always sees a live process, so it never exits —
  it spins until the tool call times out or a human intervenes.

Before — the agent runs it, and the session dies:

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
```

The repo is its own marketplace, so there is no separate marketplace to add.

## Requirements

- **bash 4.3 or newer** (the guard uses namerefs)
- **`jq`**
- **`awk`** — any POSIX awk: gawk, mawk, or one-true-awk (the stock `awk` on
  macOS and the BSDs). The scanner depends on nothing awk-specific, and the
  repo's own gate runs the whole suite under gawk *and* one-true-awk.

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
wholesale. Uninstall the plugin if you want it off.

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

## Reporting a false positive

A denied command that was actually safe is a bug worth reporting. Open an issue
at
[rvenutolo/claude-pgrep-pkill-guard/issues](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues)
with:

1. **The exact command**, verbatim — quoting and whitespace both matter, since
   the guard tokenizes the string.
2. The reason text the guard returned.
3. Your platform, plus `bash --version` and `awk --version`.

The fastest way to capture the first two:

```console
jq --null-input --arg cmd '<your command here>' \
  '{tool_name:"Bash",tool_input:{command:$cmd}}' \
  | "${CLAUDE_PLUGIN_ROOT}"/hooks/pgrep-pkill-guard.sh
```

Every fix lands as a row in `tests/cases/verdicts.tsv`, so a reported command
becomes a permanent regression test.

## License

MIT. See [LICENSE](LICENSE).
