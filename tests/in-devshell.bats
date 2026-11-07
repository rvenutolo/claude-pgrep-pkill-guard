# .ci/in-devshell against the real devShell: it must run the command, return
# its status, and leave nothing behind in the caller's TMPDIR however the
# command ends.
#
# Every case runs the wrapper with IN_DEVSHELL unset, so it really enters
# `nix develop`, and with GIT_CEILING_DIRECTORIES unset: common.bash sets it to
# the repo root, which stops `git` from climbing from .ci/ up to the root the
# wrapper resolves. Payloads are inert (`true`, `sh -c 'exit 3'`, `sleep`,
# marker files), and signals go only to processes a case started, by recorded
# pid or by the process group of a job it started.
#
# Entering the devShell needs Nix and GNU coreutils, which the ambient compat
# legs do not have, so this suite skips outside the devShell; the gate legs
# run it.
#
# Background jobs redirect every descriptor, fd 3 included: bats waits for
# fd 3 to close, so a job holding it would stall the suite.
#
# setup sets WRAPPER, the script under test, SCRATCH, an empty directory a
# case hands the wrapper as its TMPDIR, and STARTED, the file of pids a case
# has started and not yet seen end.

function setup() {
  load 'test_helper/common'
  # .ci/in-devshell exports IN_DEVSHELL; the ambient compat legs do not have it.
  if [[ -z "${IN_DEVSHELL:-}" ]]; then
    skip 'not in the devShell; entering one needs Nix'
  fi
  WRAPPER="${REPO_DIR}/.ci/in-devshell"
  SCRATCH="${BATS_TEST_TMPDIR}/tmp"
  mkdir -- "${SCRATCH}"
  STARTED="${BATS_TEST_TMPDIR}/started-pids"
  : > "${STARTED}"
}

# A case that fails midway must not leave a process it started running. A case
# records each pid it starts in the STARTED file and drops it once it has seen
# the process end: the kernel may hand that pid to an unrelated process, which
# a KILL here would then hit. A file, not an array: each case runs in a
# subshell of its own, so an array it extends would not reach teardown.
function teardown() {
  local pid
  if [[ ! -f "${STARTED:-}" ]]; then
    return 0
  fi
  while IFS= read -r pid; do
    kill -s KILL "${pid}" 2> '/dev/null' || true # the process may have ended already
  done < "${STARTED}"
}

# How long a case waits for a process to start or end, in tenths of a second.
# Entering the devShell may build or fetch it on a cold store.
readonly WAIT_TICKS=1200

# @description Record a pid this case started, for teardown.
# @arg $1 pid the process id
function remember_pid() {
  printf '%s\n' "$1" >> "${STARTED}"
}

# @description Drop a pid from the STARTED file once its process is known to
#              have ended.
# @arg $1 pid the process id
function forget_pid() {
  local -a kept=()
  local pid
  while IFS= read -r pid; do
    if [[ "${pid}" != "$1" ]]; then
      kept+=("${pid}")
    fi
  done < "${STARTED}"
  if ((${#kept[@]} > 0)); then
    printf '%s\n' "${kept[@]}" > "${STARTED}"
  else
    : > "${STARTED}"
  fi
}

# @description Poll until a file exists and is non-empty.
# @arg $1 path the file to wait for
# @exitcode 0 it appeared
# @exitcode 1 it did not appear in time
function wait_for_file() {
  local ticks=0
  while [[ ! -s "$1" ]]; do
    ticks="$((ticks + 1))"
    if ((ticks > WAIT_TICKS)); then
      return 1
    fi
    sleep 0.1
  done
}

# @description Poll until a pid stops answering `kill -0`, then forget it.
# @arg $1 pid the process id
# @exitcode 0 it is gone
# @exitcode 1 it is still there after the timeout
function wait_for_exit() {
  local ticks=0
  while kill -0 "$1" 2> '/dev/null'; do
    ticks="$((ticks + 1))"
    if ((ticks > WAIT_TICKS)); then
      return 1
    fi
    sleep 0.1
  done
  forget_pid "$1"
}

# @description Fail unless a recorded command has ended; then forget its pid.
# @arg $1 pid the process id
function assert_gone() {
  if kill -0 "$1" 2> '/dev/null'; then
    fail "the command (pid $1) is still running"
  fi
  forget_pid "$1"
}

# @description Fail unless a directory is empty, naming what was left in it.
# @arg $1 dir the directory
function assert_empty_dir() {
  local left
  left="$(find "$1" -mindepth 1 -maxdepth 1 -printf '%f ')"
  if [[ -n "${left}" ]]; then
    fail "left behind in $1: ${left}"
  fi
}

# @description Run the wrapper outside the devShell boundary with the given
#              TMPDIR, stdin from /dev/null.
# @arg $1 tmpdir the TMPDIR the caller hands the wrapper
# @arg $@ command the command to wrap, after the TMPDIR
function wrap() {
  local -r tmpdir="$1"
  shift
  env --unset=IN_DEVSHELL --unset=GIT_CEILING_DIRECTORIES TMPDIR="${tmpdir}" \
    "${WRAPPER}" "$@" < '/dev/null'
}

@test "in-devshell: a wrapped true succeeds and leaves TMPDIR empty" {
  cd "${REPO_DIR}"
  run wrap "${SCRATCH}" true
  assert_success
  assert_empty_dir "${SCRATCH}"
}

@test "in-devshell: the command's exit status is the wrapper's" {
  cd "${REPO_DIR}"
  run wrap "${SCRATCH}" sh -c 'exit 3'
  assert_failure 3
  assert_empty_dir "${SCRATCH}"
}

@test "in-devshell: the command sees a private TMPDIR inside the caller's" {
  cd "${REPO_DIR}"
  # shellcheck disable=SC2016 # expanded by the wrapped sh, not here
  run wrap "${SCRATCH}" sh -c 'printf "TMPDIR=%s\n" "${TMPDIR}"'
  assert_success
  assert_line --regexp "^TMPDIR=${SCRATCH}/.+"
  assert_empty_dir "${SCRATCH}"
}

@test "in-devshell: a relative caller TMPDIR that exists is made absolute" {
  local rel
  cd "${REPO_DIR}"
  rel="$(realpath --relative-to="${REPO_DIR}" -- "${SCRATCH}")"
  # shellcheck disable=SC2016 # expanded by the wrapped sh, not here
  run wrap "${rel}" sh -c 'printf "TMPDIR=%s\n" "${TMPDIR}"'
  assert_success
  assert_line --regexp "^TMPDIR=${SCRATCH}/.+"
  assert_empty_dir "${SCRATCH}"
}

@test "in-devshell: a caller TMPDIR naming no directory fails with one line and creates nothing" {
  local value
  cd "${BATS_TEST_TMPDIR}"
  for value in "${BATS_TEST_TMPDIR}/does-not-exist" 'does-not-exist-relative'; do
    run wrap "${value}" true
    assert_failure 1
    assert_equal "${#lines[@]}" 1
    assert_output --partial "TMPDIR ${value} names no directory"
    [[ ! -e "${value}" ]]
  done
  assert_empty_dir "${SCRATCH}"
}

@test "in-devshell: the devShell is the wrapper's own repo, whatever the caller's cwd" {
  # A directory outside any git repository: the wrapper finds its flake from
  # where it lives, not from where it is called.
  mkdir -- "${BATS_TEST_TMPDIR}/elsewhere"
  cd "${BATS_TEST_TMPDIR}/elsewhere"
  # shellcheck disable=SC2016 # expanded by the wrapped sh, not here
  run wrap "${SCRATCH}" sh -c 'printf "IN_DEVSHELL=%s\n" "${IN_DEVSHELL:-}"; exit 4'
  assert_failure 4
  assert_line 'IN_DEVSHELL=1'
  assert_empty_dir "${SCRATCH}"
}

@test "in-devshell: with GIT_DIR set, as git sets it for a hook, the devShell is still the wrapper's repo" {
  # With GIT_DIR set and no GIT_WORK_TREE, `git rev-parse --show-toplevel`
  # answers with the current directory, whatever directory that is.
  local git_dir
  git_dir="$(git -C "${REPO_DIR}" rev-parse --absolute-git-dir)"
  mkdir -- "${BATS_TEST_TMPDIR}/elsewhere"
  cd "${BATS_TEST_TMPDIR}/elsewhere"
  # shellcheck disable=SC2016 # expanded by the wrapped sh, not here
  run env --unset=IN_DEVSHELL --unset=GIT_CEILING_DIRECTORIES GIT_DIR="${git_dir}" TMPDIR="${SCRATCH}" \
    "${WRAPPER}" sh -c 'printf "IN_DEVSHELL=%s\n" "${IN_DEVSHELL:-}"; exit 4' < '/dev/null'
  assert_failure 4
  assert_line 'IN_DEVSHELL=1'
  assert_empty_dir "${SCRATCH}"
}

# The signal cases start the wrapper as a plain background command, not through
# `wrap`: bash forks once and env execs the wrapper, so `$!` is the wrapper's
# own pid. A function run in the background would put a subshell in between.

@test "in-devshell: SIGINT to the process group ends the command and leaves TMPDIR empty" {
  local wrapper_pid cmd_pid
  cd "${REPO_DIR}"
  # Job control gives the background wrapper a process group of its own, so
  # the signal below reaches only the processes this case started.
  set -m
  # shellcheck disable=SC2016 # expanded by the wrapped sh, not here
  env --unset=IN_DEVSHELL --unset=GIT_CEILING_DIRECTORIES TMPDIR="${SCRATCH}" "${WRAPPER}" \
    sh -c 'echo $$ > "$1"; exec sleep 300' sh "${BATS_TEST_TMPDIR}/cmd.pid" \
    < '/dev/null' > "${BATS_TEST_TMPDIR}/out" 2>&1 3>&- &
  wrapper_pid="$!"
  set +m
  remember_pid "${wrapper_pid}"
  wait_for_file "${BATS_TEST_TMPDIR}/cmd.pid" \
    || fail "the command never started: $(< "${BATS_TEST_TMPDIR}/out")"
  cmd_pid="$(< "${BATS_TEST_TMPDIR}/cmd.pid")"
  remember_pid "${cmd_pid}"
  kill -s INT -- "-${wrapper_pid}"
  wait_for_exit "${wrapper_pid}" || fail 'the wrapper did not end'
  assert_gone "${cmd_pid}"
  assert_empty_dir "${SCRATCH}"
}

@test "in-devshell: a command that traps INT outlives a Ctrl-C and keeps its TMPDIR until it exits" {
  local wrapper_pid cmd_pid
  cd "${REPO_DIR}"
  set -m
  # shellcheck disable=SC2016 # expanded by the wrapped sh, not here
  env --unset=IN_DEVSHELL --unset=GIT_CEILING_DIRECTORIES TMPDIR="${SCRATCH}" "${WRAPPER}" \
    sh -c 'trap "echo caught > \"\$2\"" INT; echo $$ > "$1"; while [ ! -e "$3" ]; do sleep 0.1; done' \
    sh "${BATS_TEST_TMPDIR}/cmd.pid" "${BATS_TEST_TMPDIR}/caught" "${BATS_TEST_TMPDIR}/release" \
    < '/dev/null' > "${BATS_TEST_TMPDIR}/out" 2>&1 3>&- &
  wrapper_pid="$!"
  set +m
  remember_pid "${wrapper_pid}"
  wait_for_file "${BATS_TEST_TMPDIR}/cmd.pid" \
    || fail "the command never started: $(< "${BATS_TEST_TMPDIR}/out")"
  cmd_pid="$(< "${BATS_TEST_TMPDIR}/cmd.pid")"
  remember_pid "${cmd_pid}"
  kill -s INT -- "-${wrapper_pid}"
  wait_for_file "${BATS_TEST_TMPDIR}/caught" || fail 'the command never saw the signal'
  kill -0 "${wrapper_pid}" 2> '/dev/null' || fail 'the wrapper died on the first INT'
  kill -0 "${cmd_pid}" 2> '/dev/null' || fail 'the command died on the first INT'
  if [[ -z "$(find "${SCRATCH}" -mindepth 1 -maxdepth 1)" ]]; then
    fail 'the private TMPDIR was removed under a running command'
  fi
  : > "${BATS_TEST_TMPDIR}/release"
  wait_for_exit "${wrapper_pid}" || fail 'the wrapper did not end after the command did'
  assert_gone "${cmd_pid}"
  assert_empty_dir "${SCRATCH}"
}

@test "in-devshell: SIGTERM to the wrapper alone gives 143 and leaves TMPDIR empty" {
  local wrapper_pid cmd_pid rc=0
  cd "${REPO_DIR}"
  # shellcheck disable=SC2016 # expanded by the wrapped sh, not here
  env --unset=IN_DEVSHELL --unset=GIT_CEILING_DIRECTORIES TMPDIR="${SCRATCH}" "${WRAPPER}" \
    sh -c 'echo $$ > "$1"; exec sleep 300' sh "${BATS_TEST_TMPDIR}/cmd.pid" \
    < '/dev/null' > "${BATS_TEST_TMPDIR}/out" 2>&1 3>&- &
  wrapper_pid="$!"
  remember_pid "${wrapper_pid}"
  wait_for_file "${BATS_TEST_TMPDIR}/cmd.pid" \
    || fail "the command never started: $(< "${BATS_TEST_TMPDIR}/out")"
  cmd_pid="$(< "${BATS_TEST_TMPDIR}/cmd.pid")"
  remember_pid "${cmd_pid}"
  kill -s TERM "${wrapper_pid}"
  wait "${wrapper_pid}" || rc="$?"
  forget_pid "${wrapper_pid}"
  assert_equal "${rc}" 143
  assert_gone "${cmd_pid}"
  assert_empty_dir "${SCRATCH}"
}

@test "in-devshell: a command that handles a forwarded SIGTERM reports its own status" {
  local wrapper_pid cmd_pid rc=0
  cd "${REPO_DIR}"
  # shellcheck disable=SC2016 # expanded by the wrapped sh, not here
  env --unset=IN_DEVSHELL --unset=GIT_CEILING_DIRECTORIES TMPDIR="${SCRATCH}" "${WRAPPER}" \
    sh -c 'trap "kill \$! 2> /dev/null; exit 0" TERM; echo $$ > "$1"; sleep 300 & wait' \
    sh "${BATS_TEST_TMPDIR}/cmd.pid" \
    < '/dev/null' > "${BATS_TEST_TMPDIR}/out" 2>&1 3>&- &
  wrapper_pid="$!"
  remember_pid "${wrapper_pid}"
  wait_for_file "${BATS_TEST_TMPDIR}/cmd.pid" \
    || fail "the command never started: $(< "${BATS_TEST_TMPDIR}/out")"
  cmd_pid="$(< "${BATS_TEST_TMPDIR}/cmd.pid")"
  remember_pid "${cmd_pid}"
  kill -s TERM "${wrapper_pid}"
  wait "${wrapper_pid}" || rc="$?"
  forget_pid "${wrapper_pid}"
  assert_equal "${rc}" 0
  assert_gone "${cmd_pid}"
  assert_empty_dir "${SCRATCH}"
}

@test "in-devshell: SIGHUP to the wrapper alone gives 129 and leaves TMPDIR empty" {
  local wrapper_pid cmd_pid rc=0
  cd "${REPO_DIR}"
  # shellcheck disable=SC2016 # expanded by the wrapped sh, not here
  env --unset=IN_DEVSHELL --unset=GIT_CEILING_DIRECTORIES TMPDIR="${SCRATCH}" "${WRAPPER}" \
    sh -c 'echo $$ > "$1"; exec sleep 300' sh "${BATS_TEST_TMPDIR}/cmd.pid" \
    < '/dev/null' > "${BATS_TEST_TMPDIR}/out" 2>&1 3>&- &
  wrapper_pid="$!"
  remember_pid "${wrapper_pid}"
  wait_for_file "${BATS_TEST_TMPDIR}/cmd.pid" \
    || fail "the command never started: $(< "${BATS_TEST_TMPDIR}/out")"
  cmd_pid="$(< "${BATS_TEST_TMPDIR}/cmd.pid")"
  remember_pid "${cmd_pid}"
  kill -s HUP "${wrapper_pid}"
  wait "${wrapper_pid}" || rc="$?"
  forget_pid "${wrapper_pid}"
  assert_equal "${rc}" 129
  assert_gone "${cmd_pid}"
  assert_empty_dir "${SCRATCH}"
}

@test "in-devshell: a command that handles a forwarded SIGHUP reports its own status" {
  local wrapper_pid cmd_pid rc=0
  cd "${REPO_DIR}"
  # shellcheck disable=SC2016 # expanded by the wrapped sh, not here
  env --unset=IN_DEVSHELL --unset=GIT_CEILING_DIRECTORIES TMPDIR="${SCRATCH}" "${WRAPPER}" \
    sh -c 'trap "kill \$! 2> /dev/null; exit 0" HUP; echo $$ > "$1"; sleep 300 & wait' \
    sh "${BATS_TEST_TMPDIR}/cmd.pid" \
    < '/dev/null' > "${BATS_TEST_TMPDIR}/out" 2>&1 3>&- &
  wrapper_pid="$!"
  remember_pid "${wrapper_pid}"
  wait_for_file "${BATS_TEST_TMPDIR}/cmd.pid" \
    || fail "the command never started: $(< "${BATS_TEST_TMPDIR}/out")"
  cmd_pid="$(< "${BATS_TEST_TMPDIR}/cmd.pid")"
  remember_pid "${cmd_pid}"
  kill -s HUP "${wrapper_pid}"
  wait "${wrapper_pid}" || rc="$?"
  forget_pid "${wrapper_pid}"
  assert_equal "${rc}" 0
  assert_gone "${cmd_pid}"
  assert_empty_dir "${SCRATCH}"
}
