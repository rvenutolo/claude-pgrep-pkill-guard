setup() {
  load 'test_helper/common'
  CHECK="${REPO_DIR}/.ci/check-bats-libs-in-sync"
  ACTION_YML="${REPO_DIR}/.github/actions/bats-ambient/action.yml"
  LOCK_JSON="${REPO_DIR}/flake.lock"
}

# @description Copy the real action.yml and flake.lock into a fixture directory
#              so a case can corrupt exactly one SHA and leave everything else
#              byte-identical to the tree under test. Copying rather than
#              synthesising is deliberate: a hand-written fixture would pin the
#              file SHAPE this checker reads, and the shape is exactly what a
#              future edit to action.yml might change. POSIX short flags on
#              purpose -- the compat CI legs run this suite against macOS BSD
#              coreutils, whose mkdir has no --parents.
# @arg $1 root directory to populate
# @set FIXTURE_ACTION path to the fixture action.yml
# @set FIXTURE_LOCK path to the fixture flake.lock
function make_fixture() {
  local -r root="$1"
  mkdir -p "${root}"
  cp "${ACTION_YML}" "${root}/action.yml"
  cp "${LOCK_JSON}" "${root}/flake.lock"
  FIXTURE_ACTION="${root}/action.yml"
  FIXTURE_LOCK="${root}/flake.lock"
}

# @description Overwrite one BATS_*_SHA in the fixture action.yml with a SHA
#              that is well-formed but wrong, so the case grades the COMPARISON
#              rather than the shape validation.
# @arg $1 var the env var name
function plant_mismatch() {
  local -r var="$1"
  sed -i.bak "s/^\( *${var}: \).*/\1'0123456789abcdef0123456789abcdef01234567'/" "${FIXTURE_ACTION}"
  rm -f "${FIXTURE_ACTION}.bak"
}

@test "bats libs in sync: the real repo passes" {
  run "${CHECK}" "${ACTION_YML}" "${LOCK_JSON}"
  assert_success
}

@test "bats libs in sync: an unchanged fixture passes" {
  make_fixture "${BATS_TEST_TMPDIR}/ok"
  run "${CHECK}" "${FIXTURE_ACTION}" "${FIXTURE_LOCK}"
  assert_success
}

@test "bats libs in sync: a drifted bats-support SHA is rejected" {
  make_fixture "${BATS_TEST_TMPDIR}/support"
  plant_mismatch 'BATS_SUPPORT_SHA'
  run "${CHECK}" "${FIXTURE_ACTION}" "${FIXTURE_LOCK}"
  assert_failure
  assert_output --partial 'bats-support'
}

@test "bats libs in sync: a drifted bats-assert SHA is rejected" {
  make_fixture "${BATS_TEST_TMPDIR}/assert"
  plant_mismatch 'BATS_ASSERT_SHA'
  run "${CHECK}" "${FIXTURE_ACTION}" "${FIXTURE_LOCK}"
  assert_failure
  assert_output --partial 'bats-assert'
}

@test "bats libs in sync: both mismatches are reported in one run" {
  make_fixture "${BATS_TEST_TMPDIR}/both"
  plant_mismatch 'BATS_SUPPORT_SHA'
  plant_mismatch 'BATS_ASSERT_SHA'
  run "${CHECK}" "${FIXTURE_ACTION}" "${FIXTURE_LOCK}"
  assert_failure
  assert_output --partial 'bats-support'
  assert_output --partial 'bats-assert'
}

@test "bats libs in sync: a malformed SHA is rejected as malformed" {
  make_fixture "${BATS_TEST_TMPDIR}/malformed"
  sed -i.bak "s/^\( *BATS_SUPPORT_SHA: \).*/\1'not-a-sha'/" "${FIXTURE_ACTION}"
  rm -f "${FIXTURE_ACTION}.bak"
  run "${CHECK}" "${FIXTURE_ACTION}" "${FIXTURE_LOCK}"
  assert_failure
  assert_output --partial 'not a 40-character SHA'
}

@test "bats libs in sync: a missing action file fails cleanly" {
  make_fixture "${BATS_TEST_TMPDIR}/missing"
  rm -f "${FIXTURE_ACTION}"
  run "${CHECK}" "${FIXTURE_ACTION}" "${FIXTURE_LOCK}"
  assert_failure
  assert_output --partial 'does not exist'
  refute_output --partial 'ERROR: line'
}

@test "bats libs in sync: a flake.lock with the node removed is rejected" {
  make_fixture "${BATS_TEST_TMPDIR}/no-node"
  jq 'del(.nodes["bats-assert"])' "${FIXTURE_LOCK}" > "${FIXTURE_LOCK}.new"
  mv -f "${FIXTURE_LOCK}.new" "${FIXTURE_LOCK}"
  run "${CHECK}" "${FIXTURE_ACTION}" "${FIXTURE_LOCK}"
  assert_failure
  assert_output --partial 'bats-assert'
}
