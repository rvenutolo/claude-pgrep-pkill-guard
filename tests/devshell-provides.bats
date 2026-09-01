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

@test "devshell provides: the real devShell and required-tools agree" {
  # The argument-less path is the only one that consults Nix, so unlike the
  # other gates' suites this cannot be left to run-all-checks alone -- fixture
  # mode never evaluates the flake and would not notice a broken expression.
  run "${CHECK}"
  assert_success
}

@test "devshell provides: a valid fixture passes" {
  make_devshell_fixture "${BATS_TEST_TMPDIR}/ok"
  run "${CHECK}" "${BATS_TEST_TMPDIR}/ok"
  assert_success
}

@test "devshell provides: a package justifying nothing is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/dead"
  make_devshell_fixture "${root}"
  make_package "${root}" 'cowsay' 'out' 'cowsay'
  write_inventory "${root}" 'jq' 'prettier' 'cowsay'
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'devShell package justifies nothing: cowsay'
}

@test "devshell provides: a package is justified by a non-default output" {
  # The trap this exists for: `toString pkg` is the DEFAULT output, which for
  # jq, nix and ShellCheck is -dev and holds no bin/ at all. A reverse pass that
  # scanned only that output would call all three dead packages.
  local -r root="${BATS_TEST_TMPDIR}/multi-output"
  make_devshell_fixture "${root}"
  make_package "${root}" 'ripgrep' 'dev'
  make_package "${root}" 'ripgrep' 'out' 'rg'
  printf 'rg\n' >> "${root}/required-tools"
  write_inventory "${root}" 'jq' 'prettier'
  printf 'ripgrep\t%s\t%s\n' "${root}/store/ripgrep-dev" \
    "${root}/store/ripgrep-out" >> "${root}/packages.tsv"
  run "${CHECK}" "${root}"
  assert_success
}

@test "devshell provides: a package is justified only by backing a formatter" {
  # prettier ships no declared tool; it passes solely because formatters.txt
  # places a treefmt formatter command inside its output.
  local -r root="${BATS_TEST_TMPDIR}/formatter-only"
  make_devshell_fixture "${root}"
  run "${CHECK}" "${root}"
  assert_success

  : > "${root}/formatters.txt"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'devShell package justifies nothing: prettier'
}

@test "devshell provides: a formatter under a different store path does not justify" {
  local -r root="${BATS_TEST_TMPDIR}/foreign-formatter"
  make_devshell_fixture "${root}"
  printf '%s/store/elsewhere-out/bin/prettier\n' "${root}" > "${root}/formatters.txt"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'devShell package justifies nothing: prettier'
}

@test "devshell provides: a non-executable file in bin/ does not justify" {
  local -r root="${BATS_TEST_TMPDIR}/not-executable"
  make_devshell_fixture "${root}"
  chmod -x "$(package_out "${root}" 'jq')/bin/jq"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'devShell package justifies nothing: jq'
}

@test "devshell provides: an empty tool list is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/no-tools"
  make_devshell_fixture "${root}"
  printf '# every line here is a comment\n\n' > "${root}/required-tools"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'no tools declared in'
}

@test "devshell provides: an empty package inventory is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/no-packages"
  make_devshell_fixture "${root}"
  : > "${root}/packages.tsv"
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
  run "${CHECK}" "${root}"
  assert_failure
}

@test "devshell provides: a missing tools file is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/no-file"
  make_devshell_fixture "${root}"
  rm -f "${root}/required-tools"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'is missing or unreadable'
}
