# Run the default gate
default: check

# Run the full local verification gate
check:
    ./.ci/in-devshell ./run-all-checks

# Run the BATS suite
test *ARGS:
    ./.ci/in-devshell ./run-tests {{ ARGS }}

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
