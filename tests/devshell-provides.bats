setup() {
  load 'test_helper/common'
  CHECK="${REPO_DIR}/.ci/check-devshell-provides"
}

# @description Build a minimal, VALID fixture inventory: one package justified
#              by a declared tool and one justified only by being a treefmt
#              formatter, so each negative case can corrupt exactly one thing.
#              POSIX short flags on purpose: the compat CI legs run this suite
#              against macOS BSD coreutils, whose mkdir has no --parents.
# @arg $1 root directory to populate
function make_devshell_fixture() {
  local -r root="$1"
  mkdir -p "${root}"
  make_package "${root}" 'jq' 'out' 'jq'
  make_package "${root}" 'prettier' 'out'
  # The indented entry and the comment/blank line together assert that the
  # parser strips per line -- stripping whitespace over the whole stream would
  # eat the newlines and collapse the list into one bogus entry.
  cat > "${root}/required-tools" << 'TOOLS'
# A comment, and a blank line below, both of which the parser must ignore.

  jq
TOOLS
  write_inventory "${root}" 'jq' 'prettier'
  printf '%s/bin/prettier\n' "$(package_out "${root}" 'prettier')" \
    > "${root}/formatters.txt"
}

# @description Create a fake package tree with one output and zero or more
#              executables in its bin/.
# @arg $1 root fixture root
# @arg $2 name package name
# @arg $3 output output name, e.g. out or dev
# @arg $@ binaries executables to place in that output's bin/
function make_package() {
  local -r root="$1"
  local -r name="$2"
  local -r output="$3"
  shift 3
  local -r dir="${root}/store/${name}-${output}"
  mkdir -p "${dir}/bin"
  local binary
  for binary in "$@"; do
    printf '#!/bin/sh\nexit 0\n' > "${dir}/bin/${binary}"
    chmod +x "${dir}/bin/${binary}"
  done
}

# @description Print the path of a package's `out` output.
# @arg $1 root fixture root
# @arg $2 name package name
function package_out() {
  printf '%s/store/%s-out' "$1" "$2"
}

# @description Write packages.tsv, one row per named package, each with a single
#              `out` output.
# @arg $1 root fixture root
# @arg $@ names package names
function write_inventory() {
  local -r root="$1"
  shift
  local name
  : > "${root}/packages.tsv"
  for name in "$@"; do
    printf '%s\t%s\n' "${name}" "$(package_out "${root}" "${name}")" \
      >> "${root}/packages.tsv"
  done
}

# @description Prepend every fixture package's bin/ to PATH, so both passes
#              resolve declared tools to the fixture instead of the real
#              devShell. This is what lets a fixture exercise the same code the
#              real run takes rather than a separate branch.
# @arg $1 root fixture root
function use_fixture_path() {
  local -r root="$1"
  local dir
  for dir in "${root}"/store/*/bin; do
    if [ -d "${dir}" ]; then
      PATH="${dir}:${PATH}"
    fi
  done
  export PATH
}

# Every case below drives FIXTURE mode, which never invokes Nix -- so this suite
# needs no devShell and deliberately carries no skip, the same as
# tests/issue-forms.bats. It therefore runs on the ambient compat legs too. If a
# future change makes the script genuinely unrunnable there, add a capability
# probe for that specific thing, the way tests/commit-payload.bats probes for
# `base64 --wrap`; do not reach for a blanket skip, which surrenders the whole
# suite for a hypothetical.
#
# Nothing here drives the argument-less REAL mode, so be plain about the split:
# the two Nix expressions have no coverage in this suite at all. They are graded
# by run-all-checks, which runs the argument-less gate on every gate run, locally
# at pre-push and on both CI gate legs.
#
# That is a deliberate omission rather than an oversight. bats prepends its own
# libexec to PATH, so inside a test `command -v bats` resolves to the unwrapped
# bats rather than to the bats.withLibraries output the devShell ships, and the
# check then reports that package as justifying nothing. It is right to say so:
# the PATH it was handed really does not contain that output. The verdict would
# be an artifact of the harness, and a test asserting around it would only pin
# bats' PATH behaviour.

@test "devshell provides: a valid fixture passes" {
  make_devshell_fixture "${BATS_TEST_TMPDIR}/ok"
  use_fixture_path "${BATS_TEST_TMPDIR}/ok"
  run "${CHECK}" "${BATS_TEST_TMPDIR}/ok"
  assert_success
}

@test "devshell provides: a package justifying nothing is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/dead"
  make_devshell_fixture "${root}"
  make_package "${root}" 'cowsay' 'out' 'cowsay'
  write_inventory "${root}" 'jq' 'prettier' 'cowsay'
  use_fixture_path "${root}"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'devShell package justifies nothing: cowsay'
}

@test "devshell provides: a package is justified by a non-default output" {
  # The trap this exists for: a package's binaries need not live in its default
  # output -- jq, nix and ShellCheck all ship theirs elsewhere. The resolved
  # tool path must be attributed against EVERY output, not just the first.
  local -r root="${BATS_TEST_TMPDIR}/multi-output"
  make_devshell_fixture "${root}"
  make_package "${root}" 'ripgrep' 'dev'
  make_package "${root}" 'ripgrep' 'out' 'rg'
  printf 'rg\n' >> "${root}/required-tools"
  write_inventory "${root}" 'jq' 'prettier'
  printf 'ripgrep\t%s\t%s\n' "${root}/store/ripgrep-dev" \
    "${root}/store/ripgrep-out" >> "${root}/packages.tsv"
  use_fixture_path "${root}"
  run "${CHECK}" "${root}"
  assert_success
}

@test "devshell provides: a package is justified only by backing a formatter" {
  # prettier ships no declared tool; it passes solely because formatters.txt
  # places a treefmt formatter command inside its output.
  local -r root="${BATS_TEST_TMPDIR}/formatter-only"
  make_devshell_fixture "${root}"
  use_fixture_path "${root}"
  run "${CHECK}" "${root}"
  assert_success

  : > "${root}/formatters.txt"
  use_fixture_path "${root}"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'devShell package justifies nothing: prettier'
}

@test "devshell provides: a formatter under a different store path does not justify" {
  local -r root="${BATS_TEST_TMPDIR}/foreign-formatter"
  make_devshell_fixture "${root}"
  printf '%s/store/elsewhere-out/bin/prettier\n' "${root}" > "${root}/formatters.txt"
  use_fixture_path "${root}"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'devShell package justifies nothing: prettier'
}

@test "devshell provides: a non-executable file in bin/ does not justify" {
  local -r root="${BATS_TEST_TMPDIR}/not-executable"
  make_devshell_fixture "${root}"
  chmod -x "$(package_out "${root}" 'jq')/bin/jq"
  use_fixture_path "${root}"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'devShell package justifies nothing: jq'
}

@test "devshell provides: an empty tool list is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/no-tools"
  make_devshell_fixture "${root}"
  printf '# every line here is a comment\n\n' > "${root}/required-tools"
  use_fixture_path "${root}"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'no tools declared in'
}

@test "devshell provides: an empty package inventory is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/no-packages"
  make_devshell_fixture "${root}"
  : > "${root}/packages.tsv"
  use_fixture_path "${root}"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'the devShell declares no packages'
}

@test "devshell provides: an unreadable inventory fails rather than reading empty" {
  # The inventory is fetched through a command substitution precisely so this
  # cannot pass: an unreadable source must surface as a failure, never as an
  # empty package list that the reverse pass would find nothing wrong with.
  local -r root="${BATS_TEST_TMPDIR}/no-inventory"
  make_devshell_fixture "${root}"
  rm -f "${root}/packages.tsv"
  use_fixture_path "${root}"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'could not read the devShell package inventory'
  refute_output --partial 'declares no packages'
}

@test "devshell provides: a missing tools file is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/no-file"
  make_devshell_fixture "${root}"
  rm -f "${root}/required-tools"
  use_fixture_path "${root}"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'is missing or unreadable'
}
