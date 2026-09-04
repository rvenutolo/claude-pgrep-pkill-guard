{ pkgs, ... }:
{
  projectRootFile = "flake.nix";

  programs = {
    prettier = {
      enable = true;
      # `proseWrap: "preserve"` is pinned in .prettierrc.json rather than left
      # to prettier's default. Every doc in this repo is hand-wrapped, and the
      # only thing markdown formatting is wanted for here is table alignment --
      # a prettier that reflowed prose would rewrite every paragraph in the
      # tree on a version bump.
      includes = [
        "*.json"
        "*.md"
      ];
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
  #
  # That rule is why "*.bats" appears in includes with no accompanying
  # `-ln bats`. The bats dialect is the SECOND thing that must come from
  # .editorconfig rather than from argv: `-ln` is a parser flag, so adding it
  # here would switch .editorconfig off wholesale and reindent all eleven bats
  # files to tabs, along with every other file this entry formats. The
  # `[*.bats]` section in .editorconfig carries the dialect instead.
  settings.formatter.shfmt = {
    command = "${pkgs.shfmt}/bin/shfmt";
    options = [ "--write" ];
    includes = [
      "*.sh"
      "*.bash"
      "*.bats"
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
