# Security policy

## What this is

`pgrep-pkill-guard` is a Claude Code `PreToolUse` hook. It denies a small set of
`pgrep`/`pkill` command shapes that make an agent kill its own session or spin
forever on a process that can never exit. That is its entire remit.

It is **not a sandbox**, **not a privilege boundary**, and **not a defence
against a hostile operator or a hostile prompt author**. Anyone who can run the
Bash tool through Claude Code can already run anything that user account can
run, and a hook that reads one command string does not change that. The guard
narrows one footgun; it does not contain an adversary.

Read it the way a linter rule reads: useful, worth fixing when it is wrong, and
never the thing standing between an attacker and the machine.

## What it cannot see

The guard inspects exactly one thing — the command string handed to the Bash
tool. Anything outside that string is invisible to it:

- **`bash script.sh`.** The hook sees the invocation, not the file. A
  `pkill --full java` on line 40 of the script is never examined.
- **Write-then-run.** Code written to a file in one tool call and executed in
  the next is two commands, and neither one carries the dangerous shape.
- **Other tools.** The matcher covers the Bash tool. Nothing reaches the guard
  from any other tool, or from a process spawned outside it.

The guard also stands down under conditions it can detect but not repair. In
each of these the command is **allowed**, and a `systemMessage` tells the user
the guard is inactive for that command:

- bash older than 4.3 — the guard uses namerefs
- an awk that fails the scanner's in-band integrity trailer, the check that
  proves the awk in use handed back every byte of the command
- `jq` or `awk` missing from `PATH`, or the scanner file itself unreadable

The `repeat` rule — the one stateful rule — stands down **silently** whenever
its state directory is unusable: missing, unreadable, not a directory, not
owned by the calling user, a symlink, or holding an oversized file. It emits
nothing, and the command proceeds.

Every one of these paths allows the command. Fail-open is deliberate: a hook
that blocked on its own breakage would be worse than no hook, and the loud
cases say so out loud precisely because a silent stand-down would leave the
user believing in protection that is not there.

## Bypasses are public bugs

A `pgrep`/`pkill` shape that slips past the guard is a **false negative**, not a
vulnerability. It leaves the user exactly where an unguarded shape leaves them
and exactly where they were before the hook existed. There is nothing to
embargo.

Report it in public, with the **False verdict** option at
[New issue](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/new/choose)
(the form at `.github/ISSUE_TEMPLATE/false-verdict.yml`). Give the exact
command, verbatim — quoting and whitespace both matter, since the guard
tokenizes the string. Every fix lands as a row in `tests/cases/verdicts.tsv`, so
a reported command becomes a permanent regression test.

A private report of a false negative only delays the fix. It cannot be
discussed in the issue tracker, it cannot be linked from the test row it turns
into, and it buys no protection that the public report does not.

## What is privately reportable

Report privately anything that turns the guard into a way to **cause** the harm
it prevents, or into a channel between users:

- **The hook executing attacker-controlled input.** The guard parses command
  strings. A command string that ends up evaluated rather than tokenized is a
  vulnerability in the guard itself.
- **State-directory symlink or TOCTOU issues.** The `repeat` rule's state can
  live under a shared `/tmp`. Anything that lets one local user plant,
  redirect, or race the state another user's guard reads — forcing a false
  deny, or steering a write outside the state directory — belongs here.
- **Injection into the JSON decision output.** A crafted command that forges an
  `allow`, or that rewrites the reason text an agent then acts on, is an
  injection into a channel the model trusts.
- Anything else that makes the guard the mechanism of the damage rather than
  the thing that declined to prevent it.

## Reporting a vulnerability

Use GitHub private vulnerability reporting:
**[Report a vulnerability](https://github.com/rvenutolo/claude-pgrep-pkill-guard/security/advisories/new)**.
Reports are not accepted by email.

Include:

1. The exact command or hook JSON, verbatim.
2. What the guard did, and what it should have done.
3. Your platform, plus `bash --version` and `awk --version`.
4. The impact — what an attacker gains, and what access the attack assumes.

Expect an acknowledgement within 7 days. Please do not open a public issue for
anything in the list above until a fix has shipped.

## Supported versions

Only the latest release is supported; fixes ship in a new release rather than as
patches to older tags.
