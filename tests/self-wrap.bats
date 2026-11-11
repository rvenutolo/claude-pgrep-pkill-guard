# The self-wrap rule: every tracked bash or sh script re-runs itself through
# .ci/in-devshell when IN_DEVSHELL is unset, unless it carries a
# `# devshell-exempt: <reason>` comment.
#
# Three layers. A lint over the tracked scripts holds every one to the rule. A
# stub `nix` first on PATH records the command .ci/in-devshell builds, so every
# wrapped script is shown to re-run itself, through a symlink and from a cwd
# outside any repository, without running anything; the same stub shows that
# the opt-outs (`run-tests --ambient`, a check's fixture mode) re-run nothing.
# .ci/testdata/self-wrap-probe, a script that follows the rule and prints where
# it ended up, is run against the real devShell for what only a real run
# shows: IN_DEVSHELL set, the host PATH gone, arguments and exit status intact.
#
# Every run that is meant to reach the wrapper unsets IN_DEVSHELL, and
# GIT_CEILING_DIRECTORIES, which common.bash sets to the repo root and which
# would stop `git` from climbing from .ci/ up to the root the wrapper resolves.
# Payloads are inert: the stub records and exits, the probe prints and exits.
#
# Entering the devShell needs Nix and GNU coreutils, which the ambient compat
# legs do not have, so this suite skips outside the devShell; the gate legs
# run it.
#
# setup sets PROBE, the fixture script, HOST_DIR, an empty directory standing
# in for a host PATH entry, and STUB_DIR, the directory holding the stub nix
# and the few host tools a stubbed run is given.

function setup() {
  load 'test_helper/common'
  # .ci/in-devshell exports IN_DEVSHELL; the ambient compat legs do not have it.
  if [[ -z "${IN_DEVSHELL:-}" ]]; then
    skip 'not in the devShell; entering one needs Nix'
  fi
  PROBE="${REPO_DIR}/.ci/testdata/self-wrap-probe"
  HOST_DIR="${BATS_TEST_TMPDIR}/host"
  STUB_DIR="${BATS_TEST_TMPDIR}/stub"
  mkdir -- "${HOST_DIR}" "${STUB_DIR}" "${BATS_TEST_TMPDIR}/tmp"
  # Records its arguments, one per line, and exits with NIX_STUB_STATUS.
  # shellcheck disable=SC2016 # expanded by the stub, not here
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/nix-args"\nexit "${NIX_STUB_STATUS:-0}"\n' \
    "${BATS_TEST_TMPDIR}" > "${STUB_DIR}/nix"
  chmod +x -- "${STUB_DIR}/nix"
}

# Scripts that run where the devShell cannot take them; each carries its reason
# in a `# devshell-exempt:` comment.
readonly -a EXEMPT=(
  '.ci/activate-githooks'
  '.ci/check-inactive-on-old-bash'
  '.ci/run-plugin-validate'
  'hooks/pgrep-pkill-guard.sh'
)

# @description Print every tracked executable whose shebang names bash or sh,
#              other than .ci/in-devshell itself.
# @noargs
# @stdout one repo-relative path per line
function tracked_scripts() {
  local meta path first_line interpreter
  while IFS=$'\t' read -r meta path; do
    if [[ "${meta%% *}" != '100755' || "${path}" == '.ci/in-devshell' ]]; then
      continue
    fi
    first_line=''
    IFS= read -r first_line < "${REPO_DIR}/${path}" || : # read returns 1 on an unterminated line yet stores it
    if [[ "${first_line}" != '#!'* ]]; then
      continue
    fi
    interpreter="${first_line#'#!'}"
    interpreter="${interpreter#/usr/bin/env }"
    interpreter="${interpreter%% *}"
    interpreter="${interpreter##*/}"
    if [[ "${interpreter}" == 'bash' || "${interpreter}" == 'sh' ]]; then
      printf '%s\n' "${path}"
    fi
  done < <(git -C "${REPO_DIR}" ls-files --stage)
}

# @description Succeed if the path is in EXEMPT.
# @arg $1 path the repo-relative path
# @exitcode 0 it is exempt
# @exitcode 1 it is not
function is_exempt() {
  local path
  for path in "${EXEMPT[@]}"; do
    if [[ "${path}" == "$1" ]]; then
      return 0
    fi
  done
  return 1
}

# @description Run a script outside the devShell boundary against the stub nix:
#              IN_DEVSHELL and GIT_CEILING_DIRECTORIES unset, a scratch TMPDIR,
#              stdin from /dev/null, and a PATH of the stub nix plus only the
#              host tools the self-wrap block and the wrapper use. A script
#              that failed to re-run itself would find none of the tools it
#              calls, so it stops at the first one instead of doing its work.
# @arg $@ command the script and its arguments
function run_outside() {
  local tool found
  for tool in bash dirname env git mktemp readlink rm; do
    if [[ ! -e "${STUB_DIR}/${tool}" ]]; then
      found="$(command -v "${tool}")"
      ln --symbolic -- "${found}" "${STUB_DIR}/${tool}"
    fi
  done
  env --unset=IN_DEVSHELL --unset=GIT_CEILING_DIRECTORIES \
    PATH="${STUB_DIR}" TMPDIR="${BATS_TEST_TMPDIR}/tmp" "$@" < '/dev/null'
}

# @description Run a script outside the devShell boundary with the stub nix
#              and HOST_DIR ahead of the full PATH, so an opt-out that re-runs
#              nothing finds every tool it calls, and a re-run, which it must
#              not make, would be recorded.
# @arg $@ command the script and its arguments
function run_opted_out() {
  env --unset=IN_DEVSHELL --unset=GIT_CEILING_DIRECTORIES NIX_STUB_STATUS=7 \
    PATH="${STUB_DIR}:${HOST_DIR}:${PATH}" TMPDIR="${BATS_TEST_TMPDIR}/tmp" "$@" < '/dev/null'
}

# @description Run a script outside the devShell boundary with only HOST_DIR
#              added to PATH, so the real nix enters the real devShell.
# @arg $@ command the script and its arguments
function run_real() {
  env --unset=IN_DEVSHELL --unset=GIT_CEILING_DIRECTORIES \
    PATH="${HOST_DIR}:${PATH}" TMPDIR="${BATS_TEST_TMPDIR}/tmp" "$@" < '/dev/null'
}

# @description Fail unless the probe's output says it ran inside the devShell
#              with HOST_DIR gone from PATH.
# @noargs
function assert_in_devshell() {
  assert_line 'IN_DEVSHELL=1'
  refute_line --regexp "^PATH=(.*:)?${HOST_DIR}(:.*)?$"
}

@test "self-wrap: every tracked bash or sh script re-runs through in-devshell or says why not" {
  local path text failures=''
  while IFS= read -r path; do
    # A file of comments alone has no line left, and grep then exits 1.
    text="$(grep --invert-match '^[[:space:]]*#' -- "${REPO_DIR}/${path}" || true)" # no line left is no failure
    if is_exempt "${path}"; then
      grep --quiet --extended-regexp '^# devshell-exempt: [^[:space:]]' -- "${REPO_DIR}/${path}" \
        || failures+=" ${path}(no devshell-exempt reason)"
      continue
    fi
    grep --quiet --extended-regexp '\[\[.*IN_DEVSHELL' <<< "${text}" \
      || failures+=" ${path}(no IN_DEVSHELL test)"
    grep --quiet --extended-regexp '^[[:space:]]*exec .*in-devshell' <<< "${text}" \
      || failures+=" ${path}(no exec of in-devshell)"
  done < <(tracked_scripts)
  assert_equal "${failures}" ''
}

@test "self-wrap: every wrapped script, run through a symlink from outside the repo, hands itself to the devShell" {
  local path link rc head_args failures=''
  mkdir -- "${BATS_TEST_TMPDIR}/elsewhere"
  cd "${BATS_TEST_TMPDIR}/elsewhere"
  while IFS= read -r path; do
    if is_exempt "${path}"; then
      continue
    fi
    link="${BATS_TEST_TMPDIR}/elsewhere/${path//\//_}"
    ln --symbolic -- "${REPO_DIR}/${path}" "${link}"
    rm --force -- "${BATS_TEST_TMPDIR}/nix-args"
    rc=0
    NIX_STUB_STATUS=7 run_outside "${link}" > "${BATS_TEST_TMPDIR}/out" 2>&1 || rc="$?"
    if [[ "${rc}" != 7 ]]; then
      failures+=" ${path}(exit ${rc}: $(< "${BATS_TEST_TMPDIR}/out"))"
      continue
    fi
    # develop <repo> --ignore-environment ... --command <the script's real path>
    head_args="$(sed --quiet '1p;2p;3p' "${BATS_TEST_TMPDIR}/nix-args" | paste --serial --delimiters=' ')"
    if [[ "${head_args}" != "develop ${REPO_DIR} --ignore-environment" ]] \
      || [[ "$(sed --quiet '/^--command$/{n;p;q}' "${BATS_TEST_TMPDIR}/nix-args")" != "${REPO_DIR}/${path}" ]]; then
      failures+=" ${path}(nix got: $(paste --serial --delimiters=' ' "${BATS_TEST_TMPDIR}/nix-args"))"
    fi
  done < <(tracked_scripts)
  assert_equal "${failures}" ''
  assert_equal "$(find "${BATS_TEST_TMPDIR}/tmp" -mindepth 1 -maxdepth 1)" ''
}

@test "self-wrap: arguments reach the re-run unchanged" {
  local -a got=()
  run run_outside "${REPO_DIR}/run-tests" 'a b' '' '*' 'c'
  assert_success
  mapfile -t got < <(sed --quiet '/^--command$/,$p' "${BATS_TEST_TMPDIR}/nix-args")
  assert_equal "${#got[@]}" 6
  assert_equal "${got[1]}" "${REPO_DIR}/run-tests"
  assert_equal "${got[2]}" 'a b'
  assert_equal "${got[3]}" ''
  assert_equal "${got[4]}" '*'
  assert_equal "${got[5]}" 'c'
}

@test "self-wrap: a hook started by git, with GIT_DIR set, hands itself to its repo's devShell" {
  # Git exports GIT_DIR to the hooks it runs. With GIT_DIR set and no
  # GIT_WORK_TREE, `git rev-parse --show-toplevel` answers with the current
  # directory, whatever directory that is.
  local git_dir
  git_dir="$(git -C "${REPO_DIR}" rev-parse --absolute-git-dir)"
  cd "${REPO_DIR}"
  run run_outside env GIT_DIR="${git_dir}" "${REPO_DIR}/.githooks/pre-push" 'origin' 'url'
  assert_success
  assert_equal "$(sed --quiet '2p' "${BATS_TEST_TMPDIR}/nix-args")" "${REPO_DIR}"
  assert_equal "$(sed --quiet '/^--command$/{n;p;q}' "${BATS_TEST_TMPDIR}/nix-args")" \
    "${REPO_DIR}/.githooks/pre-push"
}

@test "self-wrap: run-tests --ambient re-runs nothing, keeps the host PATH and strips the flag before bats" {
  local -r file="${BATS_TEST_TMPDIR}/ambient-probe.bats"
  # The fixture records the PATH bats ran under. Its body is the probe's only
  # effect, so a re-run, or a bats handed the flag, leaves no record.
  # shellcheck disable=SC2016 # expanded by the fixture's bats, not here
  printf '@test "ambient probe" {\n  printf "%%s\\n" "${PATH}" > "${PROBE_OUT}"\n}\n' > "${file}"
  cd "${REPO_DIR}"
  run run_opted_out env PROBE_OUT="${BATS_TEST_TMPDIR}/probe-path" "${REPO_DIR}/run-tests" "${file}" --ambient
  assert_success
  [[ ! -e "${BATS_TEST_TMPDIR}/nix-args" ]]
  assert_equal "$(grep --count --extended-regexp "(^|:)${HOST_DIR}(:|$)" "${BATS_TEST_TMPDIR}/probe-path")" 1
}

@test "self-wrap: a check given a fixture re-runs nothing and gives its own verdict" {
  local entry path expected rc failures=''
  local -a fields=()
  # <script>|<the verdict the check gives>|<its fixture arguments>, run from a
  # directory outside any repo, so nothing but the arguments names a tree. The
  # real tree passes every check that reads a whole repo root; the devShell
  # check reads an inventory the repo root does not hold, so its verdict is a
  # failure of its own.
  local -ar cases=(
    ".ci/check-bench-fresh|0|${REPO_DIR}"
    ".ci/check-devshell-provides|1|${REPO_DIR}"
    ".ci/check-executable-bit|0|${REPO_DIR}"
    ".ci/check-guard-parts|0|${REPO_DIR}"
    ".ci/check-invariant-markers|0|${REPO_DIR}"
    ".ci/check-issue-forms|0|${REPO_DIR}/.github/ISSUE_TEMPLATE|${REPO_DIR}/.github/labels.yml"
    ".ci/check-manifest-invariants|0|${REPO_DIR}"
    ".ci/check-shell-shebangs|0|${REPO_DIR}"
  )
  cd "${BATS_TEST_TMPDIR}"
  for entry in "${cases[@]}"; do
    IFS='|' read -r -a fields <<< "${entry}"
    path="${fields[0]}"
    expected="${fields[1]}"
    rm --force -- "${BATS_TEST_TMPDIR}/nix-args"
    rc=0
    run_opted_out "${REPO_DIR}/${path}" "${fields[@]:2}" > "${BATS_TEST_TMPDIR}/out" 2>&1 || rc="$?"
    if [[ -e "${BATS_TEST_TMPDIR}/nix-args" ]]; then
      failures+=" ${path}(re-ran)"
    elif [[ "${rc}" != "${expected}" ]]; then
      failures+=" ${path}(exit ${rc}, expected ${expected}: $(< "${BATS_TEST_TMPDIR}/out"))"
    fi
  done
  assert_equal "${failures}" ''
}

@test "self-wrap: a direct run ends inside the devShell with the host PATH gone" {
  cd "${REPO_DIR}"
  run run_real "${PROBE}"
  assert_success
  assert_in_devshell
}

@test "self-wrap: arguments and exit status survive the real re-run" {
  cd "${REPO_DIR}"
  run run_real "${PROBE}" --exit=3 'a b' '' '*'
  assert_failure 3
  assert_in_devshell
  assert_equal "$(grep '^ARG=' <<< "${output}" | paste --serial --delimiters='|')" 'ARG=a b|ARG=|ARG=*'
}

@test "self-wrap: a run through a symlink from the repo root ends inside the devShell" {
  ln --symbolic -- "${PROBE}" "${BATS_TEST_TMPDIR}/link"
  cd "${REPO_DIR}"
  run run_real "${BATS_TEST_TMPDIR}/link" --exit=5 'x'
  assert_failure 5
  assert_in_devshell
  assert_line 'ARG=x'
}

@test "self-wrap: a run through a symlink from outside any repo ends inside the devShell" {
  mkdir -- "${BATS_TEST_TMPDIR}/elsewhere"
  ln --symbolic -- "${PROBE}" "${BATS_TEST_TMPDIR}/elsewhere/link"
  cd "${BATS_TEST_TMPDIR}/elsewhere"
  run run_real "${BATS_TEST_TMPDIR}/elsewhere/link" --exit=6 'y'
  assert_failure 6
  assert_in_devshell
  assert_line 'ARG=y'
}

@test "self-wrap: with IN_DEVSHELL already set there is no re-run" {
  local parent pid
  cd "${REPO_DIR}"
  # The shell prints its pid and execs the probe, so the probe keeps that pid
  # unless something between them started it as a new process. A re-run would
  # also reset IN_DEVSHELL to the wrapper's value and drop HOST_DIR from PATH.
  # shellcheck disable=SC2016 # expanded by the inner bash, not here
  run env IN_DEVSHELL='caller-set' PATH="${HOST_DIR}:${PATH}" \
    bash -c 'printf "PARENT=%s\n" "$$"; exec "$1" z' bash "${PROBE}"
  assert_success
  assert_line 'IN_DEVSHELL=caller-set'
  assert_line 'ARG=z'
  assert_line --regexp "^PATH=(.*:)?${HOST_DIR}(:.*)?$"
  parent="$(sed --quiet 's/^PARENT=//p' <<< "${output}")"
  pid="$(sed --quiet 's/^PID=//p' <<< "${output}")"
  assert_equal "${pid}" "${parent}"
}

@test "self-wrap: every wrapped script takes its repo root from its own path" {
  # The strip count is the script's depth below the root plus one: a root-level
  # script strips one component, a script one directory down strips two, and
  # so on.
  # A `rev-parse --show-toplevel` that is not the repo root carries a
  # `# cwd-root: <reason>` comment on its line.
  local path text strip depth expected roots bare line seen failures=''
  while IFS= read -r path; do
    is_exempt "${path}" && continue
    text="$(grep --invert-match '^[[:space:]]*#' -- "${REPO_DIR}/${path}" || true)"       # none left: fine
    roots="$(grep --fixed-strings 'git rev-parse --show-toplevel' <<< "${text}" || true)" # none: fine
    bare="$(grep --invert-match --fixed-strings '# cwd-root: ' <<< "${roots}" || true)"   # none left: fine
    if [[ -n "${bare}" ]]; then
      failures+=" ${path}(cwd root)"
      continue
    fi
    depth="${path//[^\/]/}"
    strip=''
    for ((i = 0; i <= ${#depth}; i++)); do
      strip+='/*'
    done
    expected="SELF_REPO=\"\${SELF_PATH%${strip}}\""
    seen=0
    while IFS= read -r line; do
      if [[ "${line}" == "${expected}" ]]; then
        seen=1
      elif [[ "${line}" == *'[['*IN_DEVSHELL* ]]; then
        break
      fi
    done < "${REPO_DIR}/${path}"
    if ((! seen)); then
      failures+=" ${path}(no SELF_REPO at depth ${#depth})"
    fi
  done < <(tracked_scripts)
  assert_equal "${failures}" ''
}

@test "self-wrap: a check run through a symlink from outside any repo grades its own repo" {
  mkdir -- "${BATS_TEST_TMPDIR}/elsewhere"
  ln --symbolic -- "${REPO_DIR}/.ci/check-uses-sha-pinned" "${BATS_TEST_TMPDIR}/elsewhere/link"
  cd "${BATS_TEST_TMPDIR}/elsewhere"
  run env IN_DEVSHELL=1 "${BATS_TEST_TMPDIR}/elsewhere/link"
  assert_success
}

@test "self-wrap: a check run through a symlink from another repo grades its own repo" {
  local scratch="${BATS_TEST_TMPDIR}/other-repo"
  mkdir --parents -- "${scratch}/.github/workflows"
  # An inert unpinned reference: the check rejects it if it grades this tree.
  printf 'jobs:\n  x:\n    steps:\n      - uses: actions/checkout@v4\n' > "${scratch}/.github/workflows/x.yml"
  git -C "${scratch}" init --quiet
  git -C "${scratch}" add -- '.github/workflows/x.yml'
  ln --symbolic -- "${REPO_DIR}/.ci/check-uses-sha-pinned" "${scratch}/link"
  cd "${scratch}"
  run env IN_DEVSHELL=1 "${scratch}/link"
  assert_success
}

@test "self-wrap: a wrapped script derives no path from a non-canonical BASH_SOURCE or \$0" {
  # The only BASH_SOURCE use is the canonical SELF_PATH line, spelled
  # `readlink -f` in the AMBIENT_REACHED scripts and `readlink --canonicalize`
  # everywhere else; a dirname of BASH_SOURCE or $0, or a suffix strip of
  # either, resolves against a symlink's directory.
  local path text hits bad allowed spelling failures=''
  while IFS= read -r path; do
    is_exempt "${path}" && continue
    spelling='--canonicalize'
    if [[ " ${AMBIENT_REACHED[*]} " == *" ${path} "* ]]; then
      spelling='-f'
    fi
    allowed="readlink ${spelling} -- \"\${BASH_SOURCE[0]}\""
    text="$(grep --invert-match '^[[:space:]]*#' -- "${REPO_DIR}/${path}" || true)" # none left: fine
    # shellcheck disable=SC2016 # literal patterns, not expansions
    hits="$(grep --extended-regexp 'BASH_SOURCE|dirname[^|]*"\$0"|\$\{0%' <<< "${text}" || true)" # none: ok
    bad="$(grep --invert-match --fixed-strings "${allowed}" <<< "${hits}" || true)"               # none: ok
    if [[ -n "${bad}" ]]; then
      failures+=" ${path}(non-canonical self-location)"
    fi
  done < <(tracked_scripts)
  assert_equal "${failures}" ''
}

@test "self-wrap: check-bash-style run through a symlink finds its own jq library" {
  mkdir -- "${BATS_TEST_TMPDIR}/elsewhere"
  ln --symbolic -- "${REPO_DIR}/.ci/check-bash-style" "${BATS_TEST_TMPDIR}/elsewhere/link"
  printf '#!/usr/bin/env bash\necho PAYLOAD_RAN\n' > "${BATS_TEST_TMPDIR}/elsewhere/clean.sh"
  cd "${BATS_TEST_TMPDIR}/elsewhere"
  run env IN_DEVSHELL=1 "${BATS_TEST_TMPDIR}/elsewhere/link" "${BATS_TEST_TMPDIR}/elsewhere"
  refute_output --partial 'module not found'
  refute_output --partial 'could not be scanned'
}

# The scripts the ambient compat legs reach with IN_DEVSHELL unset: run-tests
# under --ambient and the checks under a fixture argument. They resolve their
# own path with `readlink -f`, because BSD readlink on the macOS leg has no
# long options.
readonly -a AMBIENT_REACHED=(
  '.ci/check-bench-fresh'
  '.ci/check-devshell-provides'
  '.ci/check-executable-bit'
  '.ci/check-guard-parts'
  '.ci/check-invariant-markers'
  '.ci/check-issue-forms'
  '.ci/check-manifest-invariants'
  '.ci/check-shell-shebangs'
  'run-tests'
)

@test "self-wrap: the scripts the ambient legs run resolve their path with a BSD readlink" {
  local path rc failures=''
  local -r bsd_dir="${BATS_TEST_TMPDIR}/bsd"
  mkdir -- "${bsd_dir}"
  # Inert: refuses every long option the way BSD readlink does, and otherwise
  # hands the call to the real readlink.
  # shellcheck disable=SC2016 # expanded by the stub, not here
  printf '#!/bin/sh\nfor a in "$@"; do\n  case "$a" in\n    --?*) echo "readlink: illegal option -- -" >&2; exit 1 ;;\n  esac\ndone\nexec "%s" "$@"\n' \
    "$(command -v readlink)" > "${bsd_dir}/readlink"
  chmod +x -- "${bsd_dir}/readlink"
  printf '@test "probe" {\n  :\n}\n' > "${BATS_TEST_TMPDIR}/probe.bats"
  cd "${BATS_TEST_TMPDIR}"
  for path in "${AMBIENT_REACHED[@]}"; do
    rc=0
    if [[ "${path}" == 'run-tests' ]]; then
      env --unset=IN_DEVSHELL PATH="${bsd_dir}:${PATH}" "${REPO_DIR}/${path}" --ambient \
        "${BATS_TEST_TMPDIR}/probe.bats" > "${BATS_TEST_TMPDIR}/out" 2>&1 || rc="$?"
    else
      env --unset=IN_DEVSHELL PATH="${bsd_dir}:${PATH}" "${REPO_DIR}/${path}" "${REPO_DIR}" \
        > "${BATS_TEST_TMPDIR}/out" 2>&1 || rc="$?"
    fi
    if grep --quiet --fixed-strings 'illegal option' "${BATS_TEST_TMPDIR}/out"; then
      failures+=" ${path}(long option reached BSD readlink)"
    fi
  done
  assert_equal "${failures}" ''
}
