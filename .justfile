# Run the default gate
default: check

# Run the full local verification gate
check:
    ./.ci/in-devshell ./run-all-checks

# Run the BATS suite
test *ARGS:
    ./.ci/in-devshell ./run-tests {{ARGS}}

# Run the config/markup/shell lint suite
lint:
    ./.ci/in-devshell ./.ci/run-lint-checks

# Validate both plugin manifests with the Claude Code CLI, when it is installed
validate:
    ./.ci/run-plugin-validate

# Format every file via treefmt
format:
    nix fmt

# Verify formatting without writing changes
format-check:
    nix flake check --no-eval-cache

# Activate the tracked git hooks for this clone
hooks:
    ./.ci/activate-githooks

# Add this working copy as a local marketplace, for dogfooding
install:
    @echo "In Claude Code, run:"
    @echo "  /plugin marketplace add {{justfile_directory()}}"
    @echo "  /plugin install pgrep-pkill-guard@rvenutolo"
