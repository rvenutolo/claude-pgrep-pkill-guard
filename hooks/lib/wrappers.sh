# shellcheck shell=bash
#
# Shell-wrapper and pipe-producer payload recovery, sourced by
# hooks/pgrep-pkill-guard-body.sh once the entry script's prefilter has let a
# payload through. Never executed: no shebang, no exec bit, and it must not
# set `set -Eeuo pipefail`, `IFS`, or the ERR trap -- the entry script owns
# all three, and a sourced file that sets them reconfigures its caller. Never
# add `shopt -s inherit_errexit` (invariant 2). POSIX short flags, not GNU
# long options: this runs on BSD userland too (invariant 1).
# shellcheck disable=SC2034 # cross-part names: some names defined here are
# read by another part, or passed by nameref into one, and shellcheck sees a
# single file at a time.

# Wrappers that run their `-c` payload as code ON THIS MACHINE, in this process
# tree, so the payload's `bash -c ...` ancestor is the same one a pgrep inside it
# would match. `ssh`, `docker exec`, `kubectl exec`, `watch` and friends are
# deliberately absent: their payload runs somewhere else (or under a different
# ancestor), and the scanner's masking of it is correct rather than a gap. That
# distinction -- who runs the payload -- is the whole content of this feature;
# "is it quoted" is not the question (#155 entry 4).
readonly -a LOCAL_SHELL_WRAPPERS=('bash' 'sh' 'zsh' 'dash' 'ksh')

# The same, for the user-switching wrappers. `su -c` and `runuser -c` hand the
# payload to a shell here, under this process tree, so a pgrep inside one matches
# the same ancestor. They are listed apart from the shells only because of the
# operand budget below.
readonly -a LOCAL_USER_SWITCH_WRAPPERS=('su' 'runuser')

# How many wrapper payloads deep to follow. `bash -c 'bash -c "..."'` resolves at
# 2; the limit is a runaway backstop, not a judgement about nesting.
readonly MAX_PAYLOAD_DEPTH=4

# @description How many non-flag operands may precede a wrapper's `-c` before the wrapper stops
#              owning the option. This is the whole difference between the two wrapper families.
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
function wrapper_operand_budget() {
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
function pipe_producer_payload() {
  local -r name="$1"
  shift
  local -a literals=()
  local word
  case "${name}" in
    echo)
      for word in "$@"; do
        [[ "${word}" =~ ^-[neE]+$ ]] && continue
        literals+=("${word}")
      done
      ((${#literals[@]} == 1)) || return 1
      printf '%s' "${literals[0]}"
      ;;
    printf)
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

# @description Find the payloads of local shell wrappers and print each one's raw text,
#              NUL-terminated, with any surrounding quotes stripped.
#
#              A `-c` payload counts only when all three hold: the wrapper is in command position
#              (so `ssh host bash -c ...` and a bare `echo bash -c ...` are both skipped, since
#              neither runs the payload here); a `-c` precedes it, in the same simple command,
#              within the wrapper's operand budget (see wrapper_operand_budget -- this is what
#              keeps `bash deploy.sh -c '...'`, where the `-c` belongs to the script, from being
#              read as a payload); and the raw slice is a single fully quoted word. That last
#              condition is what keeps the recursion honest -- a double-quoted payload containing
#              a command substitution is NOT one opaque token, because the scanner deliberately
#              re-enters code context inside `$(...)`, and the outer scan can already see the
#              substitution for itself. Slicing a fragment of such a payload and recursing on it
#              would classify text that is not a command.
#
#              A heredoc feeding the wrapper's stdin (`bash <<'EOF'`, `sudo sh <<EOF`, `0<<EOF
#              bash`) is a payload too: the body is the script the wrapper runs, here (#184). A
#              heredoc operator may carry an explicit fd like any other redirection (`0<<EOF`,
#              `3<<-EOF`); only fd 0 -- explicit or, far more commonly, the implicit default --
#              feeds the wrapper's stdin, so `bash 3<<EOF` is skipped: it redirects a different fd,
#              not the one the wrapper reads its script from. A heredoc counts when its operator is
#              seen in the wrapper's simple command with no `-c` before it and the simple command
#              then ends without an operand spending the budget -- an operand makes the body that
#              script's stdin instead, unless a `-s` in a short flag cluster already said stdin IS
#              the script, in which case the operands are its positional parameters and the body
#              still runs here -- and, once `-s` has taken an operand, so is a later `-c`, which is
#              then just another positional word and starts no payload.
#
#              Any other redirection in the same simple command (`bash <<EOF >
#              /tmp/log`, `bash <<EOF 2>&1`) is neither an operand nor a flag: it leaves both the
#              budget and the pending heredoc alone.
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
#              A payload piped into the wrapper counts too (#186). The wrapper reads its script
#              from stdin, so the left of the pipe is what it runs -- but only when that side hands
#              the text through unchanged: `cat` with no operand but `-`, and no redirection of its
#              own, passes a heredoc body through, and `echo` / `printf` pass a literal operand (see
#              pipe_producer_payload). A filter may emit something other than what it was given, so
#              `sed <<EOF | bash` is not read as a payload -- denying on text that never reaches the
#              wrapper is a false deny. The wrapper must be the pipe's very NEXT stage, since an
#              intermediate one (`cat <<EOF | tee f | bash`) can change the text on the way. Past the
#              pipe nothing else changes: the payload is handed to the same machinery, so an operand
#              still displaces stdin, a `-c` still claims the payload instead, `-s` still keeps stdin
#              as the script, and the prefix chain is still followed.
#
#              Still not covered: content that is not on the command line at all
#              (`printf '%s' "${script}" | bash`, `curl ... | bash`), and a here-string fed to a
#              wrapper (`bash <<< 'script'`).
#
#              Payloads are NUL-terminated because a heredoc body is usually several lines and
#              has to reach classify_command as one command.
#
#              Command position is tracked exactly as find_invocations tracks it, including the
#              prefix-word chain, so `sudo bash -c ...` is reached.
# @arg $1 command the raw command string
# @arg $2 tokens the token stream from scan_command
# @stdout one payload per NUL, quotes stripped; nothing if there are none
function shell_wrapper_payloads() {
  local -r command="$1" tokens="$2"
  local at_cmd=1 in_wrapper=0 saw_c=0 saw_s=0 saw_s_operand=0 operands=0
  local offset token word next_at_cmd raw budget
  # shellcheck disable=SC2034 # written through prefix_chain_step's namerefs, which shellcheck cannot follow
  local chain='' chain_skip=0 chain_operands=0
  local heredoc_seq=0 body_seq=0 pending='' leading_pending='' wanted=' ' expect_delim=0 len fd
  local expect_redir_target=0
  # The pipeline carry (#186). `seg_*` is the simple command being read right
  # now; `pipe_*` is what an ended segment left behind for the next one, which
  # only the very next command word may claim. `pending_text` is the wrapper's
  # claimed literal payload, held until its simple command ends the same way a
  # heredoc ordinal is.
  local seg_cmd='' seg_heredoc='' seg_redir=0 seg_ok payload w
  local -a seg_words=()
  local pipe_heredoc='' pipe_text='' pipe_text_set=0 last_pipe_offset=-1
  local pending_text='' pending_text_set=0
  # A `<<` heredoc operator may carry a leading fd (`0<<`, `3<<-`), which is
  # ordinary redirection syntax; only fd 0 (empty or explicit `0`) feeds the
  # wrapper's stdin. `<<<` (and an fd-prefixed `0<<<`) is a here-string, not a
  # heredoc, so the next byte after `<<` must not itself be `<`. ERE,
  # evaluated unquoted in [[ =~ ]].
  local -r heredoc_re='^([0-9]*)<<([^<]|$)' bare_heredoc_re='^[0-9]*<<-?$'
  # Any other redirection: an optional fd, then `>`/`<`, `>>`/`<>`, or `&>`.
  # Two other token shapes match it and must therefore stay ABOVE it: a `<<`
  # heredoc operator, and a `<HD:5>` body marker -- both branches above
  # `continue`, so neither ever reaches here. The newline token `<NL>` matches
  # too and cannot be handled that way, since it is an operator that has to
  # reach the flush below, so it is excluded by name.
  # `redir_bare_re` says the operator carries no attached target (`> f` rather
  # than `>f`), in which case the next token is the target and is not an
  # operand either.
  local -r redir_re='^[0-9]*(&?[<>]|[<>]{2})' redir_bare_re='^[0-9]*[<>&|]+$'
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
    if [[ "${token}" =~ ${bare_heredoc_re} ]]; then
      expect_delim=1
    fi
    if [[ "${token}" =~ ${heredoc_re} ]]; then
      heredoc_seq=$((heredoc_seq + 1))
      fd="${BASH_REMATCH[1]}"
      if [[ -z "${fd}" || "${fd}" == '0' ]]; then
        # Remembered for the pipeline carry whoever owns it: bash applies the
        # LAST stdin heredoc of a simple command, so a later one replaces it.
        seg_heredoc="${heredoc_seq}"
        if ((in_wrapper == 1 && saw_c == 0)); then
          pending="${heredoc_seq}"
        elif ((at_cmd == 1)); then
          # Still hunting for the command word: remember this stdin heredoc
          # in case that word turns out to be a wrapper.
          leading_pending="${heredoc_seq}"
        fi
      fi
      continue
    fi
    if [[ "${token}" == '<HD:'*'>' ]]; then
      body_seq=$((body_seq + 1))
      if [[ "${wanted}" == *" ${body_seq} "* ]]; then
        len="${token#<HD:}"
        len="${len%>}"
        printf '%s\0' "${command:offset:len}"
      fi
      continue
    fi

    # An ordinary redirection on the wrapper's own simple command (`bash <<EOF
    # > /tmp/log`, `bash <<EOF 2>&1`) is neither an operand nor a flag: it
    # neither spends the budget nor ends the wrapper, so a heredoc already
    # pending stays pending. Left to the operand branch below it exhausted a
    # zero budget and dropped the payload, and bash ran the body unclassified.
    if ((expect_redir_target == 1)); then
      # The tokenizer splits `2>&1` into `2>`, `&`, `1`, so the token after a
      # bare operator can be an operator rather than the target. It ends the
      # simple command and must reach the flush below like any other.
      expect_redir_target=0
      is_operator "${token}" || continue
    fi
    if [[ "${token}" != '<NL>' && "${token}" =~ ${redir_re} ]]; then
      [[ "${token}" =~ ${redir_bare_re} ]] && expect_redir_target=1
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
      if is_operator "${token}"; then
        [[ -n "${pending}" ]] && wanted+="${pending} "
        ((pending_text_set == 1)) && printf '%s\0' "${pending_text}"
        in_wrapper=0
        saw_c=0
        saw_s=0
        saw_s_operand=0
        pending=''
        pending_text=''
        pending_text_set=0
      elif ((saw_c == 1)) && [[ "${word}" != -* ]]; then
        raw="${command:offset:${#token}}"
        if [[ ("${raw}" == \"*\" || "${raw}" == \'*\') && ${#raw} -ge 2 ]]; then
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
          operands=$((operands - 1))
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
    if ((at_cmd == 0)) && ! is_operator "${token}" && ! is_keyword "${token}"; then
      raw="${command:offset:${#token}}"
      if [[ ("${raw}" == \"*\" || "${raw}" == \'*\') && ${#raw} -ge 2 ]]; then
        seg_words+=("${raw:1:${#raw}-2}")
      else
        seg_words+=("${raw}")
      fi
    fi

    if is_operator "${token}"; then
      if [[ "${token}" == '|' ]] && ((last_pipe_offset != offset - 1)); then
        pipe_heredoc=''
        pipe_text=''
        pipe_text_set=0
        seg_ok=1
        ((seg_redir == 1)) && seg_ok=0
        for w in ${seg_words[@]+"${seg_words[@]}"}; do
          [[ "${w}" == '-' ]] || seg_ok=0
        done
        if ((seg_ok == 1)) && [[ "${seg_cmd}" == 'cat' && -n "${seg_heredoc}" ]]; then
          pipe_heredoc="${seg_heredoc}"
        elif ((seg_redir == 0)) \
          && payload="$(pipe_producer_payload "${seg_cmd}" ${seg_words[@]+"${seg_words[@]}"})"; then
          pipe_text="${payload}"
          pipe_text_set=1
        fi
        last_pipe_offset="${offset}"
      elif [[ "${token}" == '|' ]]; then
        # The second `|` of a `||`, which is a conditional list and not a pipe:
        # nothing crosses it, so drop what the first `|` armed.
        pipe_heredoc=''
        pipe_text=''
        pipe_text_set=0
        last_pipe_offset="${offset}"
      elif [[ "${token}" == '&' ]] && ((last_pipe_offset == offset - 1)); then
        # `|&` extends the pipe it follows, so the carry it armed stands.
        last_pipe_offset="${offset}"
      else
        pipe_heredoc=''
        pipe_text=''
        pipe_text_set=0
      fi
      seg_cmd=''
      seg_heredoc=''
      seg_redir=0
      seg_words=()
      leading_pending=''
    elif is_keyword "${token}"; then
      leading_pending=''
    fi
    if prefix_chain_step "${token}" "${word}" "${at_cmd}" chain chain_skip chain_operands; then
      next_at_cmd=1
    else
      next_at_cmd=0
    fi
    if ((at_cmd == 1 && next_at_cmd == 0)); then
      seg_cmd="${word}"
    fi
    if ((at_cmd == 1)) && budget="$(wrapper_operand_budget "${word}")"; then
      in_wrapper=1
      saw_c=0
      saw_s=0
      saw_s_operand=0
      operands="${budget}"
      pending="${leading_pending}"
      leading_pending=''
      pending_text=''
      pending_text_set=0
      # A heredoc written on the wrapper's own simple command is the one bash
      # applies; the pipe only supplies stdin when nothing else did.
      if [[ -z "${pending}" && -n "${pipe_heredoc}" ]]; then
        pending="${pipe_heredoc}"
      fi
      if ((pipe_text_set == 1)); then
        pending_text="${pipe_text}"
        pending_text_set=1
      fi
      pipe_heredoc=''
      pipe_text=''
      pipe_text_set=0
    elif ((at_cmd == 1 && next_at_cmd == 0)); then
      # A command word that is not a local wrapper: whatever the pipe carried is
      # this command's input, and nothing here runs it as a script.
      pipe_heredoc=''
      pipe_text=''
      pipe_text_set=0
    fi
    at_cmd="${next_at_cmd}"
  done <<< "${tokens}"

  # A wrapper whose simple command runs to the end of the input (`echo 'x' |
  # bash`) meets no operator to flush on. A heredoc payload needs no such
  # flush: its body marker always follows the <NL> that ended that command.
  if ((pending_text_set == 1)); then
    printf '%s\0' "${pending_text}"
  fi
}
