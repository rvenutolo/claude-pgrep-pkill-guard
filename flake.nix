{
  description = "pgrep-pkill-guard — Claude Code plugin devShell and formatter";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    bats-support = {
      url = "github:bats-core/bats-support";
      flake = false;
    };
    bats-assert = {
      url = "github:bats-core/bats-assert";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      systems,
      treefmt-nix,
      bats-support,
      bats-assert,
    }:
    let
      eachSystem = f: nixpkgs.lib.genAttrs (import systems) (system: f nixpkgs.legacyPackages.${system});
      treefmtEval = eachSystem (pkgs: treefmt-nix.lib.evalModule pkgs ./.treefmt.nix);
      # nixpkgs' unstable-version convention, derived from the input's own
      # lastModifiedDate so a Renovate bump of flake.lock relabels the store path
      # too. A hardcoded date silently goes stale on the first bump.
      unstableVersion =
        input:
        let
          d = input.lastModifiedDate;
        in
        "0-unstable-${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}";
    in
    {
      formatter = eachSystem (pkgs: treefmtEval.${pkgs.stdenv.hostPlatform.system}.config.build.wrapper);

      checks = eachSystem (pkgs: {
        formatting = treefmtEval.${pkgs.stdenv.hostPlatform.system}.config.build.check self;
      });

      devShells = eachSystem (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            # formatters (also wired into treefmt)
            shfmt
            prettier
            yamlfmt
            nixfmt
            # linters
            shellcheck
            yamllint
            markdownlint-cli2
            editorconfig-checker
            typos
            actionlint
            # commitlint is invoked by .githooks/commit-msg. Without it here,
            # check-devshell-provides fails AND every git commit dies with
            # "commitlint: command not found" once activate-githooks has run.
            commitlint
            # tests / runtime
            # withLibraries, not bare bats: the wrapper exports BATS_LIB_PATH at
            # its own share/bats, so common.bash can bats_load_library and a bats
            # that is not this one fails loudly instead of silently missing them.
            # common.bash still honours an externally-set BATS_LIB_PATH so the
            # non-hermetic `compat` CI legs can supply their own copies.
            (bats.withLibraries (l: [
              # From flake INPUTS pinned in flake.lock, not the nixpkgs releases:
              # nixpkgs ships bats-assert 2.1.0, which lacks assert_stderr.
              (l.bats-support.overrideAttrs (_: {
                src = bats-support;
                version = unstableVersion bats-support;
              }))
              (l.bats-assert.overrideAttrs (_: {
                src = bats-assert;
                version = unstableVersion bats-assert;
              }))
            ]))
            # Deliberately NOT util-linux/parallel: `flock` is Linux-only in
            # nixpkgs and referencing it breaks evaluation on aarch64-darwin,
            # which would kill the hermetic macOS gate. bats runs serially.
            jq
            gawk
            git
            gh
            just
            nix
            coreutils
            findutils
            gnugrep
          ];

          # Activate the tracked git hooks for this clone. As a manual per-clone
          # step this silently never happens; the devShell is the one place
          # onboarding cannot skip. Tolerant of failure on purpose.
          shellHook = ''
            if hooks_repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
              "$hooks_repo_root/.ci/activate-githooks" \
                || echo 'warning: could not activate tracked git hooks' >&2
            fi
          '';
        };
      });
    };
}
