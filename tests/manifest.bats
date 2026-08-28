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
