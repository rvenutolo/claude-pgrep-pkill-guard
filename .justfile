# Run the default gate
default: check

# Run the full local verification gate
check:
    ./.ci/in-devshell ./run-all-checks

# Run the BATS suite
test *ARGS:
    ./.ci/in-devshell ./run-tests {{ ARGS }}

# Measure line coverage of hooks/ under the BATS suite, as HTML in DIR
#
# Linux only: nixpkgs' kcov names no darwin platform, so the devShell carries it
# only on Linux (#91). Note that this goes through .ci/in-devshell like every
# other recipe -- possible precisely BECAUSE kcov is a devShell package. It was
# not, while the first probe drove kcov from a `nix shell` outside the boundary,
# and --ignore-environment stripped it back out again.
#
# Open DIR/index.html for the per-line view, which is the part worth reading; the
# headline percentage is a floor, since kcov counts heredoc body lines as
# coverable. See docs/architecture.md, "Line coverage".
#
# Expect ~12000 lines of noise on stderr. kcov forwards every trace line it
# cannot parse, which is every continuation line of a multi-line traced command,
# and the suite's JSON payloads are full of them. bats' TAP is on stdout and is
# unaffected. Redirect stderr if it bothers you; the gate's own coverage step
# does exactly that.
coverage DIR="coverage":
    ./.ci/in-devshell ./run-tests --coverage {{ DIR }}
    ./.ci/in-devshell ./.ci/report-coverage {{ DIR }}

# Re-measure the hook's per-call cost and rewrite bench/RESULTS.md
#
# Two steps, one operation: bench/run emits markdown tables with unpadded
# cells, and prettier owns their alignment (#76). Skipping the second step
# leaves a tree that fails `nix flake check`. `nix fmt` is invoked outside
# in-devshell on purpose -- treefmt-nix supplies prettier from the Nix store
# rather than through PATH, so the devShell has nothing to add here.
bench:
    ./.ci/in-devshell ./bench/run --output bench/RESULTS.md
    nix fmt bench/RESULTS.md

# Fuzz hooks/pgrep-scan.awk with N random inputs, far more than the gate runs
#
# tests/scanner-fuzz.bats runs a few hundred cases as part of the suite, sized so
# the gate does not slow measurably. This recipe is the deliberate session: a
# larger corpus, run on demand, deliberately NOT part of `just check`.
#
# Set FUZZ_SEED to reproduce a corpus; the suite prints the seed it used on every
# run. Anything this finds becomes a hand-written case in tests/scanner.bats --
# the fuzzer's job is to find them, the suite's job is to keep them.
fuzz N="10000":
    FUZZ_N={{ N }} ./.ci/in-devshell ./run-tests tests/scanner-fuzz.bats

# Run the config/markup/shell lint suite
lint:
    ./.ci/in-devshell ./.ci/run-lint-checks

# Validate both plugin manifests with the Claude Code CLI, when it is installed
validate:
    ./.ci/run-plugin-validate

# Check every link in the tracked tree
links:
    ./.ci/in-devshell ./.ci/check-links

# Format every file via treefmt
format:
    nix fmt

# Run every auto-fixer: treefmt, then the fixers treefmt does not drive
fix:
    nix fmt
    ./.ci/in-devshell ./.ci/run-fixers

# Verify formatting without writing changes
format-check:
    nix flake check --no-eval-cache

# Activate the tracked git hooks for this clone
hooks:
    ./.ci/activate-githooks

# Add this working copy as a local marketplace, for dogfooding
install:
    @echo "In Claude Code, run:"
    @echo "  /plugin marketplace add {{ justfile_directory() }}"
    @echo "  /plugin install pgrep-pkill-guard@rvenutolo"
