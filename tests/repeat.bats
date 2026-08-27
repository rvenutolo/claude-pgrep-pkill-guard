setup() {
  load 'test_helper/common'
  # Every repeat-tier case is redirected into a per-test temp dir. This export
  # and the hook's own read of the same name must always be renamed in ONE
  # commit: flip only one and the suite writes real state into the author's
  # live ${XDG_RUNTIME_DIR} while asserting against an empty temp dir.
  STATE_DIR="${BATS_TEST_TMPDIR}/state"
  mkdir -p "${STATE_DIR}"
  export PGREP_PKILL_GUARD_STATE_DIR="${STATE_DIR}"
  TASK_BASE='/tmp/claude-1000/-home-u-proj/0b9df07e-7ed4-4c6e-99fa-4dd2deb783de/tasks'
  TASK_PATH="${TASK_BASE}/bcuxbdgc5.output"
}

@test "repeat: no session id means no rule and no state" {
  local i json
  for i in 1 2 3; do
    json="$(run_hook "cat ${TASK_PATH}")"
    [ "$(decision_of "${json}")" = 'none' ]
  done
  # The rule is skipped entirely, so nothing may be written.
  run find "${STATE_DIR}" -mindepth 1 -maxdepth 1
  assert_output ''
}

@test "repeat: a session id that is not a plain file name is rejected" {
  local json
  json="$(run_hook "cat ${TASK_PATH}" '../escape')"
  [ "$(decision_of "${json}")" = 'none' ]
  json="$(run_hook "cat ${TASK_PATH}" 'a/b')"
  [ "$(decision_of "${json}")" = 'none' ]
  [ ! -e "${STATE_DIR}/../escape" ]
  run find "${STATE_DIR}" -mindepth 1 -maxdepth 1
  assert_output ''
}

@test "repeat: the third probe of one path denies, and so does the fourth" {
  local i json decision reason needle
  for i in 1 2 3 4; do
    json="$(run_hook "cat ${TASK_PATH}" 's1')"
    decision="$(decision_of "${json}")"
    if [ "${i}" -ge 3 ]; then
      [ "${decision}" = 'deny' ]
      reason="$(reason_of "${json}")"
    else
      [ "${decision}" = 'none' ]
    fi
  done
  for needle in 'probe 3' '300 s' 'TaskOutput' 'block: true' 'If this command WRITES' \
    "task:${TASK_PATH#/tmp/}"; do
    [[ "${reason}" == *"${needle}"* ]] || {
      echo "reason lacks '${needle}': ${reason:0:200}" >&2
      return 1
    }
  done
  # A denied command is not recorded: probes 3 and 4 both denied, so the file
  # still holds only the two lines written by probes 1 and 2.
  run wc -l < "${STATE_DIR}/s1"
  assert_output --regexp '^[[:space:]]*2$'
}

@test "repeat: three different task files are three first reads" {
  local name json
  for name in a1 a2 a3; do
    json="$(run_hook "cat ${TASK_BASE}/${name}.output" 's3')"
    [ "$(decision_of "${json}")" = 'none' ]
  done
}

@test "repeat: sessions do not share state" {
  local suffix json
  for suffix in a b c; do
    json="$(run_hook "cat ${TASK_PATH}" "s4${suffix}")"
    [ "$(decision_of "${json}")" = 'none' ]
  done
}

@test "repeat: entries older than the window are pruned before counting" {
  local now key json
  now="$(date +%s)"
  key="task:${TASK_PATH#/tmp/}"
  printf '%s\t%s\n%s\t%s\n' "$((now - 400))" "${key}" "$((now - 400))" "${key}" > "${STATE_DIR}/s5"
  json="$(run_hook "cat ${TASK_PATH}" 's5')"
  [ "$(decision_of "${json}")" = 'none' ]
  run wc -l < "${STATE_DIR}/s5"
  assert_output --regexp '^[[:space:]]*1$'
}

@test "repeat: a corrupt state file allows and is healed" {
  local json key
  key="task:${TASK_PATH#/tmp/}"
  # Includes a leading-zero epoch (08): a valid-looking decimal but an invalid
  # octal literal to (( )), so it must be rejected by the epoch regex rather
  # than reaching arithmetic and printing "value too great for base".
  printf 'garbage\n\tno-epoch\n12x\ttask:foo\n08\ttask:foo\n' > "${STATE_DIR}/s6"
  json="$(run_hook "cat ${TASK_PATH}" 's6')"
  [ "$(decision_of "${json}")" = 'none' ]
  run cat "${STATE_DIR}/s6"
  assert_output --regexp "^[0-9]+	${key}$"
}

@test "repeat: a state file that is a directory allows every time" {
  local i json
  mkdir "${STATE_DIR}/s7"
  for i in 1 2 3; do
    json="$(run_hook "cat ${TASK_PATH}" 's7')"
    [ "$(decision_of "${json}")" = 'none' ]
  done
}

@test "repeat: an unwritable state dir allows every time" {
  local i json
  chmod 500 "${STATE_DIR}"
  if [ -w "${STATE_DIR}" ] && touch "${STATE_DIR}/.probe" 2> /dev/null; then
    rm -f -- "${STATE_DIR}/.probe"
    chmod 700 "${STATE_DIR}"
    skip 'running as root; mode bits are not enforced'
  fi
  for i in 1 2 3; do
    json="$(run_hook "cat ${TASK_PATH}" 's8')"
    [ "$(decision_of "${json}")" = 'none' ]
  done
  chmod 700 "${STATE_DIR}"
}

@test "repeat: a pgrep operand is a probe key and the reason names the PID probe" {
  local i json decision reason needle
  for i in 1 2 3; do
    json="$(run_hook 'pgrep -f java' 's11')"
    decision="$(decision_of "${json}")"
    if [ "${i}" -eq 3 ]; then
      [ "${decision}" = 'deny' ]
      reason="$(reason_of "${json}")"
    else
      [ "${decision}" = 'none' ]
    fi
  done
  for needle in 'kill -0' 'pgrep:java' 'TaskOutput'; do
    [[ "${reason}" == *"${needle}"* ]] || {
      echo "reason lacks '${needle}': ${reason:0:200}" >&2
      return 1
    }
  done
}

@test "repeat: a warn-tier command is still a probe; warn plus repeat denies" {
  local i json decision
  for i in 1 2 3; do
    json="$(run_hook 'pgrep --full x | wc -l' 's12')"
    decision="$(decision_of "${json}")"
    if [ "${i}" -eq 3 ]; then
      [ "${decision}" = 'deny' ]
    else
      [ "${decision}" = 'allow' ]
    fi
  done
}

@test "repeat: a stateless deny is never recorded" {
  local i json
  for i in 1 2 3; do
    json="$(run_hook 'pkill --full java' 's13')"
    [ "$(decision_of "${json}")" = 'deny' ]
  done
  [ ! -e "${STATE_DIR}/s13" ]
}

@test "repeat: two probes of one key in one command collapse to one entry" {
  local json
  json="$(run_hook 'pgrep -f java; pgrep -f java' 's14')"
  [ "$(decision_of "${json}")" = 'none' ]
  run wc -l < "${STATE_DIR}/s14"
  assert_output --regexp '^[[:space:]]*1$'
}

@test "repeat: a state dir that is itself a symlink is refused, not followed" {
  local json link="${BATS_TEST_TMPDIR}/state.link"
  ln -s "${STATE_DIR}" "${link}"
  json="$(PGREP_PKILL_GUARD_STATE_DIR="${link}" run_hook "cat ${TASK_PATH}" 's15')"
  [ "$(decision_of "${json}")" = 'none' ]
  [ ! -e "${STATE_DIR}/s15" ]
}

@test "repeat: pkill is never a probe key, even under --ignore-ancestors" {
  local i json
  for i in 1 2 3; do
    json="$(run_hook 'pkill --ignore-ancestors --full java' 's17')"
    [ "$(decision_of "${json}")" = 'none' ]
  done
  [ ! -e "${STATE_DIR}/s17" ]
}

@test "repeat: a pgrep inside a wrapper payload is invisible to the repeat tier" {
  local i json
  # Documented limit, pinned here rather than changed: probe_keys, unlike
  # classify_command, does not descend into shell_wrapper_payloads.
  for i in 1 2 3; do
    json="$(run_hook "bash -c 'pgrep -f java'" 's18')"
    [ "$(decision_of "${json}")" = 'none' ]
  done
  [ ! -e "${STATE_DIR}/s18" ]
}

@test "repeat: an oversized state file is refused and left untouched" {
  local i now key json
  now="$(date +%s)"
  key="task:${TASK_PATH#/tmp/}"
  for ((i = 0; i < 6000; i++)); do
    printf '%s\t%s\n' "${now}" "${key}"
  done > "${STATE_DIR}/s16"
  json="$(run_hook "cat ${TASK_PATH}" 's16')"
  [ "$(decision_of "${json}")" = 'none' ]
  # REPEAT_MAX_ENTRIES caps the read, and bailing there never reaches the write.
  run wc -l < "${STATE_DIR}/s16"
  assert_output --regexp '^[[:space:]]*6000$'
}
