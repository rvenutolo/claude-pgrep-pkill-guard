setup() {
  load 'test_helper/common'
}

@test "harness: bats-assert is loaded" {
  run echo 'hello'
  assert_success
  assert_output 'hello'
}

@test "harness: repo root resolves" {
  [ -f "${REPO_DIR}/flake.nix" ]
}
