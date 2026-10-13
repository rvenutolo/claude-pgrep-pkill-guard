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
# would match. `ssh`, `docker exec`, `kubectl exec` and friends are
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

# The builtins that run a file's text in the current shell. They are wrappers only for an operand
# that names their own stdin (see wrappers::names_own_stdin): any other operand is a file the
# guard cannot read, and they take no `-c`.
readonly -a LOCAL_SOURCE_BUILTINS=('source' '.')

# The long options of a shell, without their dashes. bash reads each with one dash as well as with
# two (`-login`, `-norc`), so for `bash` and `sh` a one-dash word that spells one is that option
# and not a cluster of short flags: its letters are no `-c`, `-s` or `-o`. `emulate` is zsh's. The ones in
# SHELL_WRAPPER_VALUE_OPTIONS take the next word as their value, and that word is no operand:
# counted as one it would be taken for the script to run, and drop the payload the wrapper reads.
readonly -a SHELL_WRAPPER_LONG_OPTIONS=(
  'debugger' 'dump-po-strings' 'dump-strings' 'emulate' 'help' 'init-file' 'login' 'noediting'
  'noprofile' 'norc' 'posix' 'pretty-print' 'rcfile' 'restricted' 'verbose' 'version'
)
readonly -a SHELL_WRAPPER_VALUE_OPTIONS=('emulate' 'init-file' 'rcfile')
# The long options of `su` and `runuser` that take the next word as their value, and the ones
# whose value is the payload, as `-c`'s is.
readonly -a USER_SWITCH_VALUE_OPTIONS=('--shell' '--group' '--supp-group' '--whitelist-environment' '--user')
readonly -a USER_SWITCH_COMMAND_OPTIONS=('--command' '--session-command')

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
  for wrapper in "${LOCAL_SOURCE_BUILTINS[@]}"; do
    if [[ "${token}" == "${wrapper}" ]]; then
      printf '0'
      return 0
    fi
  done
  return 1
}

# @description True when a script operand names the stdin of the command it is written on, so
#              that the script the wrapper runs is whatever its stdin holds (`bash /dev/stdin`,
#              `source /dev/fd/0`). The directory is matched at the end of any path, as
#              wrappers::redirection_replaces_stdin matches it: `/dev//stdin` is not caught, and
#              `/tmp/../dev/stdin` is.
# @arg $1 path the operand, with any surrounding quotes stripped
# @exitcode 0 the operand names the command's own stdin
# @exitcode 1 it names something else
function wrappers::names_own_stdin() {
  local -r path="$1"
  [[ "${path}" == *dev/stdin || "${path}" == *dev/fd/0 || "${path}" == *proc/self/fd/0 ]]
}

# @description What an option word of a local wrapper says: how many of the words after it are
#              its values, whether it is the `-c` that makes the next operand the payload, and
#              whether it is the `-s` that makes stdin the script.
#
#              A shell's long option is in SHELL_WRAPPER_LONG_OPTIONS, with two dashes, or for
#              `bash` and `sh` with one, and is never a cluster. In any other one-dash or one-plus
#              word of a shell each letter is a flag. `bash`, `sh` and `dash` take an option name
#              from the next word for each `o` (`-o pipefail`, `-euo pipefail`), and `bash` and
#              `sh` for each `O` as well;
#              the other letters stay flags. `zsh` and `ksh` read the name attached: the first
#              `o` ends the flags, the rest of the word is the name (`-oerrexit`), and the next
#              word is taken only when the `o` is the last letter. Their `O` is a flag. One or
#              two letters behind the `o` are too few for a name and stay flags.
#
#              `su` and `runuser` read a cluster as getopt does: the first letter that takes a
#              value ends the flags, and it takes the next word only when it is the last letter
#              (`-s /bin/sh`, but not `-s/bin/sh`). When that letter is `c`, the value is the
#              payload. Their `-s` names the shell to run; it is reported as `-s` all the same,
#              which keeps a piped text read as the script and fails closed.
# @arg $1 word the option word as written, with its leading `-` or `+`
# @arg $2 wrapper the wrapper's name, one of LOCAL_SHELL_WRAPPERS or LOCAL_USER_SWITCH_WRAPPERS
# @stdout `<values>:<c>:<s>`: the number of value words, then 1 or 0 for `-c` and for `-s`
# @exitcode 0 always
function wrappers::wrapper_option_facts() {
  local -r word="$1" wrapper="$2"
  local option valued name letters flags first values=0 has_c=0 has_s=0
  if [[ "${wrapper}" == 'su' || "${wrapper}" == 'runuser' ]]; then
    if [[ "${word}" == --* ]]; then
      for option in "${USER_SWITCH_VALUE_OPTIONS[@]}"; do
        [[ "${word}" == "${option}" ]] && values=1
      done
      for option in "${USER_SWITCH_COMMAND_OPTIONS[@]}"; do
        [[ "${word}" == "${option}" ]] && has_c=1
      done
    else
      letters="${word:1}"
      flags="${letters%%[csgGwu]*}"
      first="${letters:${#flags}:1}"
      if [[ "${first}" == 'c' ]]; then
        has_c=1
      elif [[ -n "${first}" ]]; then
        [[ "${first}" == 's' ]] && has_s=1
        ((${#flags} + 1 == ${#letters})) && values=1
      fi
    fi
    printf '%s:%s:%s' "${values}" "${has_c}" "${has_s}"
    return 0
  fi
  name="${word:1}"
  name="${name#-}"
  for option in "${SHELL_WRAPPER_LONG_OPTIONS[@]}"; do
    # With one dash only for `bash`, and for `sh`, which may be bash: to any other shell that
    # word is a cluster, and its `c` and `s` are flags.
    [[ "${word}" == --* || "${wrapper}" == 'bash' || "${wrapper}" == 'sh' ]] || break
    [[ "${name}" == "${option}" ]] || continue
    for valued in "${SHELL_WRAPPER_VALUE_OPTIONS[@]}"; do
      [[ "${name}" == "${valued}" ]] && values=1
    done
    printf '%s:0:0' "${values}"
    return 0
  done
  if [[ "${word}" == --* ]]; then
    printf '0:0:0'
    return 0
  fi
  letters="${word:1}"
  case "${wrapper}" in
    'zsh' | 'ksh')
      flags="${letters%%o*}"
      if [[ "${flags}" != "${letters}" ]]; then
        ((${#flags} + 1 == ${#letters})) && values=1
        # No option name is as short as two letters, so letters that few behind the `o` are
        # still read as flags (`-os`): the reading that keeps a `-c` or `-s` fails closed.
        if ((${#letters} - ${#flags} - 1 > 2)); then
          letters="${flags}"
        fi
      fi
      ;;
    'bash' | 'sh')
      flags="${letters//[!oO]/}"
      values="${#flags}"
      ;;
    *)
      flags="${letters//[!o]/}"
      values="${#flags}"
      ;;
  esac
  [[ "${letters}" == *c* ]] && has_c=1
  [[ "${letters}" == *s* ]] && has_s=1
  printf '%s:%s:%s' "${values}" "${has_c}" "${has_s}"
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
#              next command. A `cat` whose only operand is `-` (or none) and whose stdin is still the
#              heredoc it read carries that heredoc's ordinal, and one reading a literal here-string
#              carries its text; an `echo`/`printf` whose literal can be reconstructed carries the text.
#              A segment whose stdout was moved off the pipe carries nothing. A redirection of another
#              fd (`2>&1`, `3> f`) or of stdin leaves the pipe where it was, so the segment still
#              carries what it prints.
# @arg $1 heredoc_var name of the carried heredoc ordinal variable (set)
# @arg $2 text_var name of the carried literal payload variable (set)
# @arg $3 text_set_var name of the flag saying whether text_var is meaningful (set)
# @arg $4 seg_cmd the segment's command word
# @arg $5 seg_heredoc the heredoc ordinal the segment read, or empty
# @arg $6 seg_stdout_moved 1 when a redirection of the segment's stdout may have taken it off the pipe
# @arg $7 seg_stdin_kind the kind of the segment's last fd 0 redirection (see wrappers::stdin_reaches_wrapper)
# @arg $8 seg_here_text the text of the segment's literal here-string, read when seg_here_set is 1
# @arg $9 seg_here_set 1 when that here-string may still be the segment's stdin
# @arg $@ seg_words the segment's operand words, quotes already stripped
# @exitcode 0 always; a non-zero status here would fire the fail-open trap
# shellcheck disable=SC2034 # the carry_* namerefs are the caller's variables, which shellcheck cannot follow
function wrappers::segment_pipe_carry() {
  local -n carry_heredoc="$1" carry_text="$2" carry_text_set="$3"
  local -r seg_cmd="$4" seg_heredoc="$5" seg_stdout_moved="$6" seg_stdin_kind="$7" seg_here_text="$8" seg_here_set="$9"
  shift 9
  local seg_ok=1 seg_word payload
  carry_heredoc=''
  carry_text=''
  carry_text_set=0
  ((seg_stdout_moved == 1)) && seg_ok=0
  for seg_word in "$@"; do
    [[ "${seg_word}" == '-' ]] || seg_ok=0
  done
  if ((seg_ok == 1)) && [[ "${seg_cmd}" == 'cat' ]] && ((seg_here_set == 1)); then
    carry_text="${seg_here_text}"
    carry_text_set=1
  elif ((seg_ok == 1)) && [[ "${seg_cmd}" == 'cat' && -n "${seg_heredoc}" ]] \
    && wrappers::stdin_reaches_wrapper "${seg_stdin_kind}" 'heredoc'; then
    carry_heredoc="${seg_heredoc}"
  elif ((seg_stdout_moved == 0)) && payload="$(wrappers::pipe_producer_payload "${seg_cmd}" "$@")"; then
    carry_text="${payload}"
    carry_text_set=1
  fi
}

# @description Mark heredoc bodies as wanted, and print the ones whose marker has already gone by.
#              A body is printed when its marker is read if it is wanted by then, so a body announced
#              before the wrapper that claims it (a group's producer reading a heredoc inside the group,
#              `{ cat <<EOF ... EOF } | bash`) is printed here instead.
# @arg $1 wanted_var name of the space-delimited list of wanted ordinals (set)
# @arg $2 bodies_var name of the array of heredoc bodies by ordinal
# @arg $3 seen_seq the number of body markers read so far
# @arg $4 ordinals the space-separated ordinals being claimed
# @stdout each newly claimed body that was announced already, NUL-terminated
# @exitcode 0 always
# shellcheck disable=SC2034 # wanted_ref is the caller's variable, which shellcheck cannot follow
function wrappers::claim_heredocs() {
  local -n wanted_ref="$1" bodies_ref="$2"
  local -r seen_seq="$3" ordinals="$4"
  local -a claimed=()
  local claim_ord
  IFS=' ' read -r -a claimed <<< "${ordinals}"
  for claim_ord in "${claimed[@]}"; do
    [[ "${wanted_ref}" == *" ${claim_ord} "* ]] && continue
    wanted_ref+="${claim_ord} "
    if ((claim_ord <= seen_seq)); then
      printf '%s\0' "${bodies_ref[claim_ord]}"
    fi
  done
}

# @description Say whether a payload from one source is what a wrapper's stdin ends up reading.
#              bash applies the last redirection of fd 0 in a simple command, so exactly one source
#              wins. The kind says what the last one was, as far as the command text shows:
#              `` (none: the wrapper reads the pipe it sits on), `heredoc` (its own heredoc),
#              `text` (a here-string), `replaced` (a literal file or a closed stdin, proven not
#              to be the pipe) or `maybe-pipe` (a duplicated descriptor, a process substitution
#              or an expansion, which may be the pipe itself).
#
#              `maybe-pipe` keeps both the pipe and a heredoc the wrapper wrote itself. Neither can
#              be shown displaced, and a payload kept wrongly is a false deny where one dropped
#              wrongly is a false allow.
# @arg $1 kind the kind of the last fd 0 redirection of the segment or group, empty for none
# @arg $2 source_name `pipe` for a payload the pipe carried, `heredoc` for one the wrapper wrote itself
# @exitcode 0 the payload reaches the wrapper, or cannot be shown not to
# @exitcode 1 a later redirection of fd 0 displaces it
function wrappers::stdin_reaches_wrapper() {
  local -r kind="$1" source_name="$2"
  case "${kind}:${source_name}" in
    ':pipe' | 'maybe-pipe:pipe' | 'heredoc:heredoc' | 'maybe-pipe:heredoc') return 0 ;;
    *) return 1 ;;
  esac
}

# @description Name what an fd 0 redirection makes of the stdin of the command it attaches to, in the
#              vocabulary of wrappers::stdin_reaches_wrapper: `replaced` for a literal file or a closed
#              stdin, `text` for a literal here-string, `maybe-pipe` for anything the command text does
#              not resolve (see wrappers::redirection_replaces_stdin). The text of a literal here-string
#              is what the command reads, so it comes back too.
# @arg $1 command the raw command string
# @arg $2 offset the offset of the redirection operator's first byte, its fd included
# @arg $3 operator the operator token
# @arg $4 kind_var name of the variable that receives the kind (set)
# @arg $5 text_var name of the variable that receives the here-string's text, empty for any other kind (set)
# @exitcode 0 always
# shellcheck disable=SC2034 # the kind_ref nameref is the caller's variable, which shellcheck cannot follow
function wrappers::redirection_stdin_kind() {
  local -r command="$1" offset="$2" operator="$3" text_var="$5"
  local -n kind_ref="$4"
  if ! wrappers::redirection_replaces_stdin "${command}" "${offset}" "${text_var}"; then
    kind_ref='maybe-pipe'
  elif [[ "${operator}" == *'<<<' ]]; then
    kind_ref='text'
  else
    kind_ref='replaced'
  fi
}

# @description Name the closing word that ends the group or compound command a token opens.
# @arg $1 token the token
# @arg $2 at_cmd 1 when the token is in command position, which a keyword must be to open anything
# @stdout the closing token (`}`, `)`, `fi`, `done` or `esac`); nothing when the token opens nothing
# @exitcode 0 always
function wrappers::group_closer() {
  local -r token="$1" at_cmd="$2"
  case "${token}" in
    '{') printf '%s' '}' ;;
    '(') printf '%s' ')' ;;
    'if') ((at_cmd == 1)) && printf '%s' 'fi' ;;
    'while' | 'until' | 'for' | 'select') ((at_cmd == 1)) && printf '%s' 'done' ;;
    'case') ((at_cmd == 1)) && printf '%s' 'esac' ;;
    *) ;;
  esac
  return 0
}

# @description Say where the stdin of a group or compound command ends up, from the redirections
#              written after its closing word (`{ bash; } < f`, `done <<< x`). The group's stdin is
#              what every command inside it reads, so this decides whether a pipe into the group
#              still reaches the wrappers in it, and which heredoc, if the group has one of its own,
#              they read. An unbalanced group has no closing word to read and answers none.
#
#              A heredoc's ordinal counts the heredoc operators in the whole command, in text order:
#              the ones before the group (`base_seq`), those inside it, and those among its
#              redirections up to the one that is its stdin. A heredoc delimiter word is not a
#              closing word, so `cat <<fi` inside a group does not close an `if`.
#
#              It also says whether the group's stdout is the pipe it sits on the left of: a `|` (not
#              `||`) right after the closer and its redirections, with no redirection of fd 1 among
#              them. The commands inside such a group are what the next stage reads. A group whose stdout
#              is redirected prints nothing into any pipe around it, and says so in the fourth field.
#
#              A literal here-string on the group (`{ bash; } <<< 'cmd'`) is its stdin as well, and its
#              text comes back as the last field. A later redirection that may be that same descriptor
#              (`<&0`, `< /dev/stdin`) leaves it in place, and only a later one that provably replaces
#              fd 0 drops it.
# @arg $1 command the raw command string
# @arg $2 stream the token stream after the group's opening token
# @arg $3 first_closer the closing word the opening token expects
# @arg $4 base_seq the number of heredoc operators before the group's opening token
# @stdout `<kind>:<ordinal>:<piped>:<moved>:<here_set>:<text>`: the kind of the last fd 0 redirection after the closer,
#         empty for none; when that kind is `heredoc`, the ordinal of its body (otherwise empty); 1 when
#         the group's stdout is the pipe it sits on the left of, else 0; 1 when a redirection of fd 1
#         after the closer may have taken its stdout elsewhere, else 0; 1 when a literal here-string may
#         still be the group's stdin, else 0; and that here-string's text (otherwise empty), which may
#         hold colons and newlines and so comes last
# @exitcode 0 always
function wrappers::group_stdin_kind() {
  local -r command="$1" stream="$2" first_closer="$3" base_seq="$4"
  local -a closers=("${first_closer}")
  local offset token closer inner_at_cmd=1 closed=0 expect_target=0 expect_delim=0 glue_at=-1 kind=''
  local seq="${base_seq}" ordinal='' piped=0 moved=0 here_text='' here_set=0 redirect_text=''
  local -r redir_re='^([0-9]*[<>]+|&>>?)$' heredoc_re='^([0-9]*)<<([^<]|$)' bare_heredoc_re='^[0-9]*<<-?$'
  local -r single_re='^[0-9]*[<>]$' stdin_redir_re='^(0?<|0>)' stdout_redir_re='^(&>|1?>|1<>)'
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    if ((closed == 0)); then
      if ((expect_delim == 1)); then
        expect_delim=0
        inner_at_cmd=0
        continue
      fi
      if [[ "${token}" == '<HO>' ]]; then
        seq="$((seq + 1))"
        continue
      fi
      if [[ "${token}" =~ ${bare_heredoc_re} ]]; then
        expect_delim=1
      fi
      if [[ "${token}" =~ ${heredoc_re} ]]; then
        seq="$((seq + 1))"
      fi
      closer="$(wrappers::group_closer "${token}" "${inner_at_cmd}")"
      if [[ -n "${closer}" ]]; then
        closers+=("${closer}")
      elif [[ "${token}" == "${closers[-1]}" ]] \
        && { [[ "${token}" == ')' ]] || ((inner_at_cmd == 1)); }; then
        unset 'closers[-1]'
        ((${#closers[@]} == 0)) && closed=1
      fi
      if tokens::is_operator "${token}" || tokens::is_keyword "${token}"; then
        inner_at_cmd=1
      else
        inner_at_cmd=0
      fi
      continue
    fi
    if ((expect_delim == 1)); then
      expect_delim=0
      continue
    fi
    if ((expect_target == 1)); then
      expect_target=0
      if ((offset == glue_at)) && [[ "${token}" == '&' || ("${token}" == '|' && "${command:offset-1:1}" == '>') ]]; then
        expect_target=1
        glue_at=-1
      fi
      continue
    fi
    # `<<-` is no `redir_re` match (the dash), but it is a redirection.
    if [[ ! ("${token}" =~ ${redir_re} || "${token}" =~ ${heredoc_re}) ]]; then
      if [[ "${token}" == '|' && "${command:offset+1:1}" != '|' ]]; then
        piped=1
      fi
      break
    fi
    if [[ "${token}" =~ ${stdout_redir_re} ]]; then
      moved=1
    fi
    expect_target=1
    glue_at=-1
    [[ "${token}" =~ ${single_re} ]] && glue_at="$((offset + ${#token}))"
    if [[ "${token}" =~ ${bare_heredoc_re} ]]; then
      expect_delim=1
    fi
    if [[ "${token}" =~ ${heredoc_re} ]]; then
      seq="$((seq + 1))"
      expect_target=0
      if [[ -z "${BASH_REMATCH[1]}" || "${BASH_REMATCH[1]}" == '0' ]]; then
        kind='heredoc'
        ordinal="${seq}"
        here_text=''
        here_set=0
      fi
    elif [[ "${token}" =~ ${stdin_redir_re} ]]; then
      wrappers::redirection_stdin_kind "${command}" "${offset}" "${token}" kind redirect_text
      case "${kind}" in
        'text')
          here_text="${redirect_text}"
          here_set=1
          ;;
        'maybe-pipe') ;;
        *)
          here_text=''
          here_set=0
          ;;
      esac
    fi
  done <<< "${stream}"
  if [[ "${kind}" != 'heredoc' ]]; then
    ordinal=''
  fi
  if ((moved == 1)); then
    piped=0
  fi
  printf '%s:%s:%s:%s:%s:%s' "${kind}" "${ordinal}" "${piped}" "${moved}" "${here_set}" "${here_text}"
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
#              Everything else answers no, so that a caller dropping a payload on a yes
#              fails closed. `<&N` duplicates a descriptor that may be the pipe itself (`<&0`). A
#              target with an expansion (`< "${f}"`, `<<< "$(cat)"`) or a process substitution
#              (`< <(cat)`) can hand the piped text back. So can a path that names the current
#              stdin (`/dev/stdin`, `/dev/fd/0`, `/proc/self/fd/0`), so any file target with a
#              `dev/` or `proc/` component answers no, `/dev/null` excepted. A second redirection
#              glued to the target (`</tmp/f</dev/stdin`) answers no as well. A symbolic link to
#              one of those paths is not visible in the text and answers yes. A heredoc is not
#              asked about here: its operator is matched before any other redirection.
#
#              A literal here-string is the stdin itself, so its text, quotes stripped, is what the
#              redirected command reads.
# @arg $1 command the raw command string
# @arg $2 offset the offset of the redirection operator's first byte, its fd included
# @arg $3 text_var name of the variable that receives the here-string's text, empty otherwise (set)
# @exitcode 0 the redirection replaces stdin with something that is not the pipe
# @exitcode 1 it does not, or that cannot be told from the text
# shellcheck disable=SC2034 # the text_ref nameref is the caller's variable, which shellcheck cannot follow
function wrappers::redirection_replaces_stdin() {
  local -r command="$1" offset="$2"
  local -n text_ref="$3"
  local operator target
  text_ref=''
  # ERE, evaluated unquoted in [[ =~ ]]. The operator group is followed by the
  # target group: `&-`, a quoted word, or a bare word. The tail requires the
  # word to end there, so a literal glued to an expansion (`'a'"${b}"`) or to
  # another redirection does not pass as a literal.
  local -r quoted="'[^']*'|\"[^\"\$\`\\\\]*\""
  local -r literal_re="^0?(<<<|<>|<)[[:blank:]]*(&-|${quoted}|[A-Za-z0-9_./~@%+=:,-]+)([[:space:];|&()]|\$)"
  [[ "${command:offset}" =~ ${literal_re} ]] || return 1
  operator="${BASH_REMATCH[1]}"
  target="${BASH_REMATCH[2]}"
  if [[ "${target}" == [\'\"]* ]]; then
    target="${target:1:${#target}-2}"
  fi
  # A here-string's word is the stdin itself, not a path to open.
  if [[ "${operator}" == '<<<' ]]; then
    text_ref="${target}"
    return 0
  fi
  if [[ "${target}" == '&-' ]]; then
    return 0
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

# @description Cut every outermost `$(...)`, `$((...))`, backtick and process-substitution region
#              (`<(...)`, `>(...)`) out of a token stream, so that the simple command around it
#              reads as if the region were one word, and scan each region's own tokens for wrappers.
#
#              The scanner re-enters code context inside a region, so its tokens (`(`, `)`, the
#              backtick) look like command boundaries to a reader of the simple command that
#              contains it. They are not boundaries of that command: `FOO=$(true) bash` is one
#              simple command, and `bash > "$(mktemp)" <<EOF` still owns its heredoc. The region
#              is a command in its own right, though, and may hold a wrapper of its own, so its
#              tokens go to wrappers::shell_wrapper_payloads on their own, which prints that
#              region's payloads here.
#
#              Regions are found by tokens::region_step, which follows the scanner's rules.
#              A region with no close runs to the end of the stream, as the scanner reads it.
#
#              What the outer stream keeps of a region: the `$` word it hangs off, or a one-byte
#              word standing in for a backtick region that follows whitespace or touches an operator,
#              or for a process substitution, whose `<` or `>` is replaced by it,
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
# shellcheck disable=SC2034 # cut_outer is the caller's variable, written through the nameref
function wrappers::cut_substitutions() {
  local -r command="$1" stream="$2"
  local -n cut_outer="$3"
  local -r heredoc_re='^[0-9]*<<([^<]|$)'
  local offset token kind depth
  local -A region=()
  local outer='' inner='' glue_at=-1 outer_before_token=0 lt_glued=0
  while IFS=$'\t' read -r offset token; do
    if [[ -z "${token}" ]]; then
      outer+="${offset}"$'\t'$'\n'
      continue
    fi
    tokens::region_step "${command}" "${offset}" "${token}" region kind
    depth="${#region[kinds]}"
    case "${kind}" in
      '')
        if ((depth == 0)); then
          if ((offset != glue_at)) || tokens::is_operator "${token}" \
            || [[ "${token}" == '<'* || "${token}" == *'>'* ]]; then
            outer_before_token="${#outer}"
            if [[ "${token}" == '<' || "${token}" == '>' ]]; then
              lt_glued=0
              if ((region[prev_end] == offset)) && ! tokens::is_operator "${region[prev_token]}"; then
                lt_glued=1
              fi
            fi
            outer+="${offset}"$'\t'"${token}"$'\n'
          fi
        else
          inner+="${offset}"$'\t'"${token}"$'\n'
          if [[ "${token}" =~ ${heredoc_re} ]]; then
            outer+="${offset}"$'\t''<HO>'$'\n'
          elif [[ "${token}" == '<HD:'*'>' ]]; then
            outer+="${offset}"$'\t'"${token}"$'\n'
          fi
        fi
        ;;
      'close')
        if ((depth == 0)); then
          wrappers::shell_wrapper_payloads "${command}" "${inner}"
          inner=''
          glue_at="$((offset + 1))"
        else
          inner+="${offset}"$'\t'"${token}"$'\n'
        fi
        ;;
      *)
        if ((depth == 1)); then
          # A backtick that follows whitespace or touches an operator has no word
          # of its own to hang off, so one stands in for it.
          if [[ "${kind}" == 'B' ]] \
            && { ((region[prev_end] != offset)) || tokens::is_operator "${region[prev_token]}"; }; then
            outer+="${offset}"$'\t'$'\001'$'\n'
          elif [[ "${kind}" == 'S' ]]; then
            # The `<` or `>` just before the `(` is the word's first byte, not a redirection. A word
            # it touches (`FOO=<(...)`) already stands for the whole, so only a lone one needs a
            # stand-in.
            outer="${outer:0:outer_before_token}"
            if ((lt_glued == 0)); then
              outer+="$((offset - 1))"$'\t'$'\001'$'\n'
            fi
          fi
        else
          inner+="${offset}"$'\t'"${token}"$'\n'
        fi
        ;;
    esac
  done <<< "${stream}"
  if ((${#region[kinds]} > 0)); then
    wrappers::shell_wrapper_payloads "${command}" "${inner}"
  fi
  cut_outer="${outer}"
}

# @description Print the script `watch` runs for its operands, NUL-terminated. `watch` joins its
#              operands with single spaces and hands the result to `sh -c`, so the first operand and
#              the words after it make up one command line.
# @arg $1 first the first operand, quotes stripped
# @arg $@ operands the operands after it, quotes stripped
# @stdout the joined script, NUL-terminated
function wrappers::watch_payload() {
  local -r first="$1"
  shift
  local script="${first}" operand
  for operand in "$@"; do
    script+=" ${operand}"
  done
  printf '%s\0' "${script}"
}

# @description Find the payloads of local shell wrappers and print each one's raw text,
#              NUL-terminated, with any surrounding quotes stripped.
#
#              A `-c` payload counts only when all of these hold: the wrapper is in command position
#              (so `ssh host bash -c ...` and a bare `echo bash -c ...` are both skipped, since
#              neither runs the payload here); a `-c` precedes it, in the same simple command,
#              within the wrapper's operand budget (see wrappers::wrapper_operand_budget -- this is what
#              keeps `bash deploy.sh -c '...'`, where the `-c` belongs to the script, from being
#              read as a payload; the value of an option, such as the `pipefail` of `-o pipefail`,
#              is no operand, see wrappers::wrapper_option_facts); and the raw slice is a single
#              fully quoted word. That last
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
#              (`2>&1`, `<&3`, `>&file`) and the `|` of `>|` are part of the
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
#              bash applies the LAST redirection of fd 0, so the wrapper's own heredoc is the script
#              only when nothing after it in the simple command takes fd 0 over: `bash <<EOF < /tmp/f`,
#              `bash <<EOF <<< 'x'` and `<<EOF bash <> /tmp/f` read the file or the here-string and the
#              body is never run, while `bash < f <<EOF` still runs it. A later redirection that may
#              be the pipe or a descriptor the text cannot resolve (`<&3`, `< <(...)`) is not shown
#              to displace it, and the body stays a payload. wrappers::stdin_reaches_wrapper holds
#              that decision for every source of the wrapper's stdin.
#
#              A payload piped into the wrapper counts too. The wrapper reads its script from stdin, so the
#              left of the pipe is what it runs -- but only when that side hands the text through unchanged:
#              `cat` with no operand but `-`, still reading its own heredoc and with its stdout on the pipe,
#              passes the body through, and `echo` / `printf` with their stdout on the pipe pass a literal
#              operand (see wrappers::pipe_producer_payload). Only a redirection of fd 1 (`> f`,
#              `>&2`, `&> f`) takes the producer's stdout off the pipe; `2>&1`, `2> /dev/null` and `3> f`
#              do not. A
#              `>&1` moves nothing, while `2>&1 1>&2` is counted as moving stdout. A filter may emit
#              something other than what it was given, so `sed <<EOF | bash` is not read as a payload --
#              denying on text that never reaches the wrapper is a false deny. The wrapper must be the pipe's
#              very NEXT stage, since an intermediate one (`cat <<EOF | tee f | bash`) can change the text on
#              the way. A group, subshell or compound command counts as that next stage when it opens right
#              after the pipe (see below), and as the previous stage when it closes right before it.
#              That next stage may stand on a later line: bash continues a pipeline behind a trailing
#              `|`, so the newlines there are stepped over, and so are the body and terminator line of
#              a heredoc the producer's line opened (`cat <<EOF |`, the body, then `bash`). Inside a
#              group, a stage on the next line behind a pipe that carries nothing the reader can
#              follow (`{ cat |`, newline, `bash; }`) is read as reading the group's stdin.
#              A script operand that names the wrapper's own stdin (`bash /dev/stdin`, see
#              wrappers::names_own_stdin) displaces nothing: it says what `-s` says. `source` and
#              `.` are read as wrappers for that operand alone, and with any other, or none, they
#              run nothing of their stdin.
#              Past the pipe nothing else changes: the payload is handed to the
#              same machinery, so an operand still displaces stdin, a `-c` still claims the payload instead,
#              `-s` still keeps stdin as the script, and the prefix chain is still followed.
#
#              The pipe supplies the wrapper's stdin only when the wrapper's own simple command
#              does not give fd 0 something else. A heredoc (`echo '...' | bash <<EOF`), a literal
#              here-string (which is then the script itself, below), a literal file (`< f`, `<> f`) or a
#              closed stdin (`<&-`) there, before
#              or after the wrapper word, is what bash hands the wrapper, so the piped text is
#              never read and is not a payload. A redirection of any other fd (`3<<EOF`,
#              `> /tmp/log`, `2>&1`) leaves the pipe in place, and so does one that may still be
#              the pipe (see wrappers::redirection_replaces_stdin).
#
#              A pipe into a group (`{ ...; }`), subshell (`( ... )`) or compound command (`if`,
#              `while`, `until`, `for`, `select`, `case`) is that construct's stdin, and every wrapper
#              inside it that is not itself on the right of a pipe reads it, so each claims the payload.
#              That fails closed: `{ cat; bash; }` is read as a payload although `cat` drains the pipe
#              first, since which commands read stdin is not known. The redirections after the closing
#              word (`} < f`, `done <<< x`) are the construct's own and decide, through
#              wrappers::stdin_reaches_wrapper, whether the pipe is read at all; wrappers::group_stdin_kind
#              reads them ahead of the body, because a heredoc body is announced before the group
#              closes. A nested construct redirecting its own stdin hides the payload from the
#              wrappers inside it alone.
#
#              A heredoc written on the construct itself (`{ bash; } <<EOF`, `done <<EOF`) is its
#              stdin the same way, claimed by the same wrappers under the same rules and replacing
#              a pipe into the construct. Its body is announced after the line that holds the
#              closing word, so wrappers::group_stdin_kind also returns the heredoc's ordinal,
#              counting the heredoc operators inside the construct and among its redirections.
#
#              A group, subshell or compound command on the LEFT of a pipe (`{ echo '...'; } | bash`,
#              `( cat <<EOF ) | bash`, `for ...; do echo '...'; done | bash`) hands the wrapper what its
#              commands print. Every command in it that ends outside a pipe of its own, and whose stdout
#              is not redirected, contributes what a producer segment would carry (see
#              wrappers::segment_pipe_carry). That fails closed, as the group's stdin does: `{ echo a;
#              echo 'cmd'; }` yields both lines, joined by a newline, and a heredoc a command passes
#              through (`{ cat <<EOF; } | bash`) is a payload of its own, as is the group's own stdin
#              that a bare `cat` inside it passes through. A redirection of fd 1 after the closer
#              (`} > f | bash`, `} >&2 | bash`) takes the group off the pipe, and wrappers::group_stdin_kind
#              says whether it is on one.
#
#              A literal here-string is a source of the wrapper's stdin like a heredoc or a pipe:
#              `bash <<< 'script'` runs its text, read from the raw command at the target's offset
#              because the scanner masks quoted bytes. Only a literal counts (see
#              wrappers::redirection_replaces_stdin); `bash <<< "${script}"` and `<<< $'...'` are
#              not read. The last redirection of fd 0 wins, so a later `<`, heredoc or here-string
#              displaces it, and it displaces a pipe or a heredoc written before it. A later one that
#              may be the same descriptor (`<&0`, `< /dev/stdin`) displaces nothing. On a group
#              (`{ bash; } <<< 'script'`) it is that group's stdin, claimed by the wrappers inside
#              like the group's heredoc. A `cat` that reads one, alone or in a group on the left
#              of a pipe, hands it to the next stage.
#
#              `watch` is a payload source too: it joins its operands with spaces and runs the result
#              through `sh -c`, so `watch 'pkill --full X'` runs the kill. The first operand after
#              watch's options (and `--`) is read, quotes stripped from a fully quoted word and
#              backslashes dropped from an escaped one (`watch pkill\ --full\ X`), and the words after it join it, as
#              wrappers::watch_payload does; a plain unquoted operand yields the same verdict through
#              the prefix chain as through the script. With `-x` or `--exec` the operand is a program
#              name, not a script, and nothing is read; `watch $'...'` is not read either.
#
#              Still not covered: content that is not on the command line at all
#              (`printf '%s' "${script}" | bash`, `curl ... | bash`), a here-string that is not a
#              literal, and a subshell closed inside a command substitution, where the region ends
#              at its first `)`.
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
  if [[ "${command}" == *\$\(* || "${command}" == *'`'* ||
    "${command}" == *'<('* || "${command}" == *'>('* ]]; then
    wrappers::cut_substitutions "${command}" "${tokens}" tokens
  fi
  # A group can only own a heredoc or a here-string when the command has a `<<` operator at all.
  local has_heredoc_op=0
  [[ "${tokens}" == *'<<'* || "${tokens}" == *'<HO>'* ]] && has_heredoc_op=1
  # A group can only be a pipe's producer when the command has a pipe at all.
  local has_pipe_op=0
  [[ "${tokens}" == *$'\t|\n'* ]] && has_pipe_op=1
  local at_cmd=1 in_wrapper=0 saw_c=0 saw_s=0 saw_s_operand=0 operands=0
  # `wrapper_name` is the wrapper being read and `wrapper_kind` its family: `shell`, `user`, or
  # `source` for the builtins of LOCAL_SOURCE_BUILTINS.
  # `option_word` is the word under test as an option: the whole token, since the basename
  # reduction would cut `-s/bin/sh` down to an operand. `option_values` counts the words still to
  # come that are values of the wrapper's options (see wrappers::wrapper_option_facts).
  local wrapper_name='' wrapper_kind='' option_word option_values=0 option_c option_s
  local offset token word next_at_cmd is_cmd_word raw budget pending_source
  # shellcheck disable=SC2034 # written through tokens::prefix_chain_step's namerefs, which shellcheck cannot follow
  local chain='' chain_skip=0 chain_operands=0
  local heredoc_seq=0 body_seq=0 pending='' leading_pending='' wanted=' ' expect_delim=0 len fd
  local expect_redir_target=0
  # The pipeline carry. `seg_*` is the simple command being read right now; `pipe_*` is what an
  # ended segment left behind for the next one, which only the very next command word may claim (or
  # a group opening right after the pipe, which hands it to `grp_*`). `seg_piped` says the segment
  # sits on the right of a pipe, and so does not read the enclosing group's stdin. `pending_text` is
  # the wrapper's claimed literal payload, held until its simple command ends the same way a heredoc
  # ordinal is. `seg_stdin_kind` is where the segment's fd 0 comes from after its last fd 0
  # redirection (see wrappers::stdin_reaches_wrapper), and `pending_piped` says that `pending` holds
  # the pipe's heredoc rather than one the wrapper wrote itself. At the flush each claimed payload
  # is kept only if its own source is what fd 0 ends up reading: bash applies the last redirection,
  # so any other source is never read. `seg_here_text` is the text of the segment's literal
  # here-string and `seg_here_set` says it may still be fd 0, which makes it the wrapper's own payload.
  local seg_cmd='' seg_heredoc='' seg_stdout_moved=0 seg_stdin_kind='' seg_piped=0
  local seg_here_text='' seg_here_set=0 redirect_text=''
  local stdout_before=0 stdout_redir=0 dup_target=0
  # Groups and compound commands. `grp_*` is what the stdin of the innermost
  # one holds (the pipe it sits on the right of, or a heredoc written on it, as
  # a heredoc ordinal or a literal), which every wrapper inside reads unless a
  # pipe of its own comes first. `frame_*` hold the enclosing one's values for each open group, and
  # `frame_closer` the word that ends it. A group on the left of a pipe is a producer
  # (`frame_producer`): `frame_acc_*` collect what its commands print, and `produced_*` hand that to the
  # pipe once the closing word has been read. `frame_moved` says the group's stdout is redirected, so
  # nothing inside it reaches a producer around it.
  local grp_heredoc='' grp_text='' grp_text_set=0 group_closer='' group_stream='' group_kind='' group_ordinal=''
  local -a frame_closer=() frame_heredoc=() frame_text=() frame_text_set=()
  local -a frame_moved=() frame_producer=() frame_acc_heredoc=() frame_acc_text=() frame_acc_text_set=()
  local produced_heredoc='' produced_text='' produced_text_set=0 produced_set=0
  local closing_heredoc='' closing_text='' closing_text_set=0 closing_producer=0
  local -a hd_body=()
  local group_moved=0 group_text='' group_here_set=0
  local acc_idx acc_heredoc acc_text acc_text_set acc_word acc_through group_piped=0 producers_open=0
  local -a seg_words=()
  # `watch` tracking: it is the prefix whose operands are read as a script (see the capture below).
  local watch_active=0 watch_exec=0 watch_dd=0 watch_first='' watch_first_set=0
  local -a watch_rest=()
  local pipe_heredoc='' pipe_text='' pipe_text_set=0 last_pipe_offset=-1
  # `pipe_open` says no word of the next stage has been read since a pipe: bash continues the
  # pipeline on the next line there, so newlines, and the body and terminator line of a heredoc
  # the lines before it opened, are stepped over with the carry intact. `body_end` is the offset
  # where that body's terminator line starts.
  local pipe_open=0 body_end=-1
  local pending_text='' pending_text_set=0 pending_piped=0
  # A `<<` heredoc operator may carry a leading fd (`0<<`, `3<<-`), which is
  # ordinary redirection syntax; only fd 0 (empty or explicit `0`) feeds the
  # wrapper's stdin. `<<<` (and an fd-prefixed `0<<<`) is a here-string, not a
  # heredoc, so the next byte after `<<` must not itself be `<`. ERE,
  # evaluated unquoted in [[ =~ ]].
  local -r heredoc_re='^([0-9]*)<<([^<]|$)' bare_heredoc_re='^[0-9]*<<-?$'
  # Any other redirection: an optional fd, then a run of `<` and `>` (`>`, `>>`,
  # `<>`), or `&>` and `&>>`. The scanner emits the operator on its own, so the
  # next token is the target and is not an operand either. A `<<` heredoc operator also matches
  # and must stay ABOVE it: that branch `continue`s, so it never reaches here.
  # `stdin_redir_re` picks out the ones that redirect fd 0: an input operator
  # with no fd, or any operator with an explicit `0`.
  local -r redir_re='^([0-9]*[<>]+|&>>?)$'
  local -r stdin_redir_re='^(0?<|0>)'
  # `redir_single_re` picks out the bare `<` and `>` operators, which an `&` or
  # a `|` extends to `<&`, `>&` or `>|`; `glue_at` is the offset just past one,
  # where that `&` or `|` has to sit.
  local -r redir_single_re='^[0-9]*[<>]$'
  # `stdout_redir_re` picks out the ones that redirect fd 1: an output operator
  # with no fd or with an explicit `1`, `1<>`, or `&>` and `&>>`.
  local -r stdout_redir_re='^(&>|1?>|1<>)'
  local glue_at=-1
  # The rest of this loop stays inline on purpose: the blocks share most of
  # the locals above, and a helper with that many namerefs is harder to read
  # than the block.
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    word="${token##*/}"

    if ((pipe_open == 1)); then
      case "${token}" in
        '<NL>')
          # A pipe that carries nothing the reader can follow (`cat |`, `tee f |`, a filter) may
          # still hand on the stdin of the group it sits in. The stage on the next line is read as
          # reading that stdin, which fails closed.
          if [[ -z "${pipe_heredoc}" ]] && ((pipe_text_set == 0)); then
            seg_piped=0
          fi
          continue
          ;;
        '<HD:'*'>') ;;
        *)
          # Every token inside the body's span is body text, the `$` word of a substitution
          # included, and the terminator line is one token of filler at the span's end.
          if ((offset < body_end)) || { ((offset == body_end)) && [[ "${token}" != *[!$'\001']* ]]; }; then
            continue
          fi
          pipe_open=0
          ;;
      esac
    fi

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
        seg_stdin_kind='heredoc'
        seg_here_text=''
        seg_here_set=0
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
      len="${token#<HD:}"
      len="${len%>}"
      # Kept for a wrapper that claims it later: a group's producer reads a body
      # that sits inside the group, before the wrapper after the pipe is seen.
      hd_body[body_seq]="${command:offset:len}"
      body_end="$((offset + len))"
      if [[ "${wanted}" == *" ${body_seq} "* ]]; then
        printf '%s\0' "${hd_body[body_seq]}"
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
        dup_target="${stdout_redir}"
        [[ "${token}" == '&' ]] || dup_target=0
        continue
      fi
      # `>&1` duplicates fd 1 onto itself, which moves nothing.
      if ((dup_target == 1)); then
        case "${command:offset:${#token}}" in
          '1' | "'1'" | '"1"') seg_stdout_moved="${stdout_before}" ;;
          *) ;;
        esac
      fi
      dup_target=0
      # Any other operator here is no target. It ends the simple command and
      # must reach the flush below like any other.
      tokens::is_operator "${token}" || continue
    fi
    if [[ "${token}" =~ ${redir_re} ]]; then
      expect_redir_target=1
      glue_at=-1
      if [[ "${token}" =~ ${redir_single_re} ]]; then
        glue_at="$((offset + ${#token}))"
      fi
      # bash applies the last redirection of fd 0, so each one decides afresh:
      # a later one that may be the pipe again (`< /tmp/f <&3`) withdraws what
      # an earlier one established, and one that provably is not the pipe
      # displaces what an earlier one established, a heredoc included.
      if [[ "${token}" =~ ${stdin_redir_re} ]]; then
        wrappers::redirection_stdin_kind "${command}" "${offset}" "${token}" seg_stdin_kind redirect_text
        # A later redirection that may be the same descriptor (`<&0`, `< /dev/stdin`) leaves the
        # here-string in place; only one that provably replaces fd 0 drops it.
        case "${seg_stdin_kind}" in
          'text')
            seg_here_text="${redirect_text}"
            seg_here_set=1
            ;;
          'maybe-pipe') ;;
          *)
            seg_here_text=''
            seg_here_set=0
            ;;
        esac
      fi
      # A producer whose stdout is redirected sends the wrapper nothing: in
      # `cat > f <<EOF | bash` the body lands in the file and bash reads an empty
      # pipe. Only a redirection of fd 1 does that; `2>&1`, `3> f` and `< f` leave
      # the pipe where it was.
      stdout_redir=0
      if [[ "${token}" =~ ${stdout_redir_re} ]]; then
        stdout_before="${seg_stdout_moved}"
        seg_stdout_moved=1
        stdout_redir=1
      fi
      dup_target=0
      continue
    fi

    if ((in_wrapper == 1)); then
      option_word="${word}"
      if [[ "${token}" == [-+]* ]]; then
        option_word="${token}"
      fi
      # A word spelled like an option is never an option's value: `bash -o -c '...'` and
      # `su -s -c '...'` keep their `-c`, which fails closed.
      if ((option_values > 0)) && [[ "${option_word}" == -* ]]; then
        option_values=0
      fi
      if tokens::is_operator "${token}"; then
        # A redirection of the wrapper's own stdin replaces the pipe, so what
        # the pipe carried is never read; and a later one replaces the wrapper's
        # own heredoc the same way.
        pending_source='heredoc'
        ((pending_piped == 1)) && pending_source='pipe'
        # `source` and `.` with no operand naming their stdin run none of it.
        if [[ "${wrapper_kind}" == 'source' ]] && ((saw_s == 0)); then
          pending=''
          pending_text_set=0
        elif ((seg_here_set == 1)); then
          printf '%s\0' "${seg_here_text}"
        fi
        if [[ -n "${pending}" ]] && wrappers::stdin_reaches_wrapper "${seg_stdin_kind}" "${pending_source}"; then
          wrappers::claim_heredocs wanted hd_body "${body_seq}" "${pending}"
        fi
        if ((pending_text_set == 1)) && wrappers::stdin_reaches_wrapper "${seg_stdin_kind}" 'pipe'; then
          printf '%s\0' "${pending_text}"
        fi
        in_wrapper=0
        saw_c=0
        saw_s=0
        saw_s_operand=0
        pending=''
        pending_text=''
        pending_text_set=0
      elif ((option_values > 0)); then
        # The value of an option (`-o pipefail`, `--rcfile f`, `su -s /bin/sh`): no operand, and
        # not the `-c` string either. A fully quoted word there behind a `-c` is read as a
        # payload all the same (`bash -co '...'`, where the option's name is missing): an option
        # name is not written quoted, so this only fails closed.
        option_values="$((option_values - 1))"
        raw="${command:offset:${#token}}"
        if ((saw_c == 1)) && [[ ("${raw}" == \"*\" || "${raw}" == \'*\') && "${#raw}" -ge 2 ]]; then
          printf '%s\0' "${raw:1:${#raw}-2}"
        fi
      elif ((saw_c == 1)) && [[ "${option_word}" != -* ]] \
        && [[ "${wrapper_kind}" != 'shell' || "${option_word}" != +* ]]; then
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
      elif [[ "${wrapper_kind}" != 'source' || "${option_word}" == '--' ]] \
        && [[ "${option_word}" == -* || ("${wrapper_kind}" == 'shell' && "${option_word}" == +*) ]]; then
        # An option, which a shell also spells with a `+`. A short cluster counts for `-c`, so
        # `bash -lc '...'` does as well as `bash -c '...'`. `-s` in one says stdin IS the script,
        # so the operands after it are that script's positional parameters ($1...) rather than a
        # script to run in the body's place.
        # Once `-s` has taken an operand the wrapper's own option list is over:
        # in `bash -s arg -c '...'` the `-c` and the string after it are $2 and
        # $3 of the body, and nothing here runs that string.
        if ((saw_s_operand == 0)); then
          IFS=':' read -r option_values option_c option_s \
            <<< "$(wrappers::wrapper_option_facts "${option_word}" "${wrapper_name}")"
          ((option_c == 0)) || saw_c=1
          ((option_s == 0)) || saw_s=1
        fi
      else
        # An operand before any `-c`. Spend one from the budget, and once it is
        # gone the wrapper no longer owns the options that follow -- unless
        # `-s` already said stdin is the script, in which case no operand ever
        # displaces the body.
        # Only a shell's `-s` ends its option list at the first operand: `su -s /bin/sh root -c
        # '...'` still reads its `-c`.
        if ((saw_s == 1)) && [[ "${wrapper_kind}" == 'shell' ]]; then
          saw_s_operand=1
        fi
        # A script operand that names the wrapper's own stdin (`bash /dev/stdin`) says what `-s`
        # says: stdin is the script, and the words after it are its parameters. For `source` and
        # `.` it is the one operand that makes them a wrapper at all.
        raw="${command:offset:${#token}}"
        if [[ ("${raw}" == \"*\" || "${raw}" == \'*\') && "${#raw}" -ge 2 ]]; then
          raw="${raw:1:${#raw}-2}"
        fi
        if ((saw_s == 0)) && [[ "${wrapper_kind}" != 'user' ]] && wrappers::names_own_stdin "${raw}"; then
          saw_s=1
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
    # on the left of a pipe. Only a word that the chain step has already left
    # out of command position is kept. A word still in it is none of what the
    # producer prints: the command itself, a prefix word with its options, a
    # `VAR=value` assignment, `timeout`'s duration. Nor does it print the value
    # of a prefix's option (the `root` of `sudo -u root echo ...`), which is out
    # of command position but still the prefix's: `chain_skip` is still set
    # from the option when its value arrives here.
    if ((at_cmd == 0 && chain_skip == 0)) && ! tokens::is_operator "${token}" \
      && ! tokens::is_keyword "${token}"; then
      raw="${command:offset:${#token}}"
      if [[ ("${raw}" == \"*\" || "${raw}" == \'*\') && "${#raw}" -ge 2 ]]; then
        seg_words+=("${raw:1:${#raw}-2}")
      else
        seg_words+=("${raw}")
      fi
    fi

    # Inside a group that is a pipe's producer, every command that ends here prints into that pipe, so
    # what it carries joins the group's. The `|` that makes a pipe is excluded, since the segment before
    # it prints into that pipe instead; the first `|` of a `||` is not one.
    if ((producers_open > 0)) && tokens::is_operator "${token}" \
      && { [[ "${token}" != '|' ]] || [[ "${command:offset+1:1}" == '|' ]]; }; then
      wrappers::segment_pipe_carry acc_heredoc acc_text acc_text_set \
        "${seg_cmd}" "${seg_heredoc}" "${seg_stdout_moved}" "${seg_stdin_kind}" \
        "${seg_here_text}" "${seg_here_set}" "${seg_words[@]}"
      # A bare `cat` passes through the stdin of the group it sits in, when no pipe or redirection of
      # its own comes first.
      if [[ "${seg_cmd}" == 'cat' ]] && ((seg_piped == 0 && seg_stdout_moved == 0)) && [[ -z "${seg_stdin_kind}" ]] \
        && [[ -z "${acc_heredoc}" ]] && ((acc_text_set == 0)); then
        acc_through=1
        for acc_word in "${seg_words[@]}"; do
          [[ "${acc_word}" == '-' ]] || acc_through=0
        done
        if ((acc_through == 1)); then
          acc_heredoc="${grp_heredoc}"
          acc_text="${grp_text}"
          acc_text_set="${grp_text_set}"
        fi
      fi
      if [[ -n "${acc_heredoc}" ]] || ((acc_text_set == 1)); then
        # Walk out to the producer; a group on the way whose own stdout is redirected prints nothing into it.
        for ((acc_idx = ${#frame_producer[@]} - 1; acc_idx >= 0; acc_idx--)); do
          [[ "${frame_producer[acc_idx]}" == 1 ]] && break
          if [[ "${frame_moved[acc_idx]}" == 1 ]]; then
            acc_idx=-1
            break
          fi
        done
        if ((acc_idx >= 0)); then
          if [[ -n "${acc_heredoc}" ]]; then
            frame_acc_heredoc[acc_idx]+="${frame_acc_heredoc[acc_idx]:+ }${acc_heredoc}"
          fi
          if ((acc_text_set == 1 && frame_acc_text_set[acc_idx] == 1)); then
            frame_acc_text[acc_idx]+=$'\n'"${acc_text}"
          elif ((acc_text_set == 1)); then
            frame_acc_text[acc_idx]="${acc_text}"
            frame_acc_text_set[acc_idx]=1
          fi
        fi
      fi
    fi

    case "${token}" in
      '{' | '(' | 'if' | 'while' | 'until' | 'for' | 'select' | 'case')
        group_closer="$(wrappers::group_closer "${token}" "${at_cmd}")"
        if [[ -n "${group_closer}" ]] \
          && { ((${#frame_closer[@]} > 0)) || ((seg_piped == 1)) || ((has_heredoc_op == 1)) \
            || ((has_pipe_op == 1)); }; then
          group_piped=0
          group_moved=0
          frame_closer+=("${group_closer}")
          frame_heredoc+=("${grp_heredoc}")
          frame_text+=("${grp_text}")
          frame_text_set+=("${grp_text_set}")
          # A pipe into the group is its stdin, and so is a heredoc written on
          # it (below); without either it keeps the enclosing group's. A frame
          # opens for every group when the command has a heredoc operator or a
          # pipe, since the group may own a heredoc or produce for the pipe.
          if ((seg_piped == 1)); then
            grp_heredoc="${pipe_heredoc}"
            grp_text="${pipe_text}"
            grp_text_set="${pipe_text_set}"
          fi
          wrappers::pipe_carry_clear pipe_heredoc pipe_text pipe_text_set
          seg_piped=0
          if [[ -n "${grp_heredoc}" ]] || ((grp_text_set == 1)) || ((has_heredoc_op == 1)) || ((has_pipe_op == 1)); then
            group_stream="${tokens#*"${offset}"$'\t'"${token}"$'\n'}"
            [[ "${group_stream}" == "${tokens}" ]] && group_stream=''
            group_kind="$(wrappers::group_stdin_kind "${command}" "${group_stream}" "${group_closer}" "${heredoc_seq}")"
            group_ordinal="${group_kind#*:}"
            group_kind="${group_kind%%:*}"
            group_piped="${group_ordinal#*:}"
            group_ordinal="${group_ordinal%%:*}"
            group_moved="${group_piped#*:}"
            group_piped="${group_piped%%:*}"
            group_text="${group_moved#*:}"
            group_here_set="${group_text%%:*}"
            group_text="${group_text#*:}"
            group_moved="${group_moved%%:*}"
            if [[ "${group_kind}" == 'heredoc' ]]; then
              # The group's own heredoc is its stdin, whatever it was fed before.
              grp_heredoc="${group_ordinal}"
              grp_text=''
              grp_text_set=0
            elif ((group_here_set == 1)); then
              # So is its own literal here-string. A redirection after it that may still be the same
              # descriptor leaves the pipe in place beside it.
              if [[ "${group_kind}" == 'text' ]]; then
                grp_heredoc=''
                grp_text="${group_text}"
              elif ((grp_text_set == 1)); then
                grp_text+=$'\n'"${group_text}"
              else
                grp_text="${group_text}"
              fi
              grp_text_set=1
            elif ! wrappers::stdin_reaches_wrapper "${group_kind}" 'pipe'; then
              wrappers::pipe_carry_clear grp_heredoc grp_text grp_text_set
            fi
          fi
          frame_producer+=("${group_piped}")
          frame_moved+=("${group_moved}")
          frame_acc_heredoc+=('')
          frame_acc_text+=('')
          frame_acc_text_set+=(0)
          producers_open="$((producers_open + group_piped))"
        fi
        ;;
      '}' | ')' | 'fi' | 'done' | 'esac')
        if ((${#frame_closer[@]} > 0)) && [[ "${token}" == "${frame_closer[-1]}" ]] \
          && { [[ "${token}" == ')' ]] || ((at_cmd == 1)); }; then
          grp_heredoc="${frame_heredoc[-1]}"
          grp_text="${frame_text[-1]}"
          grp_text_set="${frame_text_set[-1]}"
          if [[ "${frame_producer[-1]}" == 1 ]]; then
            closing_heredoc="${frame_acc_heredoc[-1]}"
            closing_text="${frame_acc_text[-1]}"
            closing_text_set="${frame_acc_text_set[-1]}"
            closing_producer=1
            producers_open="$((producers_open - 1))"
          fi
          unset 'frame_closer[-1]' 'frame_heredoc[-1]' 'frame_text[-1]' 'frame_text_set[-1]'
          unset 'frame_moved[-1]' 'frame_producer[-1]'
          unset 'frame_acc_heredoc[-1]' 'frame_acc_text[-1]' 'frame_acc_text_set[-1]'
        fi
        ;;
      *) ;;
    esac

    if tokens::is_operator "${token}"; then
      if ((watch_first_set == 1)); then
        wrappers::watch_payload "${watch_first}" "${watch_rest[@]}"
      fi
      watch_active=0
      watch_first_set=0
      watch_rest=()
      if [[ "${token}" == '|' ]] && ((last_pipe_offset != offset - 1)); then
        wrappers::segment_pipe_carry pipe_heredoc pipe_text pipe_text_set \
          "${seg_cmd}" "${seg_heredoc}" "${seg_stdout_moved}" "${seg_stdin_kind}" \
          "${seg_here_text}" "${seg_here_set}" "${seg_words[@]}"
        # A group or compound command that just closed hands the pipe what its commands printed.
        if ((produced_set == 1)); then
          pipe_heredoc="${produced_heredoc}"
          pipe_text="${produced_text}"
          pipe_text_set="${produced_text_set}"
          produced_set=0
        fi
        last_pipe_offset="${offset}"
        seg_piped=1
        pipe_open=1
        body_end=-1
      elif [[ "${token}" == '|' ]]; then
        # The second `|` of a `||`, which is a conditional list and not a pipe:
        # nothing crosses it, so drop what the first `|` armed.
        wrappers::pipe_carry_clear pipe_heredoc pipe_text pipe_text_set
        last_pipe_offset="${offset}"
        seg_piped=0
        produced_set=0
      elif [[ "${token}" == '&' ]] && ((last_pipe_offset == offset - 1)); then
        # `|&` extends the pipe it follows, so the carry it armed stands.
        last_pipe_offset="${offset}"
        pipe_open=1
      else
        wrappers::pipe_carry_clear pipe_heredoc pipe_text pipe_text_set
        seg_piped=0
        produced_set=0
      fi
      seg_cmd=''
      seg_heredoc=''
      seg_stdout_moved=0
      seg_stdin_kind=''
      seg_here_text=''
      seg_here_set=0
      seg_words=()
      leading_pending=''
    elif tokens::is_keyword "${token}"; then
      leading_pending=''
    fi
    # The operands after watch's first one. They are kept here and not in `seg_words`, which leaves out
    # a word still in command position (`watch sudo '...'`).
    if ((watch_first_set == 1)) && ! tokens::is_operator "${token}"; then
      raw="${command:offset:${#token}}"
      if [[ ("${raw}" == \"*\" || "${raw}" == \'*\') && "${#raw}" -ge 2 ]]; then
        raw="${raw:1:${#raw}-2}"
      fi
      watch_rest+=("${raw}")
    fi
    # `watch` runs its operands through `sh -c`, so they are a script: a quoted word, or one with
    # backslash escapes, is hidden from the prefix chain, and so is the quoted word after a prefix
    # operand (`watch sudo '...'`). `-x`/`--exec` runs the operand as a program name instead, and
    # nothing is read.
    if ((watch_active == 1 && at_cmd == 1 && chain_skip == 0)) && ! tokens::is_operator "${token}" \
      && ! tokens::is_keyword "${token}"; then
      if ((watch_dd == 0)) && [[ "${token}" == '--' ]]; then
        watch_dd=1
      elif ((watch_dd == 0)) && [[ "${word}" == -* ]]; then
        if [[ "${word}" == '--exec' || ("${word}" == -*x* && "${word}" != --*) ]]; then
          watch_exec=1
        fi
      elif ! tokens::is_assignment_word "${token}"; then
        watch_active=0
        raw="${command:offset:${#token}}"
        if ((watch_exec == 0)); then
          watch_first="${raw}"
          if [[ ("${raw}" == \"*\" || "${raw}" == \'*\') && "${#raw}" -ge 2 ]]; then
            watch_first="${raw:1:${#raw}-2}"
          elif [[ "${raw}" == *\\* ]]; then
            watch_first="${raw//\\/}"
          fi
          watch_first_set=1
        fi
      fi
    fi
    if tokens::prefix_chain_step "${token}" "${word}" "${at_cmd}" chain chain_skip chain_operands; then
      next_at_cmd=1
    else
      next_at_cmd=0
    fi
    if ((at_cmd == 1)) && [[ "${word}" == 'watch' && "${chain}" == 'watch' ]]; then
      watch_active=1
      watch_exec=0
      watch_dd=0
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
      option_values=0
      wrapper_name="${word}"
      wrapper_kind='shell'
      ((budget == 0)) || wrapper_kind='user'
      if [[ "${word}" == 'source' || "${word}" == '.' ]]; then
        wrapper_kind='source'
      fi
      pending="${leading_pending}"
      leading_pending=''
      pending_text=''
      pending_text_set=0
      pending_piped=0
      # A heredoc written on the wrapper's own simple command is the one bash
      # applies; the pipe only supplies stdin when nothing else did. Whether
      # anything else does is not known until the simple command ends, so the
      # pipe's payload is claimed here and dropped at the flush unless
      # wrappers::stdin_reaches_wrapper says it still reaches the wrapper.
      if [[ -z "${pending}" && -n "${pipe_heredoc}" ]]; then
        pending="${pipe_heredoc}"
        pending_piped=1
      fi
      if ((pipe_text_set == 1)); then
        pending_text="${pipe_text}"
        pending_text_set=1
      fi
      # Inside a group the wrapper reads the group's stdin, unless a pipe of its
      # own comes first.
      if ((seg_piped == 0)); then
        if [[ -z "${pending}" && -n "${grp_heredoc}" ]]; then
          pending="${grp_heredoc}"
          pending_piped=1
        fi
        if ((grp_text_set == 1)); then
          pending_text="${grp_text}"
          pending_text_set=1
        fi
      fi
      wrappers::pipe_carry_clear pipe_heredoc pipe_text pipe_text_set
    elif ((is_cmd_word == 1)); then
      # A command word that is not a local wrapper: whatever the pipe carried is
      # this command's input, and nothing here runs it as a script.
      wrappers::pipe_carry_clear pipe_heredoc pipe_text pipe_text_set
    fi
    # Set here, after the operator branch above has run for the closing word itself, which would
    # otherwise discard it.
    if ((closing_producer == 1)); then
      produced_heredoc="${closing_heredoc}"
      produced_text="${closing_text}"
      produced_text_set="${closing_text_set}"
      produced_set=1
      closing_producer=0
    fi
    at_cmd="${next_at_cmd}"
  done <<< "${tokens}"

  # A wrapper whose simple command runs to the end of the input (`echo 'x' |
  # bash`) meets no operator to flush on. A heredoc body that follows it is
  # printed when its marker goes by; one that was announced already (a body
  # inside a group that produces for the wrapper) is claimed here.
  pending_source='heredoc'
  ((pending_piped == 1)) && pending_source='pipe'
  # `source` and `.` with no operand naming their stdin run none of it.
  if ((in_wrapper == 1)) && [[ "${wrapper_kind}" == 'source' ]] && ((saw_s == 0)); then
    pending=''
    pending_text_set=0
  elif ((in_wrapper == 1 && seg_here_set == 1)); then
    printf '%s\0' "${seg_here_text}"
  fi
  if [[ -n "${pending}" ]] && wrappers::stdin_reaches_wrapper "${seg_stdin_kind}" "${pending_source}"; then
    wrappers::claim_heredocs wanted hd_body "${body_seq}" "${pending}"
  fi
  if ((pending_text_set == 1)) && wrappers::stdin_reaches_wrapper "${seg_stdin_kind}" 'pipe'; then
    printf '%s\0' "${pending_text}"
  fi
  if ((watch_first_set == 1)); then
    wrappers::watch_payload "${watch_first}" "${watch_rest[@]}"
  fi
}
