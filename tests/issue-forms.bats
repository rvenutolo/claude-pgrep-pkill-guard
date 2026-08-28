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
