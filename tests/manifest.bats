setup() {
  load 'test_helper/common'
  PLUGIN_JSON="${REPO_DIR}/.claude-plugin/plugin.json"
  MARKET_JSON="${REPO_DIR}/.claude-plugin/marketplace.json"
  HOOKS_JSON="${REPO_DIR}/hooks/hooks.json"
}

@test "manifest: all three files are valid JSON" {
  run jq empty "${PLUGIN_JSON}"
  assert_success
  run jq empty "${MARKET_JSON}"
  assert_success
  run jq empty "${HOOKS_JSON}"
  assert_success
}

@test "manifest: plugin name matches the marketplace entry" {
  local plugin_name market_name
  plugin_name="$(jq --raw-output '.name' "${PLUGIN_JSON}")"
  market_name="$(jq --raw-output '.plugins[0].name' "${MARKET_JSON}")"
  [ "${plugin_name}" = 'pgrep-pkill-guard' ]
  [ "${market_name}" = 'pgrep-pkill-guard' ]
}

@test "manifest: marketplace declares the required top-level fields" {
  run jq --exit-status '.name and .owner.name and (.plugins | length > 0)' "${MARKET_JSON}"
  assert_success
}

@test "manifest: the plugin source points at the repo root" {
  local source
  source="$(jq --raw-output '.plugins[0].source' "${MARKET_JSON}")"
  [ "${source}" = './' ]
}

@test "manifest: the hook command invokes the script directly, not via bash" {
  local command
  command="$(jq --raw-output '.hooks.PreToolUse[0].hooks[0].command' "${HOOKS_JSON}")"
  # Direct invocation is load-bearing on macOS: `bash <path>` would resolve to
  # /bin/bash 3.2 and the version guard would deactivate the hook.
  refute [ "${command:0:5}" = 'bash ' ]
  [[ "${command}" == *'${CLAUDE_PLUGIN_ROOT}'* ]]
  [[ "${command}" == *'pgrep-pkill-guard.sh' ]]
}

@test "manifest: the hook path in hooks.json exists and is executable" {
  [ -x "${REPO_DIR}/hooks/pgrep-pkill-guard.sh" ]
}

@test "manifest: the scanner exists and is NOT executable" {
  [ -f "${REPO_DIR}/hooks/pgrep-scan.awk" ]
  [ ! -x "${REPO_DIR}/hooks/pgrep-scan.awk" ]
}

@test "inactive: the old-bash branch emits a systemMessage, not a bare {}" {
  # BASH_VERSINFO is read-only, so the branch cannot be driven in-process. The
  # real behaviour is covered by the stock-macOS compat CI leg; this pins the
  # source-level invariant so the branch can never silently regress to `{}`.
  # -A6, not -A3: the replacement puts a three-line comment between the
  # condition and the printf, which pushes INACTIVE outside a 3-line window.
  run grep -A6 'BASH_VERSINFO\[0\] < 4' "${HOOK}"
  assert_success
  assert_output --partial 'systemMessage'
  assert_output --partial 'INACTIVE'
  refute_output --partial "printf '{}"
}

@test "manifest: the marketplace category is a recognised value" {
  local category
  category="$(jq --raw-output '.plugins[0].category' "${MARKET_JSON}")"
  # `safety` appears zero times across the 289 entries in
  # anthropics/claude-plugins-official; `security` is the real vocabulary.
  [ "${category}" = 'security' ]
}

@test "manifest: safety survives as a keyword" {
  run jq --exit-status '.keywords | index("safety")' "${PLUGIN_JSON}"
  assert_success
}

@test "manifest: plugin and marketplace advertise the same version" {
  local plugin_version market_version
  plugin_version="$(jq --raw-output '.version' "${PLUGIN_JSON}")"
  market_version="$(jq --raw-output '.plugins[0].version' "${MARKET_JSON}")"
  [ "${plugin_version}" = "${market_version}" ]
  [[ "${plugin_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "manifest: both files declare a schemastore \$schema" {
  local plugin_schema market_schema
  plugin_schema="$(jq --raw-output '.["$schema"]' "${PLUGIN_JSON}")"
  market_schema="$(jq --raw-output '.["$schema"]' "${MARKET_JSON}")"
  [ "${plugin_schema}" = 'https://json.schemastore.org/claude-code-plugin-manifest.json' ]
  [ "${market_schema}" = 'https://json.schemastore.org/claude-code-marketplace.json' ]
}

@test "manifest: the plugin declares a displayName for the /plugin UI" {
  local display_name
  display_name="$(jq --raw-output '.displayName' "${PLUGIN_JSON}")"
  [ "${display_name}" = 'pgrep/pkill Guard' ]
}

@test "manifest: the marketplace entry carries homepage and author" {
  local homepage author_name author_url
  homepage="$(jq --raw-output '.plugins[0].homepage' "${MARKET_JSON}")"
  author_name="$(jq --raw-output '.plugins[0].author.name' "${MARKET_JSON}")"
  author_url="$(jq --raw-output '.plugins[0].author.url' "${MARKET_JSON}")"
  [ "${homepage}" = 'https://github.com/rvenutolo/claude-pgrep-pkill-guard' ]
  [ "${author_name}" = 'Rick Venutolo' ]
  [ "${author_url}" = 'https://github.com/rvenutolo' ]
}

@test "manifest: the hooks description is behavioural, not a label" {
  local description
  description="$(jq --raw-output '.description' "${HOOKS_JSON}")"
  # Anthropic's convention is to say what the hook fires on, what it returns and
  # why the timeout is what it is -- not to restate the plugin name. A label
  # fits in a tweet; this cannot.
  [ "${#description}" -gt 200 ]
  [[ "${description}" == *'PreToolUse'* ]]
  [[ "${description}" == *'permissionDecision'* ]]
  [[ "${description}" == *'additionalContext'* ]]
}

# @description Build a minimal, VALID fixture tree so each negative case can
#              corrupt exactly one thing. POSIX short flags on purpose: the
#              compat CI legs run this suite against macOS BSD coreutils, whose
#              mkdir has no --parents.
# @arg $1 root directory to populate
function make_manifest_fixture() {
  local -r root="$1"
  mkdir -p "${root}/.claude-plugin" "${root}/hooks"
  cat > "${root}/.claude-plugin/marketplace.json" << 'JSON'
{
  "$schema": "https://json.schemastore.org/claude-code-marketplace.json",
  "name": "rvenutolo",
  "owner": { "name": "Rick Venutolo", "url": "https://github.com/rvenutolo" },
  "plugins": [
    {
      "name": "alpha-plugin",
      "source": "./",
      "description": "A description that is comfortably longer than ten characters.",
      "homepage": "https://example.com/alpha"
    },
    {
      "name": "beta-plugin",
      "source": "./beta",
      "description": "Another description that is comfortably longer than ten characters.",
      "homepage": "https://example.com/beta"
    }
  ]
}
JSON
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
  mv -f "${tmp}" "${file}"
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

@test "invariants: I1 rejects an out-of-order plugins array" {
  local -r root="${BATS_TEST_TMPDIR}/i1"
  make_manifest_fixture "${root}"
  fixture_jq "${root}/.claude-plugin/marketplace.json" '.plugins |= reverse'
  run "${REPO_DIR}/.ci/check-manifest-invariants" "${root}"
  assert_failure
  assert_output --partial 'I1'
}

@test "invariants: I2 rejects duplicate plugin names" {
  local -r root="${BATS_TEST_TMPDIR}/i2"
  make_manifest_fixture "${root}"
  fixture_jq "${root}/.claude-plugin/marketplace.json" '.plugins[1].name = "alpha-plugin"'
  run "${REPO_DIR}/.ci/check-manifest-invariants" "${root}"
  assert_failure
  assert_output --partial 'I2'
}

@test "invariants: I3 rejects a too-short description" {
  local -r root="${BATS_TEST_TMPDIR}/i3-short"
  make_manifest_fixture "${root}"
  fixture_jq "${root}/.claude-plugin/marketplace.json" '.plugins[0].description = "tiny"'
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
  fixture_jq "${root}/.claude-plugin/marketplace.json" '.owner.url = "http://example.com"'
  run "${REPO_DIR}/.ci/check-manifest-invariants" "${root}"
  assert_failure
  assert_output --partial 'I4'
}

@test "invariants: I9 rejects shell metacharacters in a source" {
  local -r root="${BATS_TEST_TMPDIR}/i9"
  make_manifest_fixture "${root}"
  # An inert marker, never a real command: the point is that the string reaches
  # the check, not that anything runs.
  fixture_jq "${root}/.claude-plugin/marketplace.json" '.plugins[0].source = "./; echo PAYLOAD_RAN"'
  run "${REPO_DIR}/.ci/check-manifest-invariants" "${root}"
  assert_failure
  # The I9 message quotes the offending value, so PAYLOAD_RAN appears in the
  # output BY DESIGN -- a diagnostic that does not name the bad string is
  # useless. What the marker proves is that it was only ever printed: it is an
  # echo, so if the string had been evaluated anywhere the suite would still be
  # green while the check was worthless.
  assert_output --partial 'I9'
  assert_output --partial './; echo PAYLOAD_RAN'
}

@test "invariants: I10 rejects a zero-width space in a name" {
  local -r root="${BATS_TEST_TMPDIR}/i10"
  make_manifest_fixture "${root}"
  # \u200b, not a literal zero-width space: a literal one is invisible in this
  # file and the first editor or copy-paste that eats it turns this into a test
  # that silently checks nothing.
  fixture_jq "${root}/.claude-plugin/marketplace.json" '.plugins[0].name = "alpha\u200bplugin"'
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
