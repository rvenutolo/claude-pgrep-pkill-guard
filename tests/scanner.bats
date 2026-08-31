setup() {
  load 'test_helper/common'
}

# @description Run the scanner exactly the way the hook does. LC_ALL=C is
#              MANDATORY: the scanner emits BYTE offsets and the hook slices the
#              raw command back out with them, so a UTF-8 locale here would make
#              the two index bases disagree. The input is newline-TERMINATED:
#              the scanner reads lines, and the one guaranteed final newline is
#              how it tells `foo` from `foo\n` without depending on RS.
# @arg $1 command the command string to tokenize
# @stdout the token stream, one "<offset>\t<token>" record per line
scan() {
  printf '%s\n' "$1" | LC_ALL=C awk -f "${SCANNER}"
}

# @description A literal tab, for anchoring greps at the token field. `\b` is a
#              GNU grep extension and the compat CI legs run BSD grep, so every
#              "is this token in the stream" check anchors on <tab>token<eol>
#              instead of a word boundary.
# @noargs
# @stdout one tab character
tab() {
  printf '\t'
}

# --- Token stream: quoting, offsets, newlines, line continuations ------------

@test "scanner: a quoted mention yields no pgrep token" {
  local out
  out="$(scan 'grep -r "until ! pgrep --full x" .')"
  run grep -c "$(tab)pgrep\$" <<< "${out}"
  assert_output '0'
}

@test "scanner: a bare pgrep is tokenized" {
  local out
  out="$(scan 'pgrep --full x')"
  run awk -F'\t' 'NR==1 {print $2}' <<< "${out}"
  assert_output 'pgrep'
}

@test "scanner: a command substitution inside double quotes is visible" {
  local out
  out="$(scan 'until [ -z "$(pgrep --full x)" ]; do sleep 5; done')"
  run awk -F'\t' '$2 == "pgrep" {print $1}' <<< "${out}"
  assert_output '14'
}

@test "scanner: a newline survives as a literal token" {
  local out
  out="$(scan "$(printf 'echo hi\nls')")"
  run awk -F'\t' 'NR==3 {print $2}' <<< "${out}"
  assert_output '<NL>'
}

@test "scanner: a line continuation separates the words it joins" {
  # A `\`-newline is a line continuation, which bash removes outright, so the
  # words on either side must come out separate. Masked as filler they fuse into
  # one token and the invocation stops being recognised (#172 B).
  local out
  out="$(scan "$(printf 'sudo \\\npkill --full java')")"
  run awk -F'\t' 'NR==2 {print $2}' <<< "${out}"
  assert_output 'pkill'
}

# --- Heredocs ---------------------------------------------------------------

@test "scanner: a quoted heredoc body is masked" {
  # A quoted delimiter means bash expands nothing in the body, so nothing in it
  # is code (#184).
  local out
  out="$(scan "$(printf "cat <<'EOF'\npkill --full x\nEOF")")"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '0'
}

@test "scanner: a heredoc body marker carries the body offset and length" {
  # The marker is what shell_wrapper_payloads slices a wrapper's body by, so its
  # offset and length are asserted exactly: the body is `pkill --full x\n`, 15
  # bytes starting after the 12-byte `cat <<'EOF'\n`.
  local out
  out="$(scan "$(printf "cat <<'EOF'\npkill --full x\nEOF")")"
  run grep '<HD:' <<< "${out}"
  assert_output "12$(tab)<HD:15>"
}

@test "scanner: a command substitution inside an unquoted heredoc body is visible" {
  # An unquoted delimiter masks the body like a double-quoted string: a command
  # substitution in it re-enters code context, because bash runs it. So the
  # pkill IS seen -- one match, not zero.
  local out
  out="$(scan "$(printf 'cat <<EOF\n$(pkill --full x)\nEOF')")"
  run awk -F'\t' '$2 == "pkill" {print $1}' <<< "${out}"
  assert_output '12'
}

@test "scanner: plain text in an unquoted heredoc body is masked" {
  local out
  out="$(scan "$(printf 'cat <<EOF\npkill --full x\nEOF')")"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '0'
}

@test "scanner: a double-quoted delimiter masks the body" {
  # A double-quoted delimiter quotes the body exactly as a single-quoted one
  # does; only the unquoted form re-enters code context.
  local out
  out="$(scan "$(printf 'cat <<"EOF"\npkill --full x\nEOF')")"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '0'
}

@test "scanner: a line merely starting with the delimiter is not a terminator" {
  # The terminator is the WHOLE line, not a prefix of it: `EOFX` starts with the
  # delimiter and must not close the body, or everything after it is scanned as
  # code the shell never runs.
  local out
  out="$(scan "$(printf 'cat <<EOF\nEOFX\npkill --full x\nEOF')")"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '0'
}

@test "scanner: a body at end of input still emits a zero-length marker" {
  # A body that begins at end of input has no byte for the tokenizer loop to
  # reach, so its marker is emitted after the loop -- with the right offset and
  # a zero length. Written as a $'' literal, not $(printf ...), because the
  # trailing newline is the whole point and $() strips it. This is also the
  # case that proves the scanner keeps a trailing newline distinct from none:
  # the line reader must not fold the command's own final newline into the
  # terminating one the caller appends.
  local out
  out="$(scan $'cat <<EOF\n')"
  run grep '<HD:' <<< "${out}"
  assert_output "10$(tab)<HD:0>"
}

@test "scanner: a quoted empty delimiter ends its body at a blank line" {
  # A quoted EMPTY delimiter is legal bash -- the body runs to the first blank
  # line -- so it is enqueued like any other and its body is masked. Skipping it
  # left the body as code, where the apostrophe in "it's" flipped quote parity
  # and hid the pkill after the blank line altogether.
  local out
  out="$(scan "$(printf "cat <<''\nit's fine\n\npkill --full x")")"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '1'
}

@test "scanner: a quoted empty delimiter masks its body until that blank line" {
  local out
  out="$(scan "$(printf "cat <<''\nit's fine\npkill --full x\n\necho done")")"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '0'
}

@test "scanner: an unterminated quote ends the delimiter word at the newline" {
  # Read on past it and the next line's bytes are glued onto the delimiter, so
  # the real terminator is never recognised and the rest of the command is
  # masked as body -- here `E` closes the body and `pkill` is code again.
  local out
  out="$(scan "$(printf "cat <<E'\nx'\nE\npkill --full x")")"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '1'
}

@test "scanner: a backslash-escaped delimiter is a quoted delimiter" {
  local out
  out="$(scan "$(printf 'cat <<\\EOF\n$(pkill --full x)\nEOF')")"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '0'
}

@test "scanner: a tab-indented terminator closes a <<- body" {
  # `<<-` tolerates leading tabs on the terminator line; the line after it is
  # code again.
  local out
  out="$(scan "$(printf 'cat <<-EOF\npkill --full x\n\tEOF\nls')")"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '0'
}

@test "scanner: code after a <<- body is tokenized" {
  local out
  out="$(scan "$(printf 'cat <<-EOF\npkill --full x\n\tEOF\nls')")"
  run grep -c "$(tab)ls\$" <<< "${out}"
  assert_output '1'
}

@test "scanner: two heredocs on one line yield two bodies" {
  # The bodies follow in operator order, and the rest of the `<<` line is
  # ordinary code.
  local out
  out="$(scan "$(printf 'cat <<A <<B\na-body\nA\nb-body\nB\nls')")"
  run grep -c '<HD:' <<< "${out}"
  assert_output '2'
}

@test "scanner: the first of two bodies is masked" {
  local out
  out="$(scan "$(printf 'cat <<A <<B\na-body\nA\nb-body\nB\nls')")"
  run grep -c "$(tab)a-body\$" <<< "${out}"
  assert_output '0'
}

@test "scanner: the second of two bodies is masked" {
  local out
  out="$(scan "$(printf 'cat <<A <<B\na-body\nA\nb-body\nB\nls')")"
  run grep -c "$(tab)b-body\$" <<< "${out}"
  assert_output '0'
}

@test "scanner: code after two bodies is tokenized" {
  local out
  out="$(scan "$(printf 'cat <<A <<B\na-body\nA\nb-body\nB\nls')")"
  run grep -c "$(tab)ls\$" <<< "${out}"
  assert_output '1'
}

# --- Shapes that are NOT heredocs -------------------------------------------

@test "scanner: a quoted << is not a heredoc" {
  local out
  out="$(scan "$(printf 'echo "<<EOF"\npkill --full x')")"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '1'
}

@test "scanner: a here-string is not a heredoc" {
  local out
  out="$(scan 'cat <<< x; pkill --full x')"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '1'
}

@test "scanner: a shift inside arithmetic is not a heredoc" {
  local out
  out="$(scan "$(printf 'echo $((1<<2))\npkill --full x')")"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '1'
}

@test "scanner: an arithmetic shift leaves no << token to count" {
  # The hook counts `<<` tokens to pick a wrapper's body out of the marker
  # sequence, and the scanner emits no marker for a shift, so a counted shift
  # desyncs every later heredoc's ordinal.
  local out
  out="$(scan 'echo $((1 << 2))')"
  run grep -c '<<' <<< "${out}"
  assert_output '0'
}

@test "scanner: a parenthesised shift inside arithmetic is not a heredoc" {
  # An explicit grouping paren inside `$((...))` must nest its own arithmetic
  # level, or its `)` pops the whole arithmetic early and a `<<` later in the
  # expression reads as a heredoc operator.
  local out
  out="$(scan "$(printf 'echo $(( (1) << 2 ))\npkill --full x')")"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '1'
}

@test "scanner: a shift inside an arithmetic command is not a heredoc" {
  local out
  out="$(scan "$(printf '(( x << 2 ))\npkill --full x')")"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '1'
}

# --- Heredoc edge cases that must not hang or over-mask ----------------------

@test "scanner: an unterminated heredoc masks to end of input" {
  # Fail-open, and the test returning at all is the no-hang check. The body is
  # the 14 bytes after `cat <<EOF\n`.
  local out
  out="$(scan "$(printf 'cat <<EOF\npkill --full x')")"
  run grep '<HD:' <<< "${out}"
  assert_output "10$(tab)<HD:14>"
}

@test "scanner: a heredoc inside a command substitution is masked" {
  # The heredoc opens at the newline inside the substitution.
  local out
  out="$(scan "$(printf 'echo "$(cat <<EOF\npkill --full x\nEOF\n)"')")"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '0'
}

@test "scanner: a body line ending in a backslash does not swallow the terminator" {
  # A body line ending in a backslash is literal text, not a continuation:
  # masking the backslash together with the newline it precedes would swallow
  # the terminator's own newline and mask to end of input (#184 fix round 1).
  local out
  out="$(scan "$(printf 'cat <<EOF\nfoo \\\nEOF\npkill --full x')")"
  run grep -c "$(tab)pkill\$" <<< "${out}"
  assert_output '1'
}

# --- The guard must announce itself dead, never die quietly ------------------

# @description Run a copy of the hook end to end under a stripped environment and
#              report whether it announced that the guard is inactive, rather
#              than dying into the ERR trap's silent allow. The probe command
#              must contain `pgrep` or `pkill`, or classify_command
#              short-circuits before the scanner is ever reached and a dead
#              scanner looks healthy. The child runs under `env -i`: a plain PATH
#              prefix assignment is not enough, because a BASH_ENV inherited from
#              the caller re-sources the user's profile, which rebuilds PATH and
#              quietly restores the very binary the probe is trying to remove.
#              Invoked directly, not as `bash <script>`, matching the hooks.json
#              contract (spec amendment A12).
# @arg $1 script path to the hook copy to run
# @arg $2 path the PATH that copy should see
# @stdout inactive or active
inactive_probe() {
  local -r script="$1"
  local -r path="$2"
  local output
  output="$(printf '{"tool_name":"Bash","tool_input":{"command":"pkill --full java"}}' \
    | env -i "PATH=${path}" "${script}" 2> /dev/null || true)"
  if [[ "${output}" == *INACTIVE* ]]; then printf 'inactive\n'; else printf 'active\n'; fi
}

# @description Build a throwaway hook copy plus a stub PATH holding only what the
#              hook needs before it reaches the awk check.
# @noargs
# @stdout nothing; sets PROBE_DIR and STUB_DIR in the caller
build_inactive_fixture() {
  local binary
  PROBE_DIR="${BATS_TEST_TMPDIR}/probe"
  STUB_DIR="${PROBE_DIR}/bin"
  mkdir -p "${STUB_DIR}"
  for binary in bash jq dirname cat; do
    ln -s "$(command -v "${binary}" || printf '/nonexistent')" "${STUB_DIR}/${binary}" || true
  done
  cp "${HOOK}" "${PROBE_DIR}/hook.sh"
  chmod +x "${PROBE_DIR}/hook.sh"
  # The body too, or the entry script stops at its own missing-sibling branch and
  # never reaches the awk and scanner checks these probes exist to exercise --
  # they would report `inactive` for the wrong reason and pass regardless (#55).
  cp "${BODY}" "${PROBE_DIR}/pgrep-pkill-guard-body.sh"
  cp "${SCANNER}" "${PROBE_DIR}/pgrep-scan.awk"
}

@test "scanner: a missing awk announces the guard inactive" {
  local PROBE_DIR STUB_DIR
  build_inactive_fixture
  run inactive_probe "${PROBE_DIR}/hook.sh" "${STUB_DIR}"
  assert_output 'inactive'
}

@test "scanner: a missing scanner announces the guard inactive" {
  local PROBE_DIR STUB_DIR
  build_inactive_fixture
  rm -f -- "${PROBE_DIR}/pgrep-scan.awk"
  run inactive_probe "${PROBE_DIR}/hook.sh" "${PATH}"
  assert_output 'inactive'
}

# @description Copy ONLY the entry script into the per-test tmpdir and run it
#              there. `resolve_hook_dir` derives HOOK_DIR from ${BASH_SOURCE[0]},
#              so the copy looks for `pgrep-pkill-guard-body.sh` beside ITSELF
#              and finds whatever the caller did -- or did not -- drop in that
#              directory first. The probe command must contain `pgrep` or
#              `pkill` or the prefilter short-circuits before the sibling is ever
#              sourced; `zzznoproc` matches no process, so nothing can be killed
#              if the guard fails to fire. Invoked directly, not as
#              `bash <script>`, matching the hooks.json contract (spec amendment
#              A12). stderr is discarded because a sibling that fails to parse
#              makes bash print a syntax error, and only stdout is the contract.
# @noargs
# @stdout the hook's JSON verdict
orphan_probe() {
  local -r copy="${BATS_TEST_TMPDIR}/pgrep-pkill-guard.sh"
  cp "${HOOK}" "${copy}"
  chmod +x "${copy}"
  printf '{"tool_name":"Bash","tool_input":{"command":"pkill --full zzznoproc"}}' \
    | "${copy}" 2> /dev/null
}

@test "scanner: a missing sibling body announces the guard inactive" {
  local out
  out="$(orphan_probe)"
  [[ "${out}" == *'INACTIVE'* ]]
  # Pinned to the branch under test: without this the sibling-fails-to-load case
  # below would still pass if its broken file never got written.
  [[ "${out}" == *'is missing'* ]]
}

@test "scanner: a sibling body that fails to load announces the guard inactive" {
  # Syntactically broken on purpose, so `source` returns non-zero. The `||` on
  # the source call is what keeps that off the ERR trap, turning a corrupt
  # sibling into this message rather than the trap's silent allow.
  printf 'function {{{\n' > "${BATS_TEST_TMPDIR}/pgrep-pkill-guard-body.sh"
  local out
  out="$(orphan_probe)"
  [[ "${out}" == *'INACTIVE'* ]]
  [[ "${out}" == *'failed to load'* ]]
}

# --- The jq @tsv / printf %b round-trip -------------------------------------

@test "scanner: a command with literal tabs and newlines survives the tsv decode" {
  # jq escapes an actual tab as `\t` and an actual newline as `\n` so the record
  # stays on one TSV line; decoding the wrong sequences, or in the wrong order,
  # corrupts token boundaries silently rather than erroring. If the round-trip
  # breaks, the embedded newline splits the record and the pkill is no longer
  # seen in command position.
  local command json
  command="$(printf 'echo\tone\npkill --full java')"
  json="$(run_hook "${command}")"
  [ "$(decision_of "${json}")" = 'deny' ]
  [[ "$(reason_of "${json}")" == *'--ignore-ancestors'* ]]
}

# --- The scanner integrity trailer ------------------------------------------

@test "scanner: the token stream carries an integrity trailer" {
  local out
  out="$(scan 'ls -la')"
  [[ "${out}" == *"<SCAN:6>"* ]]
}

@test "scanner: the trailer reports zero for empty input" {
  local out
  out="$(scan '')"
  [[ "${out}" == *'<SCAN:0>'* ]]
}

@test "scanner: the trailer counts every byte of a command with a blank line" {
  # A blank line is what paragraph-mode awk splits a record on. The scanner no
  # longer depends on RS at all, so the reassembled byte count must be exact on
  # every awk, BWK included.
  local out
  out="$(scan $'echo a\n\necho b')"
  [[ "${out}" == *'<SCAN:14>'* ]]
}

@test "scanner: the trailer counts a trailing newline" {
  local out
  out="$(scan $'echo a\n')"
  [[ "${out}" == *'<SCAN:7>'* ]]
}

@test "scanner: a mangled trailer deactivates the guard loudly" {
  # Simulate an awk that strips or reshapes bytes on the way through -- the
  # failure the trailer exists to catch.
  local fake="${BATS_TEST_TMPDIR}/bad.awk"
  printf '%s\n' 'BEGIN { ORS = "" } { print } END { print "\t<SCAN:9>" }' > "${fake}"
  local out
  out="$(printf '{"tool_name":"Bash","tool_input":{"command":"pkill --full java"}}' \
    | PGREP_GUARD_SCANNER_OVERRIDE="${fake}" "${HOOK}")"
  [[ "${out}" == *'INACTIVE'* ]]
}
