{ pkgs, ... }:
{
  projectRootFile = "flake.nix";

  programs = {
    prettier = {
      enable = true;
      includes = [ "*.json" ];
    };
    yamlfmt.enable = true;
    nixfmt.enable = true;
    # treefmt-nix's taplo module runs `taplo format` over *.toml and supplies
    # the package itself, so taplo is not in .ci/required-tools -- same as
    # prettier, yamlfmt and nixfmt. No `taplo lint`: the schema catalogue does
    # not know lychee.toml or .typos.toml, so it would assert nothing.
    taplo.enable = true;
  };

  # shfmt via an explicit entry rather than programs.shfmt: that module hardcodes
  # `-s` (simplify) and options only APPEND, so the flag cannot be dropped. `-s`
  # strips quotes inside `[[ ]]`, contradicting the quote-every-expansion rule
  # and, for `=~`, silently turning a literal match into a regex match.
  #
  # Only --write: shfmt reads .editorconfig for style, but ONLY when given no
  # parser or printer flag. Style lives in .editorconfig; keep it there.
  settings.formatter.shfmt = {
    command = "${pkgs.shfmt}/bin/shfmt";
    options = [ "--write" ];
    includes = [
      "*.sh"
      "*.bash"
      "*.envrc"
    ];
  };

  settings.global.excludes = [
    "flake.lock"
    "LICENSE"
    "*.awk"
    "tests/cases/*.tsv"
  ];
}
