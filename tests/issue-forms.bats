setup() {
  load 'test_helper/common'
  CHECK="${REPO_DIR}/.ci/check-issue-forms"
  FORMS_DIR="${REPO_DIR}/.github/ISSUE_TEMPLATE"
}

# @description Build a minimal, VALID fixture directory -- one config.yml and
#              one form exercising every body type the checker knows -- so each
#              negative case can corrupt exactly one thing. POSIX short flags on
#              purpose: the compat CI legs run this suite against macOS BSD
#              coreutils, whose mkdir has no --parents.
# @arg $1 root directory to populate
function make_form_fixture() {
  local -r root="$1"
  mkdir -p "${root}"
  cat > "${root}/config.yml" << 'YAML'
blank_issues_enabled: false
contact_links:
  - name: Somewhere else
    url: https://example.com/elsewhere
    about: A link the chooser shows alongside the forms.
YAML
  cat > "${root}/report.yml" << 'YAML'
name: Report
description: A fixture form that satisfies every rule the checker enforces.
labels: [bug]
body:
  - type: markdown
    attributes:
      value: Read this before filing.
  - type: textarea
    id: what-happened
    attributes:
      label: What happened?
    validations:
      required: true
  - type: input
    id: version
    attributes:
      label: Version
  - type: dropdown
    id: kind
    attributes:
      label: Which kind is it?
      options:
        - The first kind
        - The second kind
  - type: checkboxes
    id: confirmations
    attributes:
      label: Confirmations
      options:
        - label: I redacted absolute paths.
YAML
}

@test "issue forms: the real .github/ISSUE_TEMPLATE passes" {
  # FORMS_DIR explicitly rather than relying on the argument-less default: the
  # default resolves through `git rev-parse`, and a bats test must not depend
  # on the working directory the suite happened to be launched from. The
  # argument-less path is exercised by run-all-checks on every gate run.
  run "${CHECK}" "${FORMS_DIR}"
  assert_success
}

@test "issue forms: a valid fixture passes" {
  make_form_fixture "${BATS_TEST_TMPDIR}/ok"
  run "${CHECK}" "${BATS_TEST_TMPDIR}/ok"
  assert_success
}

@test "issue forms: a form with no body is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/no-body"
  make_form_fixture "${root}"
  cat > "${root}/report.yml" << 'YAML'
name: Report
description: A form that forgot its body.
YAML
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'report.yml: body is missing or is not a non-empty sequence'
}

@test "issue forms: a body item with an unrecognised type is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/bad-type"
  make_form_fixture "${root}"
  cat > "${root}/report.yml" << 'YAML'
name: Report
description: A form whose second body item has a type GitHub does not know.
body:
  - type: markdown
    attributes:
      value: Read this before filing.
  - type: texarea
    id: what-happened
    attributes:
      label: What happened?
YAML
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'report.yml: body[1] has an unrecognised type: texarea'
}

@test "issue forms: two body items sharing an id are rejected" {
  local -r root="${BATS_TEST_TMPDIR}/dup-id"
  make_form_fixture "${root}"
  cat > "${root}/report.yml" << 'YAML'
name: Report
description: A form that reuses one id across two body items.
body:
  - type: input
    id: version
    attributes:
      label: bash version
  - type: input
    id: version
    attributes:
      label: awk version
YAML
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'report.yml: body id is not unique within the file: version'
}

@test "issue forms: a config.yml without blank_issues_enabled is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/no-blank-issues"
  make_form_fixture "${root}"
  cat > "${root}/config.yml" << 'YAML'
contact_links:
  - name: Somewhere else
    url: https://example.com/elsewhere
    about: A link the chooser shows alongside the forms.
YAML
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'config.yml: blank_issues_enabled is missing or is not a boolean'
}

@test "issue forms: a directory holding config.yml but no form is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/empty-scan"
  make_form_fixture "${root}"
  # The empty-scan guard: with only config.yml left, a checker that merely
  # iterated the forms it found would report nothing and exit 0.
  rm -f -- "${root}/report.yml"
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'holds no issue form (a *.yml other than config.yml)'
}

# @description Write a labels file declaring exactly the names given, so a case
#              can assert the mismatch rather than depending on the real
#              .github/labels.yml. POSIX short flags on purpose -- see the
#              header of tests/manifest.bats.
# @arg $1 path the labels file to write
# @arg $@ rest label names to declare
function make_labels_fixture() {
  local -r path="$1"
  shift
  mkdir -p "$(dirname "${path}")"
  : > "${path}"
  local name
  for name in "$@"; do
    printf -- '- name: %s\n  color: ededed\n  description: A fixture label.\n' "${name}" >> "${path}"
  done
}

@test "issue forms: the real forms reference only declared labels" {
  run "${CHECK}" "${FORMS_DIR}" "${REPO_DIR}/.github/labels.yml"
  assert_success
}

@test "issue forms: a form referencing an undeclared label is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/undeclared"
  make_form_fixture "${root}"
  make_labels_fixture "${BATS_TEST_TMPDIR}/labels-undeclared.yml" 'enhancement'
  run "${CHECK}" "${root}" "${BATS_TEST_TMPDIR}/labels-undeclared.yml"
  assert_failure
  assert_output --partial 'references label "bug"'
}

@test "issue forms: a label whose name is a substring of a declared one is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/substring"
  make_form_fixture "${root}"
  make_labels_fixture "${BATS_TEST_TMPDIR}/labels-substring.yml" 'bugs'
  run "${CHECK}" "${root}" "${BATS_TEST_TMPDIR}/labels-substring.yml"
  assert_failure
}

@test "issue forms: a label name holding a space is matched whole, not by word" {
  local -r root="${BATS_TEST_TMPDIR}/spaced"
  make_form_fixture "${root}"
  # The fixture form declares `labels: [bug]`; rewrite it to reference a name
  # with a space, which is what makes the --line-regexp --fixed-strings match
  # load-bearing rather than incidental.
  sed -i.bak 's/^labels: \[bug\]$/labels: [good first issue]/' "${root}/report.yml"
  rm -f "${root}/report.yml.bak"
  make_labels_fixture "${BATS_TEST_TMPDIR}/labels-spaced.yml" 'good first issue'
  run "${CHECK}" "${root}" "${BATS_TEST_TMPDIR}/labels-spaced.yml"
  assert_success
}

@test "issue forms: a missing labels file is rejected, not ignored" {
  local -r root="${BATS_TEST_TMPDIR}/no-labels"
  make_form_fixture "${root}"
  run "${CHECK}" "${root}" "${BATS_TEST_TMPDIR}/absent.yml"
  assert_failure
  assert_output --partial 'does not exist'
  refute_output --partial 'ERROR: line'
}

@test "issue forms: a labels file declaring nothing is rejected, not a vacuous pass" {
  local -r root="${BATS_TEST_TMPDIR}/empty-labels"
  make_form_fixture "${root}"
  make_labels_fixture "${BATS_TEST_TMPDIR}/labels-empty.yml"
  run "${CHECK}" "${root}" "${BATS_TEST_TMPDIR}/labels-empty.yml"
  assert_failure
  assert_output --partial 'declares no labels'
  refute_output --partial 'ERROR: line'
}
