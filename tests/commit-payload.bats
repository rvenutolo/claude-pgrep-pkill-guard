# `run --separate-stderr` is a bats 1.5.0 flag, and the error cases below need
# stdout and stderr apart: the contract is a diagnostic on stderr and NOTHING
# on stdout, which a merged capture cannot tell apart from a payload.
bats_require_minimum_version 1.5.0

setup() {
  load 'test_helper/common'
  BUILD="${REPO_DIR}/.ci/build-commit-payload"

  # Every .ci/ script is devShell-only by contract -- run-all-checks, the
  # .justfile recipes and the workflows all reach them through .ci/in-devshell
  # -- and this one reads blobs through GNU `base64 --wrap=0`. The two ambient
  # compat legs run this suite against whatever the runner ships, and macOS
  # ships BSD base64, which has no --wrap at all. Skipping there is honest:
  # the hermetic leg is the one that grades this script, and a test that
  # quietly rewrote the invocation to something BSD accepts would be grading a
  # command the script never runs.
  if ! printf '' | base64 --wrap=0 > /dev/null 2>&1; then
    skip 'base64 has no --wrap (BSD coreutils); .ci/ scripts are graded inside the devShell'
  fi
}

# @description Build a throwaway git repo holding one seed commit with two
#              files, so each case can stage exactly the change it is about.
#              POSIX short flags on purpose: the compat CI legs run this suite
#              against macOS BSD coreutils, whose mkdir has no --parents.
#
#              Identity is passed with `-c` rather than written with
#              `git config`, because test_helper/common points
#              GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM at /dev/null -- a commit
#              with no resolvable identity fails outright.
# @arg $1 root directory to create the repo in
function make_repo() {
  local -r root="$1"
  mkdir -p "${root}"
  git -c init.defaultBranch=main init -q "${root}"
  printf 'alpha\n' > "${root}/alpha.txt"
  printf 'beta\n' > "${root}/beta.txt"
  git -C "${root}" add alpha.txt beta.txt
  git -C "${root}" -c user.email='tests@example.invalid' -c user.name='Tests' commit -q -m 'seed'
}

# @description Run the payload builder with the fixture repo as the working
#              directory. The script takes no repo argument by design -- it
#              reads the index of wherever it is invoked -- so the cd is the
#              fixture selection.
# @arg $1 root the fixture repo
# @arg $@ args the script's own arguments
# @stdout the payload
function build_in() {
  local -r root="$1"
  shift
  (cd "${root}" && "${BUILD}" "$@")
}

# @description Encode stdin as unwrapped base64, portably. Asserting on the
#              ENCODING of the expected bytes rather than decoding the emitted
#              string is deliberate: GNU base64 decodes with --decode/-d and
#              BSD base64 with -D, and this helper has to work on both compat
#              legs. Encode-and-compare proves the same thing.
# @noargs
# @stdout one line of base64, no wrapping
function b64() {
  base64 | tr -d '\n'
}

# @description Read one jq path out of the payload last produced by `run`.
# @arg $1 filter a jq path expression
# @stdout the raw value
function field() {
  jq --raw-output "$1" <<< "${output}"
}

@test "commit payload: a modified file becomes one additions entry" {
  local -r root="${BATS_TEST_TMPDIR}/modified"
  make_repo "${root}"
  printf 'alpha changed\n' > "${root}/alpha.txt"
  git -C "${root}" add alpha.txt

  run build_in "${root}" 'owner/name' 'topic' 'chore: reformat'
  assert_success
  assert_equal "$(field '.variables.input.fileChanges.additions | length')" '1'
  assert_equal "$(field '.variables.input.fileChanges.additions[0].path')" 'alpha.txt'
  assert_equal "$(field '.variables.input.fileChanges.additions[0].contents')" \
    "$(printf 'alpha changed\n' | b64)"
  assert_equal "$(field '.variables.input.fileChanges.deletions | length')" '0'
}

@test "commit payload: a new file becomes one additions entry" {
  local -r root="${BATS_TEST_TMPDIR}/added"
  make_repo "${root}"
  printf 'brand new\n' > "${root}/gamma.txt"
  git -C "${root}" add gamma.txt

  run build_in "${root}" 'owner/name' 'topic' 'chore: reformat'
  assert_success
  assert_equal "$(field '.variables.input.fileChanges.additions | length')" '1'
  assert_equal "$(field '.variables.input.fileChanges.additions[0].path')" 'gamma.txt'
  assert_equal "$(field '.variables.input.fileChanges.additions[0].contents')" \
    "$(printf 'brand new\n' | b64)"
  assert_equal "$(field '.variables.input.fileChanges.deletions | length')" '0'
}

@test "commit payload: a deleted file becomes one deletions entry and no additions" {
  local -r root="${BATS_TEST_TMPDIR}/deleted"
  make_repo "${root}"
  git -C "${root}" rm -q beta.txt

  run build_in "${root}" 'owner/name' 'topic' 'chore: reformat'
  assert_success
  assert_equal "$(field '.variables.input.fileChanges.additions | length')" '0'
  assert_equal "$(field '.variables.input.fileChanges.deletions | length')" '1'
  assert_equal "$(field '.variables.input.fileChanges.deletions[0].path')" 'beta.txt'
}

@test "commit payload: an add, a modify and a delete land in the right two lists" {
  local -r root="${BATS_TEST_TMPDIR}/mixed"
  make_repo "${root}"
  printf 'alpha changed\n' > "${root}/alpha.txt"
  printf 'brand new\n' > "${root}/gamma.txt"
  git -C "${root}" add alpha.txt gamma.txt
  git -C "${root}" rm -q beta.txt

  run build_in "${root}" 'owner/name' 'topic' 'chore: reformat'
  assert_success
  assert_equal "$(field '[.variables.input.fileChanges.additions[].path] | sort | join(",")')" \
    'alpha.txt,gamma.txt'
  assert_equal "$(field '[.variables.input.fileChanges.deletions[].path] | join(",")')" 'beta.txt'
  # The deleted path must not also show up as an addition, and vice versa: a
  # status letter landing in both lists is the failure mode that makes GitHub
  # reject the whole mutation.
  assert_equal "$(field '.variables.input.fileChanges.additions | length')" '2'
  assert_equal "$(field '.variables.input.fileChanges.deletions | length')" '1'
}

@test "commit payload: a rename decomposes into a delete plus an add" {
  local -r root="${BATS_TEST_TMPDIR}/renamed"
  make_repo "${root}"
  git -C "${root}" mv alpha.txt renamed.txt

  run build_in "${root}" 'owner/name' 'topic' 'chore: reformat'
  assert_success
  assert_equal "$(field '[.variables.input.fileChanges.additions[].path] | join(",")')" 'renamed.txt'
  assert_equal "$(field '[.variables.input.fileChanges.deletions[].path] | join(",")')" 'alpha.txt'
  assert_equal "$(field '.variables.input.fileChanges.additions[0].contents')" \
    "$(printf 'alpha\n' | b64)"
}

@test "commit payload: non-ASCII content round-trips byte for byte" {
  local -r root="${BATS_TEST_TMPDIR}/utf8"
  make_repo "${root}"
  # No trailing newline, so a base64 that quietly picked up one from the
  # command substitution would show up here rather than pass by luck.
  printf 'héllo wörld — ünïcode' > "${root}/alpha.txt"
  git -C "${root}" add alpha.txt

  run build_in "${root}" 'owner/name' 'topic' 'chore: reformat'
  assert_success
  assert_equal "$(field '.variables.input.fileChanges.additions[0].contents')" \
    "$(printf 'héllo wörld — ünïcode' | b64)"
}

@test "commit payload: a path containing a space is carried intact" {
  local -r root="${BATS_TEST_TMPDIR}/spaced"
  make_repo "${root}"
  printf 'spaced\n' > "${root}/a file.txt"
  git -C "${root}" add 'a file.txt'

  run build_in "${root}" 'owner/name' 'topic' 'chore: reformat'
  assert_success
  assert_equal "$(field '.variables.input.fileChanges.additions | length')" '1'
  assert_equal "$(field '.variables.input.fileChanges.additions[0].path')" 'a file.txt'
}

@test "commit payload: expectedHeadOid is the fixture's HEAD" {
  local -r root="${BATS_TEST_TMPDIR}/head-oid"
  make_repo "${root}"
  printf 'alpha changed\n' > "${root}/alpha.txt"
  git -C "${root}" add alpha.txt

  run build_in "${root}" 'owner/name' 'topic' 'chore: reformat'
  assert_success
  assert_equal "$(field '.variables.input.expectedHeadOid')" "$(git -C "${root}" rev-parse HEAD)"
}

@test "commit payload: repo and branch arguments reach the branch input" {
  local -r root="${BATS_TEST_TMPDIR}/branch"
  make_repo "${root}"
  printf 'alpha changed\n' > "${root}/alpha.txt"
  git -C "${root}" add alpha.txt

  run build_in "${root}" 'rvenutolo/claude-pgrep-pkill-guard' 'release-please--branches--main' \
    'chore: reformat'
  assert_success
  assert_equal "$(field '.variables.input.branch.repositoryNameWithOwner')" \
    'rvenutolo/claude-pgrep-pkill-guard'
  assert_equal "$(field '.variables.input.branch.branchName')" 'release-please--branches--main'
}

@test "commit payload: the headline argument reaches the message input" {
  local -r root="${BATS_TEST_TMPDIR}/headline"
  make_repo "${root}"
  printf 'alpha changed\n' > "${root}/alpha.txt"
  git -C "${root}" add alpha.txt

  run build_in "${root}" 'owner/name' 'topic' \
    'chore: apply repo formatting to the release-please output'
  assert_success
  assert_equal "$(field '.variables.input.message.headline')" \
    'chore: apply repo formatting to the release-please output'
}

@test "commit payload: nothing staged is an error, not an empty payload" {
  local -r root="${BATS_TEST_TMPDIR}/clean"
  make_repo "${root}"

  run --separate-stderr build_in "${root}" 'owner/name' 'topic' 'chore: reformat'
  assert_failure
  # Nothing on stdout: a caller piping straight into `gh api graphql --input -`
  # must not receive a half-formed document alongside the failure.
  assert_equal "${output}" ''
  [[ "${stderr}" == *'nothing staged'* ]]
}

@test "commit payload: the wrong argument count is a usage error" {
  run --separate-stderr "${BUILD}" 'owner/name' 'topic'
  assert_failure
  assert_equal "${output}" ''
  [[ "${stderr}" == 'usage: '* ]]
}

@test "commit payload: the document is valid JSON naming createCommitOnBranch" {
  local -r root="${BATS_TEST_TMPDIR}/shape"
  make_repo "${root}"
  printf 'alpha changed\n' > "${root}/alpha.txt"
  git -C "${root}" add alpha.txt

  run build_in "${root}" 'owner/name' 'topic' 'chore: reformat'
  assert_success
  # `jq type` on the whole document is the parse: a payload that is not JSON
  # fails here rather than at `gh api graphql`, three minutes into a release.
  assert_equal "$(field 'type')" 'object'
  assert_equal "$(field '.variables | type')" 'object'
  [[ "$(field '.query')" == *'createCommitOnBranch'* ]]
}

@test "commit payload: outside a git repo is an error" {
  local -r root="${BATS_TEST_TMPDIR}/not-a-repo"
  mkdir -p "${root}"

  run --separate-stderr build_in "${root}" 'owner/name' 'topic' 'chore: reformat'
  assert_failure
  assert_equal "${output}" ''
  [[ "${stderr}" == *'not a git repo'* ]]
}

@test "commit payload: a file larger than the argv limit still round-trips" {
  local -r root="${BATS_TEST_TMPDIR}/large"
  make_repo "${root}"
  # ~208 KiB of inert, deterministic filler. Comfortably past the ~96 KiB of
  # source that base64's 4/3 inflation puts against Linux's 128 KiB
  # MAX_ARG_STRLEN, and small enough not to slow the suite. Inert on purpose:
  # this is a payload position, and payload positions never hold anything with
  # side effects.
  local -r big="${root}/big.txt"
  local line
  line="$(printf 'PAYLOAD_FILLER_%060d' 0)"
  local i=0
  : > "${big}"
  while [ "${i}" -lt 2800 ]; do
    printf '%s\n' "${line}" >> "${big}"
    i=$((i + 1))
  done
  [ "$(wc -c < "${big}")" -gt 131072 ]

  git -C "${root}" add big.txt
  run build_in "${root}" 'owner/name' 'topic' 'chore: reformat'
  assert_success

  # The emitted base64 must decode back to exactly the staged bytes. Compared by
  # RE-ENCODING the expected bytes rather than decoding the emitted string:
  # GNU base64 decodes with --decode and BSD with -D, and this suite runs on
  # both compat legs. Compared with `[` rather than assert_equal so a mismatch
  # does not dump a quarter of a megabyte of base64 into the failure report.
  local emitted expected
  emitted="$(field '.variables.input.fileChanges.additions[0].contents')"
  expected="$(b64 < "${big}")"
  [ "${emitted}" = "${expected}" ]
}
