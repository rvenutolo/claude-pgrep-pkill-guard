#!/usr/bin/env bash

# Shared test setup loader for every *.bats file under tests/.
# Each .bats file's setup() does: load '../test_helper/common'
#
# Globals exported:
#   REPO_DIR — repo root, resolved from BATS_TEST_DIRNAME
#   HOOK     — absolute path to the guard's entry script, the thing under test
#   BODY     — absolute path to the sibling the entry script sources
#   SCANNER  — absolute path to the awk scanner

REPO_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
HOOK="${REPO_DIR}/hooks/pgrep-pkill-guard.sh"
BODY="${REPO_DIR}/hooks/pgrep-pkill-guard-body.sh"
SCANNER="${REPO_DIR}/hooks/pgrep-scan.awk"
export REPO_DIR HOOK BODY SCANNER

# bats-support / bats-assert normally resolve through the BATS_LIB_PATH that the
# flake's bats wrapper exports. The non-hermetic compat CI legs have no flake, so
# they set BATS_LIB_PATH themselves before invoking bats; either way a bats that
# cannot find the libraries fails loudly here rather than silently missing
# assertions.
bats_load_library bats-support
bats_load_library bats-assert

# --- Fixture-escape hardening: every test is hermetic w.r.t. the real repo ---

# A caller may carry repo-scoped GIT_* vars; with GIT_DIR set, `git -C <fixture>`
# ignores the fixture path and operates on the real repo. Unset them all.
_git_local_env_vars="$(git rev-parse --local-env-vars)"
while IFS= read -r _git_env_var; do
  unset "${_git_env_var}"
done <<< "${_git_local_env_vars}"
unset _git_local_env_vars _git_env_var

# Host git config must never leak into fixtures, and a fixture must never write
# the inverse back into the real shared config.
export GIT_CONFIG_GLOBAL='/dev/null'
export GIT_CONFIG_SYSTEM='/dev/null'

# Upward repo discovery from a fixture path must never cross into the real repo.
export GIT_CEILING_DIRECTORIES="${REPO_DIR}"

# Stop child bash processes from re-sourcing the user's interactive ~/.bashrc,
# which would clobber the per-test environment.
unset BASH_ENV

# @description Build a PreToolUse hook payload for the Bash tool.
#              session_id is OMITTED when not supplied, which is what keeps the
#              stateful repeat tier out of the stateless verdict cases.
# @arg $1 command the command string to classify
# @arg $2 session_id optional session id; omit for stateless cases
# @stdout one line of JSON
function hook_json() {
  local -r command="$1"
  local -r session_id="${2:-}"
  if [[ -n "${session_id}" ]]; then
    jq --null-input --arg sid "${session_id}" --arg cmd "${command}" \
      '{session_id: $sid, tool_name: "Bash", tool_input: {command: $cmd}}'
  else
    jq --null-input --arg cmd "${command}" \
      '{tool_name: "Bash", tool_input: {command: $cmd}}'
  fi
}

# @description Run the hook on a command and print its raw JSON output.
# @arg $1 command the command string
# @arg $2 session_id optional session id
# @stdout the hook's JSON response
function run_hook() {
  local -r command="$1"
  local -r session_id="${2:-}"
  hook_json "${command}" "${session_id}" | "${HOOK}"
}

# @description Print the permissionDecision from a hook response, or "none".
# @arg $1 json the hook's JSON output
# @stdout allow, deny, or none
function decision_of() {
  jq --raw-output '.hookSpecificOutput.permissionDecision // "none"' <<< "$1"
}

# @description Print the permissionDecisionReason from a hook response.
# @arg $1 json the hook's JSON output
# @stdout the reason text, or empty
function reason_of() {
  jq --raw-output '.hookSpecificOutput.permissionDecisionReason // ""' <<< "$1"
}

# @description Print the additionalContext from a hook response.
# @arg $1 json the hook's JSON output
# @stdout the additionalContext text, or empty
function context_of() {
  jq --raw-output '.hookSpecificOutput.additionalContext // ""' <<< "$1"
}
