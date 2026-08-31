setup() {
  load 'test_helper/common'
  PLUGIN_JSON="${REPO_DIR}/.claude-plugin/plugin.json"
}

# The human-facing surface of hooks/pgrep-pkill-guard.sh: --help, --version, and
# the two usage errors. Driven ONLY as a subprocess (invariant 3) -- nothing here
# sources the hook or calls human_mode/print_help directly, because the thing
# worth pinning is what a person at a terminal actually sees.
#
# POSIX short flags on purpose -- see the header of tests/manifest.bats.

# @description Run the guard as a subprocess and capture its two streams into
#              SEPARATE files, so a test can assert one is empty without the
#              other's bytes leaking into it. bats' `run` merges them by default.
#
#              stdin is redirected from /dev/null rather than inherited. The
#              entry script dispatches into human mode on `(($# > 0)) ||
#              [[ -t 0 ]]`, so a test that inherited the bats runner's terminal
#              would silently turn every case below into the TTY case -- and,
#              worse, a test with NO arguments would then pass for the wrong
#              reason. Explicit is the only safe form here.
# @arg $1 tag basename for the capture files under BATS_TEST_TMPDIR
# @arg $@ rest arguments forwarded to the script verbatim
# @set CLI_STDOUT path to the captured stdout
# @set CLI_STDERR path to the captured stderr
# @set CLI_STATUS the script's exit status
function run_cli() {
  local -r tag="$1"
  shift
  CLI_STDOUT="${BATS_TEST_TMPDIR}/${tag}.out"
  CLI_STDERR="${BATS_TEST_TMPDIR}/${tag}.err"
  CLI_STATUS=0
  "${HOOK}" "$@" < /dev/null > "${CLI_STDOUT}" 2> "${CLI_STDERR}" || CLI_STATUS=$?
}

@test "cli: --help prints help on stdout, exits 0, and says nothing on stderr" {
  run_cli help --help
  [ "${CLI_STATUS}" -eq 0 ]
  [ -s "${CLI_STDOUT}" ]
  # Help is not a diagnostic: it was asked for, so it belongs on stdout and
  # stderr must stay clean enough to pipe (`--help | less`) without noise.
  [ ! -s "${CLI_STDERR}" ]
  # A usage line first, per the spec's ordering. Asserting the shape rather than
  # the whole line keeps this from breaking on a wording tweak.
  IFS= read -r first_line < "${CLI_STDOUT}"
  [[ "${first_line}" == 'Usage: '* ]]
}

@test "cli: -h produces byte-identical output to --help" {
  # Byte-identical, not merely "also non-empty": two spellings of one flag that
  # drifted apart would be a bug no looser assertion could see.
  run_cli long --help
  [ "${CLI_STATUS}" -eq 0 ]
  run_cli short -h
  [ "${CLI_STATUS}" -eq 0 ]
  cmp -s "${BATS_TEST_TMPDIR}/long.out" "${BATS_TEST_TMPDIR}/short.out"
}

@test "cli: --help wins over an unknown argument in either position" {
  # clig.dev: -h/--help prints help and ignores everything else, whatever the
  # order. Both orders matter -- a naive `case "$1"` dispatch handles the first
  # and errors on the second.
  run_cli baseline --help
  [ "${CLI_STATUS}" -eq 0 ]

  run_cli help_first --help --bogus
  [ "${CLI_STATUS}" -eq 0 ]
  [ ! -s "${BATS_TEST_TMPDIR}/help_first.err" ]
  cmp -s "${BATS_TEST_TMPDIR}/baseline.out" "${BATS_TEST_TMPDIR}/help_first.out"

  run_cli help_last --bogus --help
  [ "${CLI_STATUS}" -eq 0 ]
  [ ! -s "${BATS_TEST_TMPDIR}/help_last.err" ]
  cmp -s "${BATS_TEST_TMPDIR}/baseline.out" "${BATS_TEST_TMPDIR}/help_last.out"
}

@test "cli: help states the stdin contract, the state dir, and the probe recipe" {
  run_cli contract --help
  [ "${CLI_STATUS}" -eq 0 ]
  # The three things a person running this by hand actually came for: what the
  # script reads, the one environment variable that changes its behaviour, and
  # the copy-pasteable recipe the README's "Reporting a false verdict" tells
  # them to use. Help that omits any of them is help in name only.
  grep -q -F 'stdin' "${CLI_STDOUT}"
  grep -q -F 'PGREP_PKILL_GUARD_STATE_DIR' "${CLI_STDOUT}"
  grep -q -F 'jq --null-input' "${CLI_STDOUT}"
}

@test "cli: --version prints exactly the program name and a semver" {
  run_cli version --version
  [ "${CLI_STATUS}" -eq 0 ]
  [ ! -s "${CLI_STDERR}" ]
  # Exactly one line, GNU style: name then version, no trailing prose. This is
  # what gets pasted into a bug report, so anything else on the line is noise a
  # reporter has to strip.
  [ "$(wc -l < "${CLI_STDOUT}")" -eq 1 ]
  local line
  IFS= read -r line < "${CLI_STDOUT}"
  [[ "${line}" =~ ^pgrep-pkill-guard\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "cli: --version agrees with .claude-plugin/plugin.json" {
  # The version is a literal in the body rather than a runtime manifest read, so
  # nothing at runtime can catch it drifting. release-please bumps both and
  # .ci/check-versions-in-sync gates the source; this asserts the same thing
  # through the interface a user actually sees.
  run_cli version --version
  [ "${CLI_STATUS}" -eq 0 ]
  local manifest_version
  manifest_version="$(jq --raw-output '.version' "${PLUGIN_JSON}")"
  [ "$(cat "${CLI_STDOUT}")" = "pgrep-pkill-guard ${manifest_version}" ]
}

@test "cli: an unrecognized option exits 2 and names it on stderr" {
  run_cli bogus --bogus
  # 2, not 1: the spec makes this the one deliberate non-fail-open path in the
  # guard. hooks/hooks.json passes no arguments, so argv can only come from a
  # person and the 2 lands in a terminal, never in Claude Code.
  [ "${CLI_STATUS}" -eq 2 ]
  # Diagnostics go to stderr, and stdout stays empty: a caller that pipes this
  # script's stdout into a JSON parser must not be handed an error message.
  [ ! -s "${CLI_STDOUT}" ]
  grep -q -F -- '--bogus' "${CLI_STDERR}"
  # And a way out, not just a complaint.
  grep -q -F -- '--help' "${CLI_STDERR}"
}

@test "cli: a bare run with stdin on a terminal exits 2 instead of hanging" {
  # A real terminal or nothing. `script` is not portable between GNU and BSD and
  # the devShell ships no pty tool, so the honest options are a genuine
  # /dev/tty or a stated skip -- a faked TTY would prove nothing about the
  # `[[ -t 0 ]]` test this case exists to pin.
  if ! (: < /dev/tty) 2> /dev/null; then
    skip 'no controlling terminal is attachable (CI and most agent runners have none)'
  fi

  local -r out="${BATS_TEST_TMPDIR}/tty.out"
  local -r err="${BATS_TEST_TMPDIR}/tty.err"
  local status=0
  # No arguments: the dispatch can only fire on `[[ -t 0 ]]`. Without it the
  # script would block in `read -r -d ''` on an EOF a terminal never sends until
  # the user finds Ctrl-D -- so a regression here shows up as a hung suite, and
  # the exit-2 assertion below is what turns that into a red test instead.
  "${HOOK}" > "${out}" 2> "${err}" < /dev/tty || status=$?
  [ "${status}" -eq 2 ]
  [ ! -s "${out}" ]
  # Name the thing that is wrong (stdin) and the way out (--help).
  grep -q -F 'stdin' "${err}"
  grep -q -F -- '--help' "${err}"
}

@test "cli: the JSON path is unchanged by the human-mode dispatch" {
  # The regression guard for the whole feature. run_hook pipes hook JSON in and
  # passes no arguments, which is exactly how Claude Code invokes the hook, so
  # neither dispatch test can fire and the verdict must be what it always was.
  # `pkill --full java` is an inert string inside a JSON payload here; nothing
  # in this suite ever runs it.
  local out
  out="$(run_hook 'ls -la')"
  [ "${out}" = '{}' ]

  out="$(run_hook 'pkill --full java')"
  [ "$(decision_of "${out}")" = 'deny' ]
}
