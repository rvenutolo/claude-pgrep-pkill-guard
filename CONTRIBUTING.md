# Contributing

Thanks for looking. This is a small, single-purpose plugin: a Claude Code
`PreToolUse` hook, an awk scanner, and a table-driven bats suite. The fastest
useful contribution is usually a wrong verdict reported with the exact command
that produced it — it becomes a row in `tests/cases/verdicts.tsv` and a
permanent regression test.

[`docs/architecture.md`](docs/architecture.md) explains how the guard works and
why three of its rules are written the way they are.
[`SECURITY.md`](SECURITY.md) covers what the guard can and cannot see, and what
belongs in a private report.

## Setup

The repo ships a Nix flake with every tool the gate needs, pinned. With
[direnv](https://direnv.net) installed:

```console
direnv allow
```

Without direnv:

```console
nix develop
```

That is the whole setup. The only thing the devShell does not supply is the
bash that runs the hook by hand outside it: the guard needs **bash 4.3 or
newer**, so on macOS run `brew install bash` as the README instructs.

Activate the tracked git hooks once per clone:

```console
just hooks
```

## Running the gate

**Everything runs through `./.ci/in-devshell`. Never invoke a gate tool from
the ambient `PATH`.** That wrapper runs `nix develop --ignore-environment`, so
the devShell cannot inherit the caller's `PATH` and no gate step can silently
resolve a tool from the machine it happens to be running on. Local runs and CI
runs therefore cannot drift. The `just` recipes all go through it:

| Recipe | What it does |
| --- | --- |
| `just check` | the full local verification gate (the default recipe) |
| `just test` | the bats suite; extra arguments are forwarded to `run-tests` |
| `just lint` | the config, markup and shell lint suite |
| `just validate` | validates both plugin manifests with the Claude Code CLI, when it is installed |
| `just format` | formats every file via treefmt |
| `just format-check` | verifies formatting without writing changes |
| `just hooks` | activates the tracked git hooks for this clone |
| `just install` | prints the commands that add this working copy as a local marketplace, for dogfooding |

`just check` is verify-only — it never rewrites the tree — so run `just format`
first. It aggregates exit codes rather than failing fast, so one run surfaces
every failing category. It also runs the bats suite twice, once under gawk and
once under one-true-awk, because the hook must behave identically on both.

A PR is ready when `just format`, `just check` and `just validate` are all
green.

## Commits

Commit messages follow the Angular convention: `type: subject`, imperative
mood, 72-character subject line, with `!` after the type for a breaking change.
Allowed types are `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `ci`,
`perf`, `style`, `build` and `revert`. An optional body after a blank line
explains *why*, not *what*.

commitlint enforces this through the tracked `commit-msg` hook that `just
hooks` activates, running inside the devShell so the same commitlint runs
locally and in CI.

release-please consumes that history to cut releases and to write
`CHANGELOG.md`. **Never hand-edit `CHANGELOG.md`.** The next release run
overwrites it, and the edit is lost along with whatever it was trying to say.

## Tests

The suite is bats only, under `tests/`. Three rules:

- **Drive the hook as a subprocess with hook JSON on stdin, and assert on the
  JSON it writes to stdout.** `tests/test_helper/common.bash` provides
  `hook_json`, `run_hook`, `decision_of`, `reason_of` and `context_of`; that is
  the whole interface. **Never `source` the hook and never call an internal
  function** — the reasoning is invariant 3 in
  [`docs/architecture.md`](docs/architecture.md#3-no-test-sources-the-hook-or-calls-an-internal-function).
  The one exception is `hooks/pgrep-scan.awk`, which has its own public
  interface and may be driven with `awk -f`, always under `LC_ALL=C`.
- **A changed or fixed verdict lands as a row in `tests/cases/verdicts.tsv`**
  (`<command>\t<verdict>`), and changed reason text lands as a row in
  `tests/cases/messages.tsv`
  (`<command>\t<field>\t<mode>\t<needle>`). Both columns holding shell text are
  JSON-encoded so quoting and whitespace survive. Adding the row is not
  optional bookkeeping: the tables are the specification, and a fix without one
  regresses the moment someone refactors.
- **Never use a real destructive command as test payload.** Where a test needs
  filler in a payload position — inside a heredoc whose termination is under
  test, in a string being parsed, in a fixture — use an inert marker such as
  `echo PAYLOAD_RAN` and assert on the marker. The whole point of such a test
  is that the parsing assumption might be wrong, and when it is wrong the
  payload runs. The same applies to `rm`, `dd`, `git push` and anything else
  with side effects.

Run the suite with `just test`, or a single file with
`just test tests/scanner.bats`. `run-tests` snapshots the repo's HEAD, config
and index before and after, and fails loudly if the suite mutated the real
repo even when bats exited 0.

## Style

Shellcheck-clean, shfmt-formatted bash throughout, with one deliberate split:

- **`hooks/` and `tests/*.bats` use POSIX short flags** (`mkdir -p -m 0700`,
  `rm -f`, `mv -f`). Everything else — `.ci/`, `run-all-checks`, `run-tests`,
  `.githooks/`, `.justfile`, the workflows — uses GNU long options.
- **`hooks/` must never set `shopt -s inherit_errexit`**, and the
  `repeat_reason="$(repeat_check ...)" || repeat_reason=''` assignment in `main`
  must never become a plain one.

Both look like inconsistencies and are not; the reasons are invariants 1 and 2
in [`docs/architecture.md`](docs/architecture.md#design-invariants). Read that
section before you tidy either one.

Prose in Markdown wraps at roughly 80 columns, matching the README.

## Reporting a bug or a false verdict

A denied command that was safe, or an allowed command that should have been
denied, is a bug worth reporting. Use the issue forms:

<https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/new/choose>

Include the exact command verbatim — quoting and whitespace both matter, since
the guard tokenizes the string — the hook's JSON output, and your platform with
`bash --version` and `awk --version`. The README's reproduction recipe captures
the first two in one command.

**A guard bypass is a public issue, not a private report.** A command shape
that slips through is a false negative in a heuristic, not a vulnerability, and
filing it publicly is what turns it into a test row. See
[`SECURITY.md`](SECURITY.md) for what does belong in a private report.

## Licensing

There is no CLA and no DCO. Inbound contributions are accepted under the
repository's [MIT license](LICENSE), the same terms the project is distributed
under.
