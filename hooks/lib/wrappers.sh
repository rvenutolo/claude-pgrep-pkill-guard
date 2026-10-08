# shellcheck shell=bash
#
# Shell-wrapper and pipe-producer payload recovery, sourced by
# hooks/pgrep-pkill-guard-body.sh whenever the entry script loads the body --
# in human mode, or once the prefilter has let a payload through. Never
# executed: no shebang, no exec bit, and it must not set `set -Eeuo pipefail`,
# `IFS`, or the ERR trap -- the entry script owns them all, and a sourced file
# that sets them reconfigures its caller. Never add `shopt -s inherit_errexit`
# (invariant 2). Long options only where the BSD tool has them: this runs on
# BSD userland too (invariant 1).

# Wrappers that run their `-c` payload as code ON THIS MACHINE, in this process
# tree, so the payload's `bash -c ...` ancestor is the same one a pgrep inside it
# would match. `ssh`, `docker exec`, `kubectl exec`, `watch` and friends are
# deliberately absent: their payload runs somewhere else (or under a different
# ancestor), and the scanner's masking of it is correct rather than a gap. That
# distinction -- who runs the payload -- is the whole content of this feature;
# "is it quoted" is not the question.
readonly -a LOCAL_SHELL_WRAPPERS=('bash' 'sh' 'zsh' 'dash' 'ksh')

# The same, for the user-switching wrappers. `su -c` and `runuser -c` hand the
# payload to a shell here, under this process tree, so a pgrep inside one matches
# the same ancestor. They are listed apart from the shells only because of the
# operand budget below.
readonly -a LOCAL_USER_SWITCH_WRAPPERS=('su' 'runuser')

# How many wrapper payloads deep to follow. `bash -c 'bash -c "..."'` resolves at
# 2; the limit is a runaway backstop, not a judgement about nesting.
# shellcheck disable=SC2034 # read by hooks/lib/classify.sh
readonly MAX_PAYLOAD_DEPTH=4

# @description How many non-flag operands may precede a wrapper's `-c` before the wrapper stops
#              owning the option. This is the whole difference between the wrapper families.
#
#              A shell's own options end at its first operand: past that word it is running a
#              SCRIPT, and a `-c` among the words after it is an argument being handed to that
#              script. `bash deploy.sh -c '...'` runs deploy.sh; nothing executes the string, so
#              reading it as a payload is a false deny. Budget 0.
#
#              `su`/`runuser` take the user name as an operand and still parse a `-c` after it --
#              `su - user -c '...'` is the ordinary spelling and does run the payload. Exactly one,
#              though: past the user name the words are arguments to the login shell, so a `-c`
#              among them is not su's either. Budget 1. A bare `-` needs no budget, being already
#              spelled like a flag.
# @arg $1 token the token to test, already reduced to its basename
# @stdout the operand budget, when the token names a local wrapper
# @exitcode 0 the token is a local wrapper
# @exitcode 1 it is not
function wrappers::wrapper_operand_budget() {
  local -r token="$1"
  local wrapper
  for wrapper in "${LOCAL_SHELL_WRAPPERS[@]}"; do
    if [[ "${token}" == "${wrapper}" ]]; then
      printf '0'
      return 0
    fi
  done
  for wrapper in "${LOCAL_USER_SWITCH_WRAPPERS[@]}"; do
    if [[ "${token}" == "${wrapper}" ]]; then
      printf '1'
      return 0
    fi
  done
  return 1
}

# @description The text a pass-through producer on the left of a pipe hands to the wrapper on the
#              right, for the producers whose output is knowable from the command line alone.
#              `cat` is not one of them here -- what it passes through is a heredoc body, which
#              the caller resolves through the scanner's `<HD:len>` marker instead.
#
#              `echo` prints its operands, so a single literal operand IS the script. `-n`, `-e`
#              and `-E` are the only flags it has and are skipped; any other dash word is printed
#              literally, and counting it as a flag would hand the recursion a script the shell
#              never sees. More than one operand is skipped rather than reconstructed: the
#              separator is a space only because IFS says so, and a wrong reconstruction is a
#              false deny.
#
#              `printf` takes its format first, so one operand means the format itself is the
#              script (`printf 'cmd\n' | bash`) and two mean the format is a pass-through and the
#              second operand is (`printf '%s\n' 'cmd' | bash`). Three or more is a format applied
#              repeatedly, which cannot be reconstructed here either.
# @arg $1 name the producer's basename
# @arg $@ words its operand words, already unquoted
# @stdout the payload text, when there is one
# @exitcode 0 a payload was printed
# @exitcode 1 this producer hands the wrapper nothing knowable
function wrappers::pipe_producer_payload() {
  local -r name="$1"
  shift
  local -a literals=()
  local word
  case "${name}" in
    'echo')
      for word in "$@"; do
        [[ "${word}" =~ ^-[neE]+$ ]] && continue
        literals+=("${word}")
      done
      ((${#literals[@]} == 1)) || return 1
      printf '%s' "${literals[0]}"
      ;;
    'printf')
      for word in "$@"; do
        [[ "${word}" == '--' ]] && continue
        literals+=("${word}")
      done
      case "${#literals[@]}" in
        1) printf '%s' "${literals[0]}" ;;
        2) printf '%s' "${literals[1]}" ;;
        *) return 1 ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# @description Drop whatever a finished pipeline segment left for the next command.
# @arg $1 heredoc_var name of the carried heredoc ordinal variable (set)
# @arg $2 text_var name of the carried literal payload variable (set)
# @arg $3 text_set_var name of the flag saying whether text_var is meaningful (set)
# @exitcode 0 always; it ends on an assignment
function wrappers::pipe_carry_clear() {
  local -n carry_heredoc="$1" carry_text="$2" carry_text_set="$3"
  carry_heredoc=''
  carry_text=''
  carry_text_set=0
}

# @description Decide what a pipeline segment that just ended at a `|` leaves on the pipe for the
#              next command. A `cat` whose only operand is `-` (or none) and that read a heredoc
#              carries that heredoc's ordinal; an `echo`/`printf` whose literal can be
#              reconstructed carries the text. A segment with any redirection other than a heredoc
#              carries nothing: which fd it moved is not tracked, so the pipe may never see its output.
# @arg $1 heredoc_var name of the carried heredoc ordinal variable (set)
# @arg $2 text_var name of the carried literal payload variable (set)
# @arg $3 text_set_var name of the flag saying whether text_var is meaningful (set)
# @arg $4 seg_cmd the segment's command word
# @arg $5 seg_heredoc the heredoc ordinal the segment read, or empty
# @arg $6 seg_redir 1 when the segment carried any redirection other than a heredoc
# @arg $@ seg_words the segment's operand words, quotes already stripped
# @exitcode 0 always; a non-zero status here would fire the fail-open trap
# shellcheck disable=SC2034 # the carry_* namerefs are the caller's variables, which shellcheck cannot follow
function wrappers::segment_pipe_carry() {
  local -n carry_heredoc="$1" carry_text="$2" carry_text_set="$3"
  local -r seg_cmd="$4" seg_heredoc="$5" seg_redir="$6"
  shift 6
  local seg_ok=1 seg_word payload
  carry_heredoc=''
  carry_text=''
  carry_text_set=0
  ((seg_redir == 1)) && seg_ok=0
  for seg_word in "$@"; do
    [[ "${seg_word}" == '-' ]] || seg_ok=0
  done
  if ((seg_ok == 1)) && [[ "${seg_cmd}" == 'cat' && -n "${seg_heredoc}" ]]; then
    carry_heredoc="${seg_heredoc}"
  elif ((seg_redir == 0)) && payload="$(wrappers::pipe_producer_payload "${seg_cmd}" "$@")"; then
    carry_text="${payload}"
    carry_text_set=1
  fi
}

# @description Say whether the redirection starting at an offset gives its simple command a stdin
#              that is not the pipe that command sits on, as far as the command text shows.
#
#              Read from the raw command text rather than the token stream, because the stream
#              masks a quoted target's bytes. Only an input redirection of fd 0 (`<`, `<>`, `<<<`,
#              with or without an explicit `0`) whose target is a complete literal word counts: a
#              single-quoted word, a double-quoted word with no expansion in it, or a bare word of
#              plain path characters. A file target must also be absolute or under `~/`, since
#              what a relative path names depends on a directory the text does not show. `<&-`
#              counts too, since a closed stdin reads nothing.
#
#              Everything else answers no, so that a caller dropping a piped payload on a yes
#              fails closed. `<&N` duplicates a descriptor that may be the pipe itself (`<&0`). A
#              target with an expansion (`< "${f}"`, `<<< "$(cat)"`) or a process substitution
#              (`< <(cat)`) can hand the piped text back. So can a path that names the current
#              stdin (`/dev/stdin`, `/dev/fd/0`, `/proc/self/fd/0`), so any file target with a
#              `dev/` or `proc/` component answers no, `/dev/null` excepted. A second redirection
#              glued to the target (`</tmp/f</dev/stdin`) answers no as well. A symbolic link to
#              one of those paths is not visible in the text and answers yes. A heredoc is not
#              asked about here: its operator is matched before any other redirection.
# @arg $1 command the raw command string
# @arg $2 offset the offset of the redirection operator's first byte, its fd included
# @exitcode 0 the redirection replaces stdin with something that is not the pipe
# @exitcode 1 it does not, or that cannot be told from the text
function wrappers::redirection_replaces_stdin() {
  local -r command="$1" offset="$2"
  local operator target
  # ERE, evaluated unquoted in [[ =~ ]]. The operator group is followed by the
  # target group: `&-`, a quoted word, or a bare word. The tail requires the
  # word to end there, so a literal glued to an expansion (`'a'"${b}"`) or to
  # another redirection does not pass as a literal.
  local -r quoted="'[^']*'|\"[^\"\$\`\\\\]*\""
  local -r literal_re="^0?(<<<|<>|<)[[:blank:]]*(&-|${quoted}|[A-Za-z0-9_./~@%+=:,-]+)([[:space:];|&()]|\$)"
  [[ "${command:offset}" =~ ${literal_re} ]] || return 1
  operator="${BASH_REMATCH[1]}"
  target="${BASH_REMATCH[2]}"
  # A here-string's word is the stdin itself, not a path to open.
  if [[ "${operator}" == '<<<' || "${target}" == '&-' ]]; then
    return 0
  fi
  if [[ "${target}" == [\'\"]* ]]; then
    target="${target:1:${#target}-2}"
  fi
  # `dev/` and `proc/` are matched anywhere in the path on purpose: `/dev//stdin`,
  # `/dev/./fd/0` and `/tmp/../dev/stdin` all reach the same descriptor. The
  # tilde is bracketed because a bare `~/` in a case pattern is tilde-expanded.
  case "${target}" in
    '/dev/null') return 0 ;;
    *dev/* | *proc/*) return 1 ;;
    /* | [~]/*) return 0 ;;
    *) return 1 ;;
  esac
}

# @description Cut every outermost `$(...)`, `$((...))` and backtick region out of a token stream,
#              so that the simple command around it reads as if the region were one word, and
#              scan each region's own tokens for wrappers.
#
#              The scanner re-enters code context inside a region, so its tokens (`(`, `)`, the
#              backtick) look like command boundaries to a reader of the simple command that
#              contains it. They are not boundaries of that command: `FOO=$(true) bash` is one
#              simple command, and `bash > "$(mktemp)" <<EOF` still owns its heredoc. The region
#              is a command in its own right, though, and may hold a wrapper of its own, so its
#              tokens go to wrappers::shell_wrapper_payloads on their own, which prints that
#              region's payloads here.
#
#              A region is found the way the scanner finds it: a `(` glued to a `$` opens one,
#              and the first `)` closes it, except that inside an arithmetic region (`$((`) a `(`
#              nests, and so does a `(` directly followed by another `(`; a backtick closes a
#              backtick region and opens one anywhere else. A `(` that is neither, a subshell
#              or a process substitution, opens no region, and the first `)` after it closes
#              the enclosing one, as the scanner reads it.
#              A region with no close runs to the end of the stream, as the scanner reads it.
#
#              What the outer stream keeps of a region: the `$` word it hangs off, or a one-byte
#              word standing in for a backtick region that follows whitespace or touches an operator,
#              and an inert `<HO>` token for each heredoc operator and the body markers inside,
#              so that the heredoc ordinals of the operators and bodies after the region
#              still line up. A token glued directly behind the close (the closing quote of
#              `"$(mktemp)"`, the `x` of `$(true)x`) belongs to the same word and is dropped; an
#              operator glued there is kept.
#
#              Not handled: a heredoc whose operator is inside a region and whose body marker
#              is outside it (`$(cat <<EOF)` then the body on the next line). The region's
#              heredoc gets no body, and the ordinals outside it stay right.
# @arg $1 command the raw command string
# @arg $2 stream the token stream from scanner::scan_command
# @arg $3 outer_var name of the variable set to the stream with each outermost region cut out (set)
# @stdout the payloads found inside the cut regions, NUL-terminated
# @exitcode 0 always; it ends on an assignment
function wrappers::cut_substitutions() {
  local -r command="$1" stream="$2"
  local -n cut_outer="$3"
  local -r heredoc_re='^[0-9]*<<([^<]|$)'
  local offset token kind
  local -a open_kinds=()
  local outer='' region='' glue_at=-1 last_end=-1 last_token=''
  while IFS=$'\t' read -r offset token; do
    if [[ -z "${token}" ]]; then
      outer+="${offset}"$'\t'$'\n'
      continue
    fi
    kind=''
    case "${token}" in
      '`')
        if ((${#open_kinds[@]} > 0)) && [[ "${open_kinds[-1]}" == 'B' ]]; then
          kind='close'
        else
          kind='B'
        fi
        ;;
      '(')
        if [[ "${last_token}" == *'$' ]] && ((last_end == offset)); then
          if [[ "${command:offset+1:1}" == '(' ]]; then
            kind='A'
          else
            kind='P'
          fi
        elif ((${#open_kinds[@]} > 0)) && [[ "${open_kinds[-1]}" == 'A' || "${command:offset+1:1}" == '(' ]]; then
          kind='A'
        fi
        ;;
      ')')
        if ((${#open_kinds[@]} > 0)) && [[ "${open_kinds[-1]}" != 'B' ]]; then
          kind='close'
        fi
        ;;
    esac
    case "${kind}" in
      '')
        if ((${#open_kinds[@]} == 0)); then
          if ((offset != glue_at)) || tokens::is_operator "${token}" \
            || [[ "${token}" == '<'* || "${token}" == *'>'* ]]; then
            outer+="${offset}"$'\t'"${token}"$'\n'
          fi
        else
          region+="${offset}"$'\t'"${token}"$'\n'
          if [[ "${token}" =~ ${heredoc_re} ]]; then
            outer+="${offset}"$'\t''<HO>'$'\n'
          elif [[ "${token}" == '<HD:'*'>' ]]; then
            outer+="${offset}"$'\t'"${token}"$'\n'
          fi
        fi
        ;;
      'close')
        unset 'open_kinds[-1]'
        if ((${#open_kinds[@]} == 0)); then
          wrappers::shell_wrapper_payloads "${command}" "${region}"
          region=''
          glue_at="$((offset + 1))"
        else
          region+="${offset}"$'\t'"${token}"$'\n'
        fi
        ;;
      *)
        if ((${#open_kinds[@]} == 0)); then
          # A backtick that follows whitespace or touches an operator has no word
          # of its own to hang off, so one stands in for it.
          if [[ "${kind}" == 'B' ]] && { ((last_end != offset)) || tokens::is_operator "${last_token}"; }; then
            outer+="${offset}"$'\t'$'\001'$'\n'
          fi
        else
          region+="${offset}"$'\t'"${token}"$'\n'
        fi
        open_kinds+=("${kind}")
        ;;
    esac
    last_end="$((offset + ${#token}))"
    last_token="${token}"
  done <<< "${stream}"
  if ((${#open_kinds[@]} > 0)); then
    wrappers::shell_wrapper_payloads "${command}" "${region}"
  fi
  cut_outer="${outer}"
}

# @description Find the payloads of local shell wrappers and print each one's raw text,
#              NUL-terminated, with any surrounding quotes stripped.
#
#              A `-c` payload counts only when all of these hold: the wrapper is in command position
#              (so `ssh host bash -c ...` and a bare `echo bash -c ...` are both skipped, since
#              neither runs the payload here); a `-c` precedes it, in the same simple command,
#              within the wrapper's operand budget (see wrappers::wrapper_operand_budget -- this is what
#              keeps `bash deploy.sh -c '...'`, where the `-c` belongs to the script, from being
#              read as a payload); and the raw slice is a single fully quoted word. That last
#              condition is what keeps the recursion honest -- a double-quoted payload containing
#              a command substitution is NOT one opaque token, because the scanner deliberately
#              re-enters code context inside `$(...)`, and the outer scan can already see the
#              substitution for itself. Slicing a fragment of such a payload and recursing on it
#              would classify text that is not a command.
#
#              A heredoc feeding the wrapper's stdin (`bash <<'EOF'`, `sudo sh <<EOF`, `0<<EOF
#              bash`) is a payload too: the body is the script the wrapper runs, here. A
#              heredoc operator may carry an explicit fd like any other redirection (`0<<EOF`,
#              `3<<-EOF`); only fd 0 -- explicit or, far more commonly, the implicit default --
#              feeds the wrapper's stdin, so `bash 3<<EOF` is skipped: it redirects a different fd,
#              not the one the wrapper reads its script from. A heredoc counts when its operator is
#              seen in the wrapper's simple command with no `-c` before it and the simple command
#              then ends without an operand the budget does not cover -- such an operand makes the
#              body that script's stdin instead, unless a `-s` in a short flag cluster already said stdin IS
#              the script, in which case the operands are its positional parameters and the body
#              still runs here -- and, once `-s` has taken an operand, so is a later `-c`, which is
#              then just another positional word and starts no payload.
#
#              Any other redirection in the same simple command (`bash <<EOF >
#              /tmp/log`, `bash <<EOF 2>&1`) is neither an operand nor a flag: it leaves both the
#              budget and the wrapper's own pending heredoc alone. The `&` of a duplication
#              (`2>&1`, `<&3`, `>&file`) or of `&>`, and the `|` of `>|`, are part of the
#              redirection operator and do not end the simple command, so `bash 2>&1 <<EOF` and
#              `bash >| /tmp/log -c '...'` still own what follows. A background `&` does end it
#              (`bash <<EOF &`).
#
#              A redirection may precede the command word it attaches to
#              (`<<EOF bash`, `sudo <<EOF bash`), so a stdin heredoc seen while still hunting for
#              the command word is remembered and, once that word turns out to be a wrapper,
#              counted as its payload exactly as one written after the word would be. Both
#              delimiter forms count: the body text is what runs either way, and a `$(...)` inside
#              an unquoted body is seen by the outer scan and the recursion alike. The scanner
#              announces each body with a `<HD:len>` marker at the body's first byte, in operator
#              order, so a heredoc's ordinal among all `<<` tokens -- fd-prefixed or not -- is its
#              body's ordinal among the markers.
#
#              A payload piped into the wrapper counts too. The wrapper reads its script
#              from stdin, so the left of the pipe is what it runs -- but only when that side hands
#              the text through unchanged: `cat` with no operand but `-`, and no redirection of its
#              own, passes a heredoc body through, and `echo` / `printf` pass a literal operand (see
#              wrappers::pipe_producer_payload). A filter may emit something other than what it was given, so
#              `sed <<EOF | bash` is not read as a payload -- denying on text that never reaches the
#              wrapper is a false deny. The wrapper must be the pipe's very NEXT stage, since an
#              intermediate one (`cat <<EOF | tee f | bash`) can change the text on the way. Past the
#              pipe nothing else changes: the payload is handed to the same machinery, so an operand
#              still displaces stdin, a `-c` still claims the payload instead, `-s` still keeps stdin
#              as the script, and the prefix chain is still followed.
#
#              The pipe supplies the wrapper's stdin only when the wrapper's own simple command
#              does not give fd 0 something else. A heredoc (`echo '...' | bash <<EOF`), a literal
#              here-string, a literal file (`< f`, `<> f`) or a closed stdin (`<&-`) there, before
#              or after the wrapper word, is what bash hands the wrapper, so the piped text is
#              never read and is not a payload. A redirection of any other fd (`3<<EOF`,
#              `> /tmp/log`, `2>&1`) leaves the pipe in place, and so does one that may still be
#              the pipe (see wrappers::redirection_replaces_stdin).
#
#              Still not covered: content that is not on the command line at all
#              (`printf '%s' "${script}" | bash`, `curl ... | bash`), and a here-string fed to a
#              wrapper (`bash <<< 'script'`).
#
#              Payloads are NUL-terminated because a heredoc body is usually several lines and
#              has to reach classify::classify_command as one command.
#
#              An expansion inside a word of the wrapper's simple command (`FOO=$(true) bash`,
#              `FOO=${x} bash`, `bash > "$(mktemp)" <<EOF`) is part of that word: the scanner keeps the
#              braces of `${...}` inside the word, and wrappers::cut_substitutions takes a command
#              substitution out of the stream. An expansion as an operand (`bash ${x} <<EOF`) is an
#              operand like a quoted one, so the body is that script's stdin; its value is not on the
#              command line, which is a limit.
#
#              Command position is tracked as scanner::find_invocations tracks it, including the
#              prefix-word chain, so `sudo bash -c ...` is reached; the one difference is that this
#              reader steps over a substitution region as part of a word.
# @arg $1 command the raw command string
# @arg $2 tokens the token stream from scanner::scan_command
# @stdout one payload per NUL, quotes stripped; nothing if there are none
function wrappers::shell_wrapper_payloads() {
  local -r command="$1"
  local tokens="$2"
  # Regions are rare, and cutting them costs a pass over the stream, so the
  # raw text decides whether to look for any.
  if [[ "${command}" == *'$('* || "${command}" == *'`'* ]]; then
    wrappers::cut_substitutions "${command}" "${tokens}" tokens
  fi
  local at_cmd=1 in_wrapper=0 saw_c=0 saw_s=0 saw_s_operand=0 operands=0
  local offset token word next_at_cmd is_cmd_word raw budget
  # shellcheck disable=SC2034 # written through tokens::prefix_chain_step's namerefs, which shellcheck cannot follow
  local chain='' chain_skip=0 chain_operands=0
  local heredoc_seq=0 body_seq=0 pending='' leading_pending='' wanted=' ' expect_delim=0 len fd
  local expect_redir_target=0
  # The pipeline carry. `seg_*` is the simple command being read right
  # now; `pipe_*` is what an ended segment left behind for the next one, which
  # only the very next command word may claim. `pending_text` is the wrapper's
  # claimed literal payload, held until its simple command ends the same way a
  # heredoc ordinal is. `seg_stdin` says the segment gives its own fd 0
  # something that is not the pipe, and `pending_piped` that `pending` holds
  # the pipe's heredoc rather than one the wrapper wrote itself. At the flush
  # `seg_stdin` alone drops a claimed literal, and with `pending_piped` it
  # drops a claimed pipe heredoc: bash hands the wrapper the redirection and
  # the pipe is never read.
  local seg_cmd='' seg_heredoc='' seg_redir=0 seg_stdin=0
  local -a seg_words=()
  local pipe_heredoc='' pipe_text='' pipe_text_set=0 last_pipe_offset=-1
  local pending_text='' pending_text_set=0 pending_piped=0
  # A `<<` heredoc operator may carry a leading fd (`0<<`, `3<<-`), which is
  # ordinary redirection syntax; only fd 0 (empty or explicit `0`) feeds the
  # wrapper's stdin. `<<<` (and an fd-prefixed `0<<<`) is a here-string, not a
  # heredoc, so the next byte after `<<` must not itself be `<`. ERE,
  # evaluated unquoted in [[ =~ ]].
  local -r heredoc_re='^([0-9]*)<<([^<]|$)' bare_heredoc_re='^[0-9]*<<-?$'
  # Any other redirection: an optional fd, then a run of `<` and `>` (`>`, `>>`,
  # `<>`). The scanner emits the operator on its own, so the next token is the
  # target and is not an operand either. A `<<` heredoc operator also matches
  # and must stay ABOVE it: that branch `continue`s, so it never reaches here.
  # `stdin_redir_re` picks out the ones that redirect fd 0: an input operator
  # with no fd, or any operator with an explicit `0`.
  local -r redir_re='^[0-9]*[<>]+$'
  local -r stdin_redir_re='^(0?<|0>)'
  # `redir_single_re` picks out the bare `<` and `>` operators, which an `&` or
  # a `|` extends to `<&`, `>&` or `>|`; `glue_at` is the offset just past one,
  # where that `&` or `|` has to sit.
  local -r redir_single_re='^[0-9]*[<>]$'
  local glue_at=-1
  # The rest of this loop stays inline on purpose: the blocks share most of
  # the locals above, and a helper with that many namerefs is harder to read
  # than the block.
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    word="${token##*/}"

    # Heredoc bookkeeping. A bare `<<` / `<<-` token, fd-prefixed or not, is
    # followed by its delimiter as a separate word, which must not be spent
    # as an operand.
    if ((expect_delim == 1)); then
      expect_delim=0
      continue
    fi
    # A heredoc operator inside a cut region: it only keeps the ordinals of the
    # operators after it in step with the body markers.
    if [[ "${token}" == '<HO>' ]]; then
      heredoc_seq="$((heredoc_seq + 1))"
      continue
    fi
    if [[ "${token}" =~ ${bare_heredoc_re} ]]; then
      expect_delim=1
    fi
    if [[ "${token}" =~ ${heredoc_re} ]]; then
      heredoc_seq="$((heredoc_seq + 1))"
      fd="${BASH_REMATCH[1]}"
      if [[ -z "${fd}" || "${fd}" == '0' ]]; then
        # Remembered for the pipeline carry whoever owns it: bash applies the
        # LAST stdin heredoc of a simple command, so a later one replaces it.
        seg_heredoc="${heredoc_seq}"
        seg_stdin=1
        if ((in_wrapper == 1 && saw_c == 0)); then
          pending="${heredoc_seq}"
          pending_piped=0
        elif ((at_cmd == 1)); then
          # Still hunting for the command word: remember this stdin heredoc
          # in case that word turns out to be a wrapper.
          leading_pending="${heredoc_seq}"
        fi
      fi
      continue
    fi
    if [[ "${token}" == '<HD:'*'>' ]]; then
      body_seq="$((body_seq + 1))"
      if [[ "${wanted}" == *" ${body_seq} "* ]]; then
        len="${token#<HD:}"
        len="${len%>}"
        printf '%s\0' "${command:offset:len}"
      fi
      continue
    fi

    # An ordinary redirection on the wrapper's own simple command (`bash <<EOF
    # > /tmp/log`, `bash <<EOF 2>&1`) is neither an operand nor a flag: it
    # neither spends the budget nor ends the wrapper, so a heredoc the wrapper
    # wrote itself stays pending. The operand branch below would spend a zero
    # budget on it and drop the payload, and bash would run the body
    # unclassified.
    if ((expect_redir_target == 1)); then
      expect_redir_target=0
      # The tokenizer splits `2>&1` into `2>`, `&`, `1` and `>|` into `>`, `|`.
      # An `&` glued to a bare `<` or `>`, or a `|` glued to a bare `>`, is the
      # rest of that redirection operator and not the background operator or a
      # pipe: the simple command goes on, and the target is still to come.
      if ((offset == glue_at)) \
        && [[ "${token}" == '&' || ("${token}" == '|' && "${command:offset-1:1}" == '>') ]]; then
        expect_redir_target=1
        glue_at=-1
        continue
      fi
      # Any other operator here is no target. It ends the simple command and
      # must reach the flush below like any other.
      tokens::is_operator "${token}" || continue
    fi
    # `&>` and `&>>` arrive as an `&` and then the `>` token, which the branch
    # below reads as the redirection it is. A background `&` is never glued to
    # a `>`.
    if [[ "${token}" == '&' && "${command:offset+1:1}" == '>' ]]; then
      continue
    fi
    if [[ "${token}" =~ ${redir_re} ]]; then
      expect_redir_target=1
      glue_at=-1
      if [[ "${token}" =~ ${redir_single_re} ]]; then
        glue_at="$((offset + ${#token}))"
      fi
      # bash applies the last redirection of fd 0, so each one decides afresh:
      # a later one that may be the pipe again (`< /tmp/f <&3`) withdraws what
      # an earlier one, a heredoc included, established.
      if [[ "${token}" =~ ${stdin_redir_re} ]]; then
        if wrappers::redirection_replaces_stdin "${command}" "${offset}"; then
          seg_stdin=1
        else
          seg_stdin=0
        fi
      fi
      # A producer whose own output is redirected sends the wrapper nothing:
      # in `cat > f <<EOF | bash` the body lands in the file and bash reads an
      # empty pipe. Disqualify the segment rather than guess which fd it was.
      seg_redir=1
      continue
    fi

    if ((in_wrapper == 1)); then
      # `-s` in a short cluster says stdin IS the script, so the operands after
      # it are that script's positional parameters ($1...) rather than a script
      # to run in the body's place.
      if [[ "${word}" == -*s* && "${word}" != --* ]]; then
        saw_s=1
      fi
      if tokens::is_operator "${token}"; then
        # A redirection of the wrapper's own stdin replaces the pipe, so what
        # the pipe carried is never read; a heredoc the wrapper wrote itself
        # still counts.
        if [[ -n "${pending}" ]] && ((pending_piped == 0 || seg_stdin == 0)); then
          wanted+="${pending} "
        fi
        ((pending_text_set == 1 && seg_stdin == 0)) && printf '%s\0' "${pending_text}"
        in_wrapper=0
        saw_c=0
        saw_s=0
        saw_s_operand=0
        pending=''
        pending_text=''
        pending_text_set=0
      elif ((saw_c == 1)) && [[ "${word}" != -* ]]; then
        raw="${command:offset:${#token}}"
        if [[ ("${raw}" == \"*\" || "${raw}" == \'*\') && "${#raw}" -ge 2 ]]; then
          printf '%s\0' "${raw:1:${#raw}-2}"
        fi
        in_wrapper=0
        saw_c=0
        saw_s=0
        saw_s_operand=0
        pending=''
        pending_text=''
        pending_text_set=0
      elif [[ "${word}" == -*c* && "${word}" != --* ]] && ((saw_s_operand == 0)); then
        # A short cluster, so `bash -lc '...'` counts as well as `bash -c '...'`.
        # Once `-s` has taken an operand the wrapper's own option list is over:
        # in `bash -s arg -c '...'` the `-c` and the string after it are $2 and
        # $3 of the body, and nothing here runs that string.
        saw_c=1
      elif [[ "${word}" != -* ]]; then
        # An operand before any `-c`. Spend one from the budget, and once it is
        # gone the wrapper no longer owns the options that follow -- unless
        # `-s` already said stdin is the script, in which case no operand ever
        # displaces the body.
        if ((saw_s == 1)); then
          saw_s_operand=1
        fi
        if ((operands > 0)); then
          operands="$((operands - 1))"
        elif ((saw_s == 0)); then
          in_wrapper=0
          saw_c=0
          pending=''
          pending_text=''
          pending_text_set=0
        fi
      fi
    fi

    # The segment's operand words, kept in case it turns out to be a producer
    # on the left of a pipe. A word still in command position is the command
    # itself or a prefix's own option, neither of which the producer prints.
    # Nor does it print the value of a prefix's option (the `root` of `sudo -u
    # root echo ...`), which is out of command position but still the prefix's:
    # `chain_skip` is still set from the option when its value arrives here.
    if ((at_cmd == 0 && chain_skip == 0)) && ! tokens::is_operator "${token}" \
      && ! tokens::is_keyword "${token}"; then
      raw="${command:offset:${#token}}"
      if [[ ("${raw}" == \"*\" || "${raw}" == \'*\') && "${#raw}" -ge 2 ]]; then
        seg_words+=("${raw:1:${#raw}-2}")
      else
        seg_words+=("${raw}")
      fi
    fi

    if tokens::is_operator "${token}"; then
      if [[ "${token}" == '|' ]] && ((last_pipe_offset != offset - 1)); then
        wrappers::segment_pipe_carry pipe_heredoc pipe_text pipe_text_set \
          "${seg_cmd}" "${seg_heredoc}" "${seg_redir}" "${seg_words[@]}"
        last_pipe_offset="${offset}"
      elif [[ "${token}" == '|' ]]; then
        # The second `|` of a `||`, which is a conditional list and not a pipe:
        # nothing crosses it, so drop what the first `|` armed.
        wrappers::pipe_carry_clear pipe_heredoc pipe_text pipe_text_set
        last_pipe_offset="${offset}"
      elif [[ "${token}" == '&' ]] && ((last_pipe_offset == offset - 1)); then
        # `|&` extends the pipe it follows, so the carry it armed stands.
        last_pipe_offset="${offset}"
      else
        wrappers::pipe_carry_clear pipe_heredoc pipe_text pipe_text_set
      fi
      seg_cmd=''
      seg_heredoc=''
      seg_redir=0
      seg_stdin=0
      seg_words=()
      leading_pending=''
    elif tokens::is_keyword "${token}"; then
      leading_pending=''
    fi
    if tokens::prefix_chain_step "${token}" "${word}" "${at_cmd}" chain chain_skip chain_operands; then
      next_at_cmd=1
    else
      next_at_cmd=0
    fi
    # Leaving command position marks the command word, with one exception: a
    # prefix's value-taking option (`sudo -u`) leaves it only for its value,
    # and the chain step says so by setting `chain_skip`. Taking that option
    # for the command would drop the carry a wrapper further along the same
    # chain is about to claim (`echo '...' | sudo -u root bash`).
    is_cmd_word=0
    if ((at_cmd == 1 && next_at_cmd == 0 && chain_skip == 0)); then
      is_cmd_word=1
      seg_cmd="${word}"
    fi
    if ((at_cmd == 1)) && budget="$(wrappers::wrapper_operand_budget "${word}")"; then
      in_wrapper=1
      saw_c=0
      saw_s=0
      saw_s_operand=0
      operands="${budget}"
      pending="${leading_pending}"
      leading_pending=''
      pending_text=''
      pending_text_set=0
      pending_piped=0
      # A heredoc written on the wrapper's own simple command is the one bash
      # applies; the pipe only supplies stdin when nothing else did. Whether
      # anything else does is not known until the simple command ends, so the
      # pipe's payload is claimed here and dropped at the flush if `seg_stdin`
      # is set by then.
      if [[ -z "${pending}" && -n "${pipe_heredoc}" ]]; then
        pending="${pipe_heredoc}"
        pending_piped=1
      fi
      if ((pipe_text_set == 1)); then
        pending_text="${pipe_text}"
        pending_text_set=1
      fi
      wrappers::pipe_carry_clear pipe_heredoc pipe_text pipe_text_set
    elif ((is_cmd_word == 1)); then
      # A command word that is not a local wrapper: whatever the pipe carried is
      # this command's input, and nothing here runs it as a script.
      wrappers::pipe_carry_clear pipe_heredoc pipe_text pipe_text_set
    fi
    at_cmd="${next_at_cmd}"
  done <<< "${tokens}"

  # A wrapper whose simple command runs to the end of the input (`echo 'x' |
  # bash`) meets no operator to flush on. A heredoc payload needs no such
  # flush: its body marker always follows the <NL> that ended that command.
  if ((pending_text_set == 1 && seg_stdin == 0)); then
    printf '%s\0' "${pending_text}"
  fi
}
