# Changelog

## [1.1.0](https://github.com/rvenutolo/claude-pgrep-pkill-guard/compare/v1.0.0...v1.1.0) (2026-09-05)

### Features

- add --help and --version to the guard's entry script ([dd72a4c](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/dd72a4c732e46d4cfdc5b06cdfb694b56310ea8b)), closes [#34](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/34)
- add --help and --version to the guard's entry script ([#60](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/60)) ([0a7ee36](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/0a7ee36f437f0381ecdc06b9b6d891e7eef9b96e))
- add a just fix recipe that runs every auto-fixer ([69492d8](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/69492d82e04dd7c0d3a4c0742e9ce70c03e525af))
- add a social preview card and the script that builds it ([48d34fb](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/48d34fb5bf7b524c0036d071d06e101acfc444b3)), closes [#35](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/35)
- add a social preview card and the script that builds it ([#66](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/66)) ([0454908](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/04549084b4c48fb5cf5842bc9b6cedc0bab43ebd))
- record machine state in benchmark provenance and regenerate ([#119](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/119)) ([58573d7](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/58573d7219fdb5a10384353ab958f015bfd55db3))
- record machine state in the benchmark provenance table ([ffc95d6](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/ffc95d62fbae45a382ad2c78195e18c2d34b859d))

### Bug Fixes

- create the release formatting commit through the API ([83cd6ce](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/83cd6cea53e70feff6c5387158cd21336b29f331)), closes [#70](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/70)
- create the release formatting commit through the API ([#95](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/95)) ([a32b475](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/a32b475b3edccd2a26d1f7889b5946791d696428)), closes [#70](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/70)
- create the report directory with a POSIX mkdir -p ([56ece02](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/56ece0206ffb8ad458d3dcfa1de8a03d68f3d228))
- exclude renovate's Handlebars template from the link check ([c357f34](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/c357f340272a84f0152ee5b35a29853d6c13e32f))
- exclude the changelog release compare link from the link check ([#99](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/99)) ([720137a](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/720137af01397d3e9893e083d739399b0541ec4f)), closes [#98](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/98)
- exclude the changelog's release compare link from the link check ([c416b1f](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/c416b1f7473f07d064c829d826c65c12f3cd42b4)), closes [#98](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/98)
- guard the scanner's trailing-newline strip on empty input ([ec5f5be](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/ec5f5be0c85dc97c9fea6982e9bb96bf4b9cd21a))
- make renovate's bats manager resolve, and gate the config ([#102](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/102)) ([a639e44](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/a639e4442950065c4383ad4e65ccb406efa789de))
- pass commit blobs to jq through files, not argv ([73ec72a](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/73ec72ab03be70af065168bac1733a79745df089)), closes [#94](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/94)
- pass commit payload blobs to jq through files, not argv ([#124](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/124)) ([f576fbf](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/f576fbff5238c3e04a911e7d04f624d32ac67d8b))
- pin nix in the devShell and justify packages by PATH, not by scan ([e37df97](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/e37df973f07f7b1bd5f8d893ca81a9d26b29bbfd))
- refuse to report a coverage run that lost a file, and say why ([#129](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/129)) ([4db7fb1](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/4db7fb1b79619cda7b218c45b2e23b2c80511d4c))
- refuse to report a coverage run that lost a hooks file ([61484a8](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/61484a88c562fecc3eb3231559137fc4869a2a91)), closes [#128](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/128)
- resolve the bats pins with git-refs instead of github-tags ([0018fb8](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/0018fb87d548c2019efd0ef607d3b102f649e3a5)), closes [#71](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/71)
- skip the --awk=bwk cases when nawk is not one-true-awk ([4e14292](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/4e14292c9d8708ea379261dae0fc93209f7f1ba3))
- skip the devShell suite ambiently and report eval failure honestly ([988828f](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/988828fe3088d62f2839b542fa0ba0002e4605e6))
- stop the ERR trap reporting a gate's own deliberate failure ([c838df7](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/c838df74c9b7ac4c94eaf6e5398e50b484be081f)), closes [#43](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/43)
- stop the ERR trap reporting a gate's own deliberate failure ([#63](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/63)) ([3d63266](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/3d63266ebb8dd903f99c02003bfdec62cccfcd1b))
- stop the link checker failing on prose that quotes its own patterns ([d653b51](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/d653b516b27287530f7d051f93ea47a398426b54))
- stop the release job failing when there is nothing to release ([a78fda0](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/a78fda034ff945b518f5d5bb00f15dd85165fc81)), closes [#103](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/103)
- stop the release job failing when there is nothing to release ([#104](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/104)) ([e28f2e2](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/e28f2e2ecf062b7366beb63620eb2b341d722cd6))
- stop typos rejecting the SHAs release-please writes to the changelog ([65634bd](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/65634bd92f5f28b18cbe9a88e04de6308ff2e649)), closes [#61](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/61)
- stop typos rejecting the SHAs release-please writes to the changelog ([#62](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/62)) ([1036ee1](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/1036ee1ecc5c9c93381bcdef37674c12da3f2756))
- strip any trailing newline from a staged base64 blob ([07d2be4](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/07d2be469b2f899f2c878bb4f280bd3a35d93b6e)), closes [#94](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/94)

### Performance Improvements

- **bench:** measure a typical-command cohort, not just the corpus ([21d966f](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/21d966f1af10113951e373a7aef3565b8622bc20))
- **bench:** republish the per-call cost after the prefilter ([944fbc2](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/944fbc2ba01a7c0fb83e0363632d8291549e542c))
- **bench:** split the prefilter short-circuit into its own cohort ([ffe393a](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/ffe393a215bf134d56c6f3d07a51a992f5219e34))
- drop the two helper spawns from the hook's fast path ([17dcd50](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/17dcd508559302c277e4616fb1f99bb2b5ae5d1c)), closes [#54](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/54)
- drop the two helper spawns from the hook's fast path ([#56](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/56)) ([281521f](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/281521fa3058a53500b528056fc8e98e2c0f073a))
- micro-benchmark the hook and publish the per-call cost ([#48](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/48)) ([8ebdebc](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/8ebdebcfb841ec7ff2da550e39c8bc042bb19541))
- short-circuit the hook before the jq and awk spawns ([3abe9ce](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/3abe9cefeea89e83e3621ddc9039d0f37ae4d502))
- short-circuit the hook before the jq and awk spawns ([#53](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/53)) ([39de1bf](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/39de1bf6092df4f81bdf6aab4c84eac478f0bd7a))
- split the guard so the fast path parses 152 lines, not 2203 ([6fa70a0](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/6fa70a012aee392c32b0fea2bf3022079afb0f21)), closes [#55](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/55)
- split the guard so the fast path parses 152 lines, not 2203 ([#57](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/57)) ([33ba166](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/33ba16607942084201e9f1b140daf95488d1a68f))

## 1.0.0 (2026-08-28)

### Features

- add plugin, marketplace and hook manifests ([c89bebd](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/c89bebda6ae7f95fa6544e53870a7e2dc97baa02))
- import guard hook and plugin manifests ([df27581](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/df27581c3231545ec9b739d8385ed9e3f604d4d3))
- import the pgrep/pkill guard hook and scanner ([2b8fa01](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/2b8fa01c16f2eb7dcb7c8bc7473a5e2794839b10))

### Bug Fixes

- give body_has_terminator a command-substitution scope barrier ([f845e6d](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/f845e6d6930eeec8a3f17e438981da5acbe3565b))
- give body_has_terminator a command-substitution scope barrier ([5311b34](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/5311b34554e1ae5cd42f1aa3b9a580fa26700e69)), closes [#8](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/8)
- make pgrep-scan.awk independent of RS so one-true-awk works unaided ([17cb928](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/17cb928776dcbf39e5095b03286f59bfd3d14a2b))
- make pgrep-scan.awk independent of RS so one-true-awk works unaided ([bb1c2dc](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/bb1c2dc9d2469b40554ab79d0387a251d770d8b1)), closes [#7](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/7)
- make the guard portable and rename it ([134e939](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/134e93997b5c5c6e26c3649e2d70809079b75eb4))
- reject a pre-4.2 host bash in .ci/in-devshell ([b7c3c32](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/b7c3c3291e657617cd98f94facd95f63e5078b5f))
- report INACTIVE loudly when bash is older than 4.3 ([3e9a3dd](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/3e9a3dd737a52ad3eace051d470f17669b4a8316))
- use POSIX short flags in the guard for macOS support ([ee45d68](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/ee45d68ba99a4b9f2eb2daa364077b549512109b))
- use the security category and sync the marketplace version ([a2f54a6](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/a2f54a626b2a5d46c50fd7ab87878bc383758005))
- verify scanner integrity in-band instead of via the ERR trap ([5e3264f](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/5e3264f357cf110670a0d0868d7e99416a3075ea))

### Continuous Integration

- add release-please, commitlint and renovate ([31feb1d](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/31feb1d796bf66dd1392cb28907f43b52a61ba1e))
