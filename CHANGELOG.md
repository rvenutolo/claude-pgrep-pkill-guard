# Changelog

## 1.0.0 (2026-08-28)


### Features

* add plugin, marketplace and hook manifests ([c89bebd](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/c89bebda6ae7f95fa6544e53870a7e2dc97baa02))
* import guard hook and plugin manifests ([df27581](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/df27581c3231545ec9b739d8385ed9e3f604d4d3))
* import the pgrep/pkill guard hook and scanner ([2b8fa01](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/2b8fa01c16f2eb7dcb7c8bc7473a5e2794839b10))


### Bug Fixes

* give body_has_terminator a command-substitution scope barrier ([f845e6d](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/f845e6d6930eeec8a3f17e438981da5acbe3565b))
* give body_has_terminator a command-substitution scope barrier ([5311b34](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/5311b34554e1ae5cd42f1aa3b9a580fa26700e69)), closes [#8](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/8)
* make pgrep-scan.awk independent of RS so one-true-awk works unaided ([17cb928](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/17cb928776dcbf39e5095b03286f59bfd3d14a2b))
* make pgrep-scan.awk independent of RS so one-true-awk works unaided ([bb1c2dc](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/bb1c2dc9d2469b40554ab79d0387a251d770d8b1)), closes [#7](https://github.com/rvenutolo/claude-pgrep-pkill-guard/issues/7)
* make the guard portable and rename it ([134e939](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/134e93997b5c5c6e26c3649e2d70809079b75eb4))
* reject a pre-4.2 host bash in .ci/in-devshell ([b7c3c32](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/b7c3c3291e657617cd98f94facd95f63e5078b5f))
* report INACTIVE loudly when bash is older than 4.3 ([3e9a3dd](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/3e9a3dd737a52ad3eace051d470f17669b4a8316))
* use POSIX short flags in the guard for macOS support ([ee45d68](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/ee45d68ba99a4b9f2eb2daa364077b549512109b))
* use the security category and sync the marketplace version ([a2f54a6](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/a2f54a626b2a5d46c50fd7ab87878bc383758005))
* verify scanner integrity in-band instead of via the ERR trap ([5e3264f](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/5e3264f357cf110670a0d0868d7e99416a3075ea))


### Continuous Integration

* add release-please, commitlint and renovate ([31feb1d](https://github.com/rvenutolo/claude-pgrep-pkill-guard/commit/31feb1d796bf66dd1392cb28907f43b52a61ba1e))
