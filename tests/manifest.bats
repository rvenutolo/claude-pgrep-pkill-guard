# The plugin's manifests -- .claude-plugin/plugin.json and hooks/hooks.json --
# and the files they point at; the entry script's old-bash INACTIVE branch,
# pinned at source level; and .ci/check-manifest-invariants, against the real
# repo and fixtures.
#
# setup sets PLUGIN_JSON and HOOKS_JSON, the paths of the real manifests.

function setup() {
  load 'test_helper/common'
  PLUGIN_JSON="${REPO_DIR}/.claude-plugin/plugin.json"
  HOOKS_JSON="${REPO_DIR}/hooks/hooks.json"
}

@test "manifest: plugin.json and hooks.json are valid JSON" {
  run jq 'empty' "${PLUGIN_JSON}"
  assert_success
  run jq 'empty' "${HOOKS_JSON}"
  assert_success
}

@test "manifest: the plugin is named pgrep-pkill-guard" {
  local plugin_name
  plugin_name="$(jq --raw-output '.name' "${PLUGIN_JSON}")"
  [[ "${plugin_name}" == 'pgrep-pkill-guard' ]]
}

@test "manifest: the hook command invokes the script directly, not via bash" {
  local command
  command="$(jq --raw-output '.hooks.PreToolUse[0].hooks[0].command' "${HOOKS_JSON}")"
  # Direct invocation is load-bearing on macOS: `bash <path>` would resolve to
  # /bin/bash 3.2 and the version guard would deactivate the hook.
  # Not `refute [[ ... ]]`: bats-assert runs its argument as a simple command, so
  # `[[` is not a keyword there -- it would fail to execute and `refute` would
  # pass vacuously. A plain negated `[[ ]]` keeps the assertion live.
  [[ "${command:0:5}" != 'bash ' ]]
  # The single quotes are the point: hooks.json stores the LITERAL text
  # `${CLAUDE_PLUGIN_ROOT}` for Claude Code to expand at hook-dispatch time, so
  # this assertion must compare against the unexpanded string. Double quotes
  # here would expand it in the test's own shell -- to the empty string, since
  # nothing sets it -- and the glob would then match any command at all.
  # Per-site rather than file-level: SC2016 sites are rare in this file.
  # shellcheck disable=SC2016 # `${CLAUDE_PLUGIN_ROOT}` must stay unexpanded here
  [[ "${command}" == *'${CLAUDE_PLUGIN_ROOT}'* ]]
  [[ "${command}" == *'pgrep-pkill-guard.sh' ]]
}

@test "manifest: the hook path in hooks.json exists and is executable" {
  [[ -x "${REPO_DIR}/hooks/pgrep-pkill-guard.sh" ]]
}

@test "manifest: the scanner exists and is NOT executable" {
  [[ -f "${REPO_DIR}/hooks/pgrep-scan.awk" ]]
  [[ ! -x "${REPO_DIR}/hooks/pgrep-scan.awk" ]]
}

@test "inactive: the old-bash branch emits a systemMessage, not a bare {}" {
  # BASH_VERSINFO is read-only, so the branch cannot be driven in-process. The
  # real behaviour is covered by the stock-macOS compat CI leg; this pins the
  # source-level invariant so the branch can never silently regress to `{}`.
  # --after-context=6, not 3: the version guard carries a comment between the
  # condition and the printf, which pushes INACTIVE outside a 3-line window.
  run grep --after-context=6 'BASH_VERSINFO\[0\] < 4' "${HOOK}"
  assert_success
  assert_output --partial 'systemMessage'
  assert_output --partial 'INACTIVE'
  refute_output --partial "printf '{}"
}

@test "inactive: the old-bash branch names a 4.4 floor" {
  # 4.4, not 4.3: bash 4.3 treats expanding an empty array under `set -u` as an
  # unbound-variable error, and the guard expands arrays that can be empty.
  run grep --after-context=6 'BASH_VERSINFO\[0\] < 4' "${HOOK}"
  assert_success
  assert_output --partial 'BASH_VERSINFO[1] < 4))'
  assert_output --partial 'bash 4.4+ required'
}

@test "manifest: safety survives as a keyword" {
  run jq --exit-status '.keywords | index("safety")' "${PLUGIN_JSON}"
  assert_success
}

@test "manifest: the plugin advertises a semver version" {
  local plugin_version
  plugin_version="$(jq --raw-output '.version' "${PLUGIN_JSON}")"
  [[ "${plugin_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "manifest: plugin.json declares a schemastore \$schema" {
  local plugin_schema
  plugin_schema="$(jq --raw-output '.["$schema"]' "${PLUGIN_JSON}")"
  [[ "${plugin_schema}" == 'https://json.schemastore.org/claude-code-plugin-manifest.json' ]]
}

@test "manifest: the repo ships no marketplace manifest" {
  # The plugin is listed in the separate rvenutolo/claude-plugins-marketplace
  # repo, pinned by tag and sha. A copy here would be a second, unpinned
  # listing that nothing keeps in sync.
  [[ ! -e "${REPO_DIR}/.claude-plugin/marketplace.json" ]]
}

@test "manifest: the plugin declares a displayName for the /plugin UI" {
  local display_name
  display_name="$(jq --raw-output '.displayName' "${PLUGIN_JSON}")"
  [[ "${display_name}" == 'pgrep/pkill Guard' ]]
}

@test "manifest: the hooks description is behavioural, not a label" {
  local description
  description="$(jq --raw-output '.description' "${HOOKS_JSON}")"
  # Anthropic's convention is to say what the hook fires on, what it returns and
  # why the timeout is what it is -- not to restate the plugin name. A label
  # fits in a tweet; this cannot.
  [[ "${#description}" -gt 200 ]]
  [[ "${description}" == *'PreToolUse'* ]]
  [[ "${description}" == *'permissionDecision'* ]]
  [[ "${description}" == *'additionalContext'* ]]
}

# @description Build a minimal, VALID fixture tree so each negative case can
#              corrupt exactly one thing. A short flag only where macOS has no
#              long form, on purpose: a compat CI leg runs this suite against
#              macOS BSD coreutils, whose mkdir has no --parents.
# @arg $1 root directory to populate
function make_manifest_fixture() {
  local -r root="$1"
  mkdir -p "${root}/.claude-plugin" "${root}/hooks"
  cat > "${root}/.claude-plugin/plugin.json" << 'JSON'
{
  "$schema": "https://json.schemastore.org/claude-code-plugin-manifest.json",
  "name": "alpha-plugin",
  "description": "A plugin description that is comfortably longer than ten characters.",
  "homepage": "https://example.com/alpha",
  "repository": "https://example.com/alpha.git",
  "author": { "name": "Rick Venutolo", "url": "https://github.com/rvenutolo" }
}
JSON
  printf '{"description": "fixture", "hooks": {}}\n' > "${root}/hooks/hooks.json"
}

# @description Rewrite one fixture file through a jq filter, in place.
# @arg $1 file the fixture file to edit
# @arg $2 filter the jq program to apply
function fixture_jq() {
  local -r file="$1" filter="$2"
  local -r tmp="${file}.tmp"
  jq "${filter}" "${file}" > "${tmp}"
  mv -f -- "${tmp}" "${file}"
}

@test "invariants: the real repo satisfies every ported invariant" {
  # REPO_DIR explicitly rather than relying on the argument-less default: the
  # default resolves through `git rev-parse`, and a bats test must not depend on
  # the working directory the suite happened to be launched from. The
  # argument-less path is exercised by run-all-checks on every gate run.
  run "${REPO_DIR}/.ci/check-manifest-invariants" "${REPO_DIR}"
  assert_success
}

@test "invariants: a valid fixture passes" {
  make_manifest_fixture "${BATS_TEST_TMPDIR}/ok"
  run "${REPO_DIR}/.ci/check-manifest-invariants" "${BATS_TEST_TMPDIR}/ok"
  assert_success
}

@test "invariants: I3 rejects a too-short description" {
  local -r root="${BATS_TEST_TMPDIR}/i3-short"
  make_manifest_fixture "${root}"
  fixture_jq "${root}/.claude-plugin/plugin.json" '.description = "tiny"'
  run "${REPO_DIR}/.ci/check-manifest-invariants" "${root}"
  assert_failure
  assert_output --partial 'I3'
}

@test "invariants: I3 rejects leading or trailing whitespace in a description" {
  local -r root="${BATS_TEST_TMPDIR}/i3-space"
  make_manifest_fixture "${root}"
  fixture_jq "${root}/.claude-plugin/plugin.json" '.description = "  A description with edge whitespace.  "'
  run "${REPO_DIR}/.ci/check-manifest-invariants" "${root}"
  assert_failure
  assert_output --partial 'I3'
}

@test "invariants: I4 rejects a non-https URL" {
  local -r root="${BATS_TEST_TMPDIR}/i4"
  make_manifest_fixture "${root}"
  fixture_jq "${root}/.claude-plugin/plugin.json" '.homepage = "http://example.com"'
  run "${REPO_DIR}/.ci/check-manifest-invariants" "${root}"
  assert_failure
  assert_output --partial 'I4'
}

@test "invariants: I10 rejects a zero-width space in a name" {
  local -r root="${BATS_TEST_TMPDIR}/i10"
  make_manifest_fixture "${root}"
  # \u200b, not a literal zero-width space: a literal one is invisible in this
  # file and the first editor or copy-paste that eats it turns this into a test
  # that silently checks nothing.
  fixture_jq "${root}/.claude-plugin/plugin.json" '.name = "alpha\u200bplugin"'
  run "${REPO_DIR}/.ci/check-manifest-invariants" "${root}"
  assert_failure
  assert_output --partial 'I10'
}

@test "invariants: I10 rejects a left-to-right mark in a name" {
  local -r root="${BATS_TEST_TMPDIR}/i10-ltr-mark"
  make_manifest_fixture "${root}"
  # \u200e, not a literal LEFT-TO-RIGHT MARK: a literal one is invisible in
  # this file and the first editor or copy-paste that eats it turns this into
  # a test that silently checks nothing.
  fixture_jq "${root}/.claude-plugin/plugin.json" '.name = "alpha\u200eplugin"'
  run "${REPO_DIR}/.ci/check-manifest-invariants" "${root}"
  assert_failure
  assert_output --partial 'I10'
}

@test "invariants: I11 rejects a name outside the allowed shape" {
  local -r root="${BATS_TEST_TMPDIR}/i11"
  make_manifest_fixture "${root}"
  fixture_jq "${root}/.claude-plugin/plugin.json" '.name = "Alpha_Plugin"'
  run "${REPO_DIR}/.ci/check-manifest-invariants" "${root}"
  assert_failure
  assert_output --partial 'I11'
}

@test "invariants: a malformed hooks.json is a failure, not a skip" {
  local -r root="${BATS_TEST_TMPDIR}/hooks"
  make_manifest_fixture "${root}"
  printf '{"description": "truncated"\n' > "${root}/hooks/hooks.json"
  run "${REPO_DIR}/.ci/check-manifest-invariants" "${root}"
  assert_failure
  assert_output --partial 'hooks/hooks.json'
}

@test "invariants: a missing manifest is a failure, not a skip" {
  local -r root="${BATS_TEST_TMPDIR}/missing"
  make_manifest_fixture "${root}"
  rm -f -- "${root}/.claude-plugin/plugin.json"
  run "${REPO_DIR}/.ci/check-manifest-invariants" "${root}"
  assert_failure
  assert_output --partial 'plugin.json'
}

@test "invariants: a surplus argument is rejected, not ignored" {
  # Every positional is optional, so an extra argument can only be a typo -- a
  # misplaced flag, a stray path. Swallowing it silently would run the check
  # anyway and report success on something nobody asked for. Exit 2 rather than
  # 1 keeps the misuse distinct from this script's own failure verdict.
  run "${REPO_DIR}/.ci/check-manifest-invariants" "${REPO_DIR}" 'extra'
  assert_failure 2
  assert_output --partial 'usage:'
}
