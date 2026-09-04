# Property fuzzing for hooks/pgrep-scan.awk (#92).
#
# tests/scanner.bats pins the scanner's BEHAVIOUR on hand-written inputs -- which
# tokens come out, at which offsets. This file pins the far narrower thing that
# has to hold for EVERY input, including inputs nobody would write on purpose:
#
#   1. the scanner always exits 0;
#   2. its last line is always a well-formed integrity trailer, `<TAB><SCAN:n>`;
#   3. n is the byte length of the reassembled command -- for input bytes B,
#      n == len(B) - 1 when B ends with a newline, and n == len(B) when it does
#      not.
#
# Rule 1 is not decoration. The hook calls the scanner inside a command
# substitution, so a non-zero exit is swallowed by the ERR trap and becomes a
# silent ALLOW. An exit code is not an available failure channel, which is
# exactly why the trailer exists at all -- see the trailer comment at the foot of
# hooks/pgrep-scan.awk.
#
# What is deliberately NOT asserted here is which tokens appear, or at what
# offsets. A random input has no expected token stream, and inventing one would
# mean reimplementing the scanner inside the test.
#
# --- The corpus -------------------------------------------------------------
#
# Uniform random bytes would be a weak fuzzer: they essentially never produce
# `<<'EOF'`, an unbalanced `$(`, or a `#` at word start -- the constructs where
# this scanner's logic actually lives -- so the whole budget would go on
# confirming that ordinary text round trips. The generator is therefore
# FRAGMENT-BASED: a fixed catalogue of short strings drawn from the trouble spots
# the scanner's own header names, assembled in random order and random counts,
# with a minority of runs of random printable bytes mixed in. The catalogue is
# the interesting half; randomness only decides the arrangement.
#
# SAFETY: the catalogue holds BARE WORDS -- `pgrep`, `pkill`, `.output` -- and
# never a full invocation. Nothing here runs a shell on generated input, and
# nothing writes generated input to a file that is later executed; it is only
# ever piped to `awk`. This is the project's standing rule and it has an incident
# behind it: on 2026-08-26 a broad pattern-kill used as heredoc filler terminated
# the author's X session. Same signal, zero blast radius.
#
# --- Determinism and the RANDOM caveat --------------------------------------
#
# FUZZ_SEED selects the corpus; absent, one is drawn from ${RANDOM} and printed
# on EVERY run, not only on failure -- a seed a reader has to reconstruct from a
# red CI log is a seed they will not have once the log has scrolled.
#
# CAVEAT: the generator seeds bash's own RANDOM, and the sequence RANDOM produces
# for a given seed is not guaranteed identical across bash versions. A seed
# reproduces reliably on the same bash and only probably on another. That is
# acceptable because the corpus is fragment-based: a failure is a short,
# printable string that fuzz_fail prints in full via `printf %q`, and THAT string
# is the durable reproducer, not the seed.
#
# --- Size and cost ----------------------------------------------------------
#
# FUZZ_N (default 200) is honoured from the environment, and every test covers
# the WHOLE corpus -- partitioning it between tests would leave each property
# checked on a slice of the inputs, which is the wrong trade.
#
# The corpus is scanned exactly TWICE, once newline-terminated and once raw, and
# all three properties are asserted from each single `awk` run per case. That
# matters more than it looks: the gate runs the whole suite twice, under gawk and
# under one-true-awk, so every spawn here is paid for twice. Two costs that are
# NOT the awk spawns dominated the first cut of this file and are worth knowing
# about before changing anything here -- bats traps DEBUG to track line numbers,
# so a simple command inside a test costs ~200us, and setup() runs once per test.
# Hence: the corpus is generated once in setup_file and read back from a file,
# and the hot loop forks no subshell it does not have to.
#
# Measured on the author's machine: this file's own bats run is 7-8s at the
# default FUZZ_N=200, of which ~0.7s is bats startup and roughly half the rest is
# the 400 awk spawns; the whole suite is ~56s without it. That is the number to
# quote, because the suite-level delta measured on the same machine ranged from
# +4s to +20s across interleaved runs -- the machine's own variance is larger
# than what this file costs, so a single before/after pair proves nothing.
# FUZZ_N=5000 takes ~2m50s. `just fuzz` runs a much larger N on demand and is
# deliberately not part of `just check`.
#
# The per-case runtime bound the issue asks for is implemented as ONE bound on
# the whole corpus, not a `timeout` per case: a per-case `timeout` is a second
# process spawn per input, doubling the cost of the very thing it measures, and
# `timeout` is not POSIX. A genuine hang is caught by CI's own job timeout; what
# the budget test adds is the pathological-but-finite case, where one input drags
# the corpus far past its allowance.
#
# --- When this finds something ----------------------------------------------
#
# A find becomes a HAND-WRITTEN CASE IN tests/scanner.bats -- not a row in
# tests/cases/. The issue's wording points at the tables, but verdicts.tsv and
# messages.tsv are HOOK-level tables read by tests/classify.bats, and a scanner
# input put there would be interpreted as a command to classify. The fuzzer's job
# is to find them; tests/scanner.bats' job is to keep them.
#
# Per the repo's testing rules the fix is a separate `fix:` commit naming the
# surfacing test, never folded into the `test:` commit that surfaced it.
#
# --- shellcheck -------------------------------------------------------------
#
# The fragment catalogue holds single-quoted literals containing `$(`, `$((` and
# `${`. Those are the SUBJECT of the test -- the scanner's whole job is deciding
# which of them the shell would have expanded -- so they have to reach it byte
# for byte, and double-quoting any of them would make bash expand it here
# instead. Several sites in one array is over the threshold at which per-site
# disables become noise, so the disable is file-level, exactly as in
# tests/scanner.bats.
#
# The directive is honoured despite the file having no shebang (bats sources
# these, so .ci/check-bats-no-shebang forbids one): shellcheck scopes a
# file-level directive to everything after it, and infers bash for a
# shebang-less file.
# shellcheck disable=SC2016

# @description Pick the seed ONCE for the whole file and announce it. Exported,
#              because bats runs every test in its own process and only exported
#              setup_file variables reach them -- without the export each test
#              would silently fuzz a different corpus and "same seed, same
#              corpus" would be untestable. Printed to fd 3, the one bats channel
#              that is shown on a PASSING run: `run-tests <path>` does not pass
#              --print-output-on-failure, so stdout would be swallowed either
#              way.
# @noargs
# @stdout nothing; the seed banner goes to fd 3
setup_file() {
  export FUZZ_SEED="${FUZZ_SEED:-${RANDOM}}"
  export FUZZ_N="${FUZZ_N:-200}"
  # Generate the corpus ONCE for the whole file and hand it to the tests through
  # BATS_FILE_TMPDIR, NUL-delimited. Not a micro-optimisation: bats traps DEBUG
  # to track line numbers, so every simple command inside a test costs on the
  # order of 200us, and rebuilding the corpus in setup() -- which runs once per
  # test -- was measured at 1.8s a time, roughly ten times what the awk spawns
  # this file exists to make cost. NUL rather than newline because a generated
  # case routinely CONTAINS newlines; it can never contain a NUL, since the
  # catalogue is ASCII text and FUZZ_ALPHABET spans 0x20-0x7E.
  fuzz_catalogue
  fuzz_corpus
  printf '%s\0' "${FUZZ_CORPUS[@]}" > "${BATS_FILE_TMPDIR}/corpus"
  # The banner carries a checksum of the corpus, not just the seed. The seed
  # alone is a weak identity -- bash makes no promise that a given seed yields
  # the same RANDOM sequence on another bash version, so "seed 42" on a Linux
  # runner and "seed 42" on macOS may be two different corpora. The checksum
  # makes that visible instead of leaving it to be inferred, and it is what turns
  # "reproduce it with FUZZ_SEED=42" into a claim a reader can check. `cksum` is
  # POSIX, so it is there on the compat legs' ambient userland too.
  local digest
  digest="$(cksum < "${BATS_FILE_TMPDIR}/corpus")"
  printf 'scanner-fuzz: FUZZ_SEED=%s FUZZ_N=%s corpus=%s\n' \
    "${FUZZ_SEED}" "${FUZZ_N}" "${digest%% *}" >&3
}

setup() {
  load 'test_helper/common'
  # LC_ALL=C twice over, and both are load-bearing. For `awk` it is the same
  # requirement tests/scanner.bats documents: the scanner emits BYTE offsets and
  # the hook slices the raw command back out with them, so a UTF-8 locale would
  # make the two index bases disagree. For BASH it is what makes `${#input}` a
  # byte count rather than a character count, which is the number every
  # assertion in this file compares against. Today's catalogue is pure ASCII so
  # the two agree, but a single non-ASCII fragment added later would silently
  # turn every byte-count assertion into a character-count assertion, and it
  # would still pass.
  export LC_ALL=C
  # The catalogue is cheap and the two anti-vacuity tests regenerate from it;
  # the corpus itself is read back from the file setup_file wrote.
  fuzz_catalogue
  fuzz_read_corpus
}

# --- The fragment catalogue -------------------------------------------------

# @description Populate FUZZ_FRAGMENTS with one entry per trouble spot the
#              scanner's header names. Built in a function rather than at file
#              scope because bats sources this file once per test to discover
#              it, and top-level work runs on every one of those passes.
# @noargs
# @stdout nothing; sets FUZZ_FRAGMENTS in the caller
fuzz_catalogue() {
  FUZZ_FRAGMENTS=(
    # Quote openers with no closer, and their backslash-escaped forms. An
    # unclosed quote is what makes quote parity the scanner's most fragile
    # invariant.
    "'"
    '"'
    "\\'"
    '\"'
    "''"
    '""'
    # Context openers. `$(` inside double quotes re-enters an UNQUOTED context,
    # because the shell expands it there.
    '$('
    '$(('
    '${'
    ')'
    '))'
    '}'
    '`'
    '`x`'
    # Comments. An unquoted `#` that starts a word runs to end of line; a `#`
    # mid-word does not; a `#` inside single quotes is just text.
    '#'
    '# comment'
    'x#y'
    "'#'"
    # Heredoc operators, quoted and unquoted, plus a bare `<<` with no
    # delimiter at all.
    '<<EOF'
    '<<-EOF'
    "<<'EOF'"
    '<<"EOF"'
    '<<\EOF'
    '<<'
    "<<''"
    '\<<EOF'
    # Terminator lines: bare, tab-indented (which only `<<-` accepts), and one
    # with trailing spaces (which is NOT a terminator, the whole line must
    # match).
    'EOF'
    $'\tEOF'
    'EOF   '
    'EOFX'
    # The shift the scanner must not read as a heredoc operator.
    '$((1 << 2))'
    '(( x << 2 ))'
    '<<< x'
    # Line structure: a newline, a blank line, and a line ending in a
    # backslash, which is a continuation outside a heredoc body and literal
    # text inside one.
    $'\n'
    $'\n\n'
    $'x \\\n'
    # The parity inverter the scanner's header calls out by name.
    "don't"
    'it'"'"'s fine'
    # The words the hook cares about, and near misses. BARE WORDS ONLY -- never
    # a full invocation. See the SAFETY note in the file header.
    'pgrep'
    'pkill'
    '.output'
    'pgrepx'
    'xpgrep'
    '\pgrep'
    'echo'
    'cat'
    ';'
    '|'
    '&&'
  )
  # A very long run of one character, three ways. The `'` run is the
  # interesting one: it flips quote parity 384 times in a row.
  local pad ch
  printf -v pad '%*s' 384 ''
  for ch in 'a' "'" '$' '<'; do
    FUZZ_FRAGMENTS+=("${pad// /${ch}}")
  done
  # What goes BETWEEN two fragments. An array rather than a `case` so a
  # fragment and its glue are one append, see fuzz_case.
  FUZZ_GLUE=(' ' $'\n' '')
}

# @description Populate FUZZ_ALPHABET with every printable ASCII byte, 0x20
#              through 0x7E. Built rather than written out so no byte is
#              accidentally omitted and no quoting accident silently drops one.
# @noargs
# @stdout nothing; sets FUZZ_ALPHABET in the caller
fuzz_alphabet() {
  local i byte
  FUZZ_ALPHABET=''
  for ((i = 32; i <= 126; i++)); do
    printf -v byte '\\%03o' "${i}"
    printf -v byte '%b' "${byte}"
    FUZZ_ALPHABET+="${byte}"
  done
}

# --- The generator ----------------------------------------------------------

# @description Assemble ONE fuzz input. Result lands in the global FUZZ_CASE
#              rather than on stdout, and that is not a style choice: `$(...)`
#              strips trailing newlines, and whether the input ends with a
#              newline is precisely what selects between the two halves of the
#              byte-count rule. A generator that returned through stdout could
#              not produce a case for the second half at all.
#
#              At least three fragments per case, never zero: the catalogue
#              holds no empty fragment, so a floor of three is what guarantees
#              the "non-empty" half of the anti-vacuity test can never be
#              satisfied by accident.
# @noargs
# @stdout nothing; sets FUZZ_CASE in the caller
fuzz_case() {
  local -r count="${#FUZZ_FRAGMENTS[@]}"
  local -r parts=$((RANDOM % 10 + 3))
  local i
  FUZZ_CASE=''
  for ((i = 0; i < parts; i++)); do
    # Fragment and glue in ONE append rather than a fragment append followed by
    # a `case` picking the glue. Same corpus, half the simple commands, and
    # under bats' DEBUG trap the command count is what this loop costs.
    #
    # Glue: a space keeps two fragments separate words, a newline puts them on
    # separate lines (which is what heredoc bodies and comments need), and the
    # empty string fuses them into one word.
    FUZZ_CASE+="${FUZZ_FRAGMENTS[RANDOM % count]}${FUZZ_GLUE[RANDOM % 3]}"
  done
  # A minority of cases get a run of random printable bytes appended. This is
  # the half that reaches shapes the catalogue's author did not think of.
  if ((RANDOM % 5 == 0)); then
    local length=$((RANDOM % 24 + 1))
    for ((i = 0; i < length; i++)); do
      FUZZ_CASE+="${FUZZ_ALPHABET:RANDOM%${#FUZZ_ALPHABET}:1}"
    done
  fi
}

# @description Build a corpus into FUZZ_CORPUS, deterministically from
#              FUZZ_SEED. setup_file calls this once and writes the result out;
#              only the two anti-vacuity tests call it again, to show that a
#              seed reproduces its corpus and that a different seed does not.
# @arg $1 count how many cases to generate; defaults to FUZZ_N
# @arg $2 seed  which seed to generate from; defaults to FUZZ_SEED. Taken as an
#         argument rather than by reassigning FUZZ_SEED, because a test that
#         reassigned the exported seed would be reassigning it inside the
#         subshell bats wraps every @test in -- invisible to the rest of the
#         file, and exactly the SC2030/SC2031 shape shellcheck warns about.
# @stdout nothing; sets FUZZ_CORPUS in the caller
fuzz_corpus() {
  local -r wanted="${1:-${FUZZ_N}}"
  local -r seed="${2:-${FUZZ_SEED}}"
  local i
  fuzz_alphabet
  FUZZ_CORPUS=()
  RANDOM="${seed}"
  for ((i = 0; i < wanted; i++)); do
    fuzz_case
    FUZZ_CORPUS+=("${FUZZ_CASE}")
  done
}

# @description Read the corpus setup_file generated back into FUZZ_CORPUS. Two
#              commands per case instead of the dozen a rebuild costs, which
#              matters because setup() runs once per test. `read -d ''` splits
#              on NUL and is a bash builtin present since 3.2, so it needs
#              nothing from the ambient userland the compat legs run against.
# @noargs
# @stdout nothing; sets FUZZ_CORPUS in the caller
fuzz_read_corpus() {
  local item
  FUZZ_CORPUS=()
  while IFS= read -r -d '' item; do
    FUZZ_CORPUS+=("${item}")
  done < "${BATS_FILE_TMPDIR}/corpus"
}

# --- Driving the scanner ----------------------------------------------------

# @description Run the scanner the way the hook does: input newline-TERMINATED,
#              which is the documented calling convention. Mirrors the `scan`
#              helper in tests/scanner.bats.
# @arg $1 command the command string to tokenize
# @stdout the token stream
# @exitcode whatever awk exited with -- the caller checks it, this helper does
#           not swallow it
scan_terminated() {
  printf '%s\n' "$1" | LC_ALL=C awk -f "${SCANNER}"
}

# @description Run the scanner on EXACTLY the given bytes, with no newline
#              appended -- the calling convention VIOLATED. The scanner still
#              has to answer correctly, and this is the only way to reach the
#              second half of the byte-count rule.
# @arg $1 command the command string to tokenize
# @stdout the token stream
# @exitcode whatever awk exited with
scan_raw() {
  printf '%s' "$1" | LC_ALL=C awk -f "${SCANNER}"
}

# --- The one comparison every property test rests on ------------------------

# @description Verify a scanner stream ends in a well-formed integrity trailer
#              carrying the expected byte count. This is the single comparison
#              every property in this file rests on, which is why the second
#              anti-vacuity test feeds it a known-bad trailer: a comparison that
#              always held would make every property green forever.
#
#              Two failures, distinguished by the reason text -- "not a
#              well-formed trailer" means the STREAM was mangled, "expected"
#              means the stream was intact and the COUNT was wrong. That is why
#              they do not need to be separate tests: one awk spawn produces the
#              evidence for both, and fuzz_fail prints whichever fired.
#
#              The reason goes into the global TRAILER_REASON rather than onto
#              stdout. Returning it through `$(...)` would fork a subshell for
#              every case in the corpus, on the hot path, purely to move a string
#              that is only ever read on failure.
# @arg $1 out    the scanner's stdout
# @arg $2 expect the expected byte count
# @stdout nothing; sets TRAILER_REASON in the caller on failure
# @exitcode 0 trailer present, well-formed, and carrying ${2}
# @exitcode 1 otherwise
trailer_check() {
  local -r out="$1"
  local -r expect="$2"
  # `$(...)` already stripped any trailing newline, and the scanner emits none
  # anyway (ORS is "" and the trailer print carries no "\n"), so the last line
  # is everything after the final newline. With no newline at all -- a stream
  # that is nothing but the trailer -- this yields the whole string, which is
  # the right answer.
  local -r last="${out##*$'\n'}"
  local -r pattern=$'^\t<SCAN:[0-9]+>$'
  TRAILER_REASON=''
  if [[ ! "${last}" =~ ${pattern} ]]; then
    printf -v TRAILER_REASON 'last line is not a well-formed trailer: %q' "${last}"
    return 1
  fi
  local -r want=$'\t'"<SCAN:${expect}>"
  if [[ "${last}" != "${want}" ]]; then
    printf -v TRAILER_REASON 'trailer is %q, expected %q' "${last}" "${want}"
    return 1
  fi
}

# @description Report one failing case on fd 3 and fail the test. fd 3 rather
#              than stdout because `run-tests <path>` forwards no
#              --print-output-on-failure, so a message on stdout would never be
#              seen -- and a fuzz failure whose reproducer is invisible is a
#              fuzz failure nobody can act on. `%q` renders the input
#              unambiguously; it is the durable reproducer, more so than the
#              seed (see the RANDOM caveat in the file header).
# @arg $1 index  the case index within the corpus
# @arg $2 input  the offending input
# @arg $3 detail what went wrong
# @exitcode 1 always
fuzz_fail() {
  local -r index="$1"
  local -r input="$2"
  local -r detail="$3"
  {
    printf 'scanner-fuzz FAILURE: seed=%s case=%s of %s\n' "${FUZZ_SEED}" "${index}" "${FUZZ_N}"
    printf '  input:  %q\n' "${input}"
    printf '  detail: %s\n' "${detail}"
  } >&3
  return 1
}

# --- One pass over the corpus -----------------------------------------------

# @description Scan the whole corpus once and assert all three properties from
#              that single `awk` invocation per case: exit status 0, a
#              well-formed trailer, and the right byte count in it.
#
#              ONE spawn, not three. The three properties are not independent
#              observations -- they all fall out of the same run, and
#              TRAILER_REASON already says which of them broke -- so splitting
#              them across three tests would triple the corpus's cost for no
#              extra diagnostic. The gate runs the whole suite twice (gawk and
#              one-true-awk), so every spawn here is paid for twice.
#
#              Records its own elapsed seconds so the budget test can assert
#              against the REAL loops rather than adding a pass of its own.
# @arg $1 mode `terminated` for the documented calling convention (exactly one
#         newline appended), `raw` for the convention violated
# @stdout nothing; writes elapsed seconds to BATS_FILE_TMPDIR
# @exitcode 0 every case in the corpus held
# @exitcode 1 a case failed; fuzz_fail has already printed it on fd 3
fuzz_scan_pass() {
  local -r mode="$1"
  local -r scan="scan_${mode}"
  local i status expect out
  SECONDS=0
  for ((i = 0; i < FUZZ_N; i++)); do
    expect="${#FUZZ_CORPUS[i]}"
    # Under `raw` the scanner receives exactly these bytes, so its one-newline
    # drop applies only when the input supplied that newline itself. Under
    # `terminated` the caller supplies it and the drop always lands on the
    # appended one, so `expect` is the length either way.
    #
    # An `if`, not `[[ ... ]] && expect=...`: bats runs tests under `set -e`,
    # and an `&&` list whose left side is false is a failing command, so the
    # short form would abort the loop on the first case that does NOT end with
    # a newline -- silently turning this into a one-case test.
    if [[ "${mode}" == 'raw' && "${FUZZ_CORPUS[i]}" == *$'\n' ]]; then
      expect=$((expect - 1))
    fi
    status=0
    out="$("${scan}" "${FUZZ_CORPUS[i]}")" || status=$?
    # Explicit `return 1` after each report, NOT a bare `x || fuzz_fail ...`
    # leaning on bats' `set -e` to unwind. This function was written the short
    # way first and it was WRONG: `fuzz_fail`'s non-zero return ends an `||`
    # list, the loop carries on to the next case, and the final `printf` hands
    # back 0 -- so a corpus full of failures reported itself as a pass anywhere
    # errexit was not in force. Caught by driving this same function against a
    # scanner mutated to emit `n+1`, which it then declared clean.
    if ((status != 0)); then
      fuzz_fail "${i}" "${FUZZ_CORPUS[i]}" "scanner exited ${status}; a non-zero exit is a silent allow"
      return 1
    fi
    if ! trailer_check "${out}" "${expect}"; then
      fuzz_fail "${i}" "${FUZZ_CORPUS[i]}" "${TRAILER_REASON}"
      return 1
    fi
  done
  printf '%s\n' "${SECONDS}" > "${BATS_FILE_TMPDIR}/elapsed-${mode}"
}

# --- Anti-vacuity: the fuzzer itself ----------------------------------------

@test "scanner-fuzz: the generator yields a non-empty, varied, stable corpus" {
  # A generator that silently produced empty strings, or the same string every
  # time, would make every property below green forever. Three claims:
  # non-empty, varied, and reproducible from the seed.
  local i
  for ((i = 0; i < FUZZ_N; i++)); do
    if [[ -z "${FUZZ_CORPUS[i]}" ]]; then
      # `return 1` spelled out, for the reason documented in fuzz_scan_pass:
      # fuzz_fail's exit status is a report, not an unwind.
      fuzz_fail "${i}" '' 'generator produced an empty input'
      return 1
    fi
  done

  # Varied, but deliberately NOT "all distinct". The generator draws from a
  # finite catalogue and a case can be as short as three fragments, so exact
  # collisions are expected at any interesting N, and demanding uniqueness would
  # make this red for a reason that has nothing to do with what it guards. The
  # measured rate is 100% distinct at FUZZ_N=200, 5000 and 10000 across seeds,
  # so the 90% floor is not a description of the generator -- it is headroom
  # against a collision nobody wants to debug, sitting far enough below the real
  # rate that only a generator which has stopped varying can reach it.
  #
  # Counted with an associative array rather than `sort -u`: BSD sort has no
  # `-z`, and an input holding embedded newlines cannot be de-duplicated
  # line-wise. Pure bash needs no flag that differs across userlands.
  local -A seen=()
  local distinct=0
  for ((i = 0; i < FUZZ_N; i++)); do
    if [[ -z "${seen[${FUZZ_CORPUS[i]}]:-}" ]]; then
      seen["${FUZZ_CORPUS[i]}"]=1
      distinct=$((distinct + 1))
    fi
  done
  ((distinct * 100 >= FUZZ_N * 90)) \
    || fail "only ${distinct} of ${FUZZ_N} generated inputs were distinct"

  # Stable: regenerating from the same seed reproduces the corpus byte for byte
  # -- in a DIFFERENT PROCESS from the one setup_file generated it in, since
  # FUZZ_CORPUS here was read back from the file setup_file wrote -- and a
  # different seed does not. Without the second half "stable" would be satisfied
  # by a generator that ignored the seed entirely.
  #
  # Bounded to the first 64 cases rather than all FUZZ_N. Generation is
  # sequential, so the first 64 of a corpus are the same 64 at any N, and this
  # is the one test that has to run the generator itself -- twice -- under
  # bats' DEBUG trap, where a full regeneration at `just fuzz`'s N would cost
  # more than every awk spawn in the file put together.
  local -r sample=$((FUZZ_N < 64 ? FUZZ_N : 64))
  local -a first=("${FUZZ_CORPUS[@]:0:sample}")
  fuzz_corpus "${sample}"
  for ((i = 0; i < sample; i++)); do
    [[ "${FUZZ_CORPUS[i]}" == "${first[i]}" ]] \
      || fail "seed ${FUZZ_SEED} did not reproduce case ${i}"
  done

  local -r other=$((FUZZ_SEED + 1))
  fuzz_corpus "${sample}" "${other}"
  local differs=0
  for ((i = 0; i < sample; i++)); do
    if [[ "${FUZZ_CORPUS[i]}" != "${first[i]}" ]]; then
      differs=1
      break
    fi
  done
  ((differs == 1)) || fail "seed $((other - 1)) and seed ${other} produced the same corpus"
}

@test "scanner-fuzz: the trailer comparison rejects a known-bad trailer" {
  # Exercise the assertion path with inputs that are SUPPOSED to fail, through
  # the very function the corpus loop calls. A comparison that always held would
  # make every property in this file green forever, and nothing else here would
  # notice.
  #
  # Called directly rather than through bats' `run`, because the reason text
  # lands in TRAILER_REASON and `run` would not bring it back.
  local out
  out="$(printf '0\tls\n\t<SCAN:6>')"
  trailer_check "${out}" 6 || fail "the comparison rejected a correct trailer: ${TRAILER_REASON}"

  if trailer_check "${out}" 9; then
    fail 'the comparison accepted a byte count that does not match'
  fi
  [[ "${TRAILER_REASON}" == *'expected'* ]] \
    || fail "wrong-count reason did not name the expectation: ${TRAILER_REASON}"

  out="$(printf '0\tls\n3\t-la')"
  if trailer_check "${out}" 6; then
    fail 'the comparison accepted a stream with no trailer at all'
  fi
  [[ "${TRAILER_REASON}" == *'not a well-formed trailer'* ]] \
    || fail "missing-trailer reason was wrong: ${TRAILER_REASON}"

  # A trailer that is present but not LAST is the mangled-stream shape the
  # trailer exists to catch, and must not pass.
  out="$(printf '\t<SCAN:6>\n0\tls')"
  if trailer_check "${out}" 6; then
    fail 'the comparison accepted a trailer that was not the last line'
  fi

  # A count that is not digits must not be read as well-formed.
  out="$(printf '0\tls\n\t<SCAN:x>')"
  if trailer_check "${out}" 6; then
    fail 'the comparison accepted a non-numeric byte count'
  fi
  [[ "${TRAILER_REASON}" == *'not a well-formed trailer'* ]] \
    || fail "non-numeric reason was wrong: ${TRAILER_REASON}"
}

# --- The properties ---------------------------------------------------------

@test "scanner-fuzz: newline-terminated input exits 0 with a correct trailer" {
  # The documented calling convention: the caller appends exactly one newline,
  # the scanner drops exactly one, so the count is the length of the string
  # BEFORE the appended newline -- whether or not that string ends with a
  # newline of its own.
  #
  # Exit status, trailer well-formedness and byte count are asserted from one
  # `awk` run per case; see fuzz_scan_pass for why they are not three tests.
  fuzz_scan_pass 'terminated'
}

@test "scanner-fuzz: unterminated input exits 0 with a correct trailer" {
  # A SEPARATE test from the one above, deliberately, so the two halves of the
  # byte-count rule fail independently and a reader can tell which precondition
  # broke. Here the caller violates the convention and sends the bytes raw, so
  # the scanner's one-newline drop applies only when the input supplied that
  # newline itself.
  fuzz_scan_pass 'raw'
}

@test "scanner-fuzz: the corpus finished inside its budget" {
  # The issue asks for a per-case runtime bound; this is one bound on the whole
  # corpus instead. A per-case `timeout` would be a second process spawn per
  # input -- doubling the cost of the thing it measures -- and `timeout` is not
  # POSIX. A genuine hang is caught by CI's own job timeout; what this adds is
  # the pathological-but-finite input, one the scanner degrades on badly enough
  # to drag the whole corpus past its allowance.
  #
  # It measures the two REAL passes rather than making a third of its own: each
  # records its elapsed seconds in BATS_FILE_TMPDIR, and bats runs the tests of
  # a file in file order, so both recordings exist by the time this runs. Run
  # this test on its own with --filter and the recording is missing, so it does
  # the pass itself rather than passing vacuously on no evidence.
  #
  # The allowance is 10s of fixed slack plus 50ms per case per pass, roughly
  # twenty times the measured cost. It is deliberately loose: this is a hang
  # detector on shared CI hardware, not a performance assertion, and a red
  # budget on a slow runner would teach everyone to ignore it.
  local -r budget=$((10 + FUZZ_N / 10))
  local mode total=0 elapsed
  for mode in 'terminated' 'raw'; do
    if [[ ! -f "${BATS_FILE_TMPDIR}/elapsed-${mode}" ]]; then
      fuzz_scan_pass "${mode}"
    fi
    elapsed="$(< "${BATS_FILE_TMPDIR}/elapsed-${mode}")"
    total=$((total + elapsed))
  done
  ((total <= budget)) \
    || fail "scanning ${FUZZ_N} cases twice took ${total}s, over the ${budget}s budget (seed ${FUZZ_SEED})"
}
