# shellcheck shell=bash
#
# Whether a pgrep result is consumed, captured, or fed to a kill, sourced by
# hooks/pgrep-pkill-guard-body.sh whenever the entry script loads the body --
# in human mode, or once the prefilter has let a payload through. Never
# executed: no shebang, no exec bit, and it must not set `set -Eeuo pipefail`,
# `IFS`, or the ERR trap -- the entry script owns them all, and a sourced file
# that sets them reconfigures its caller. Never add `shopt -s inherit_errexit`
# (invariant 2). Long options only where the BSD tool has them: this runs on
# BSD userland too (invariant 1).

# xargs options that take their value as a SEPARATE word, so that word is data
# rather than the command xargs will run. Only options whose argument is
# mandatory belong here. GNU spells `-e`, `-i` and `-l` with an OPTIONAL
# argument, which the shell can only attach (`-i%`), never separate --
# so `xargs -i kill {}` runs kill, and listing them would swallow the very
# command word tokens::prefix_chain_step is looking for. tokens::prefix_value_option
# reads them inside a cluster of short flags for the same reason. Over-consuming hides
# a kill; under-consuming only costs a warn, so the doubtful cases stay out.
# `-J` is BSD/macOS-only and has no GNU meaning, so it is safe to carry here.
readonly -a XARGS_VALUE_OPTIONS=(
  '-a' '--arg-file' '-d' '--delimiter' '-E' '-I' '-J' '-L' '-n' '--max-args'
  '-P' '--max-procs' '-s' '--max-chars' '--process-slot-var'
)

# @description True when a token is an xargs option that consumes the following word as its value.
#              Matches the exact option only: an attached spelling (`-n1`, `--max-args=1`) carries
#              its own value and must not also eat the next word.
# @arg $1 token the token to test
# @exitcode 0 the token is such an option
# @exitcode 1 it is not
function consumption::is_xargs_value_option() {
  local -r token="$1"
  local option
  for option in "${XARGS_VALUE_OPTIONS[@]}"; do
    [[ "${token}" == "${option}" ]] && return 0
  done
  return 1
}

# @description Find the innermost group, subshell, substitution or compound command around a
#              token: `{ ...; }`, `( ... )`, `$( ... )` and its kin, a backtick pair,
#              `if ... fi`, `case ... esac`, and a `while`, `until`, `for` or `select` loop up
#              to its `done`. The stream is walked from its start, tracking command position:
#              a keyword or a brace that is an argument word (`echo fi`, `echo then if`, `{}`,
#              `f{,.bak}`) opens and closes nothing. A `)` directly inside a `case` is a
#              pattern's and closes nothing, and neither does a closing word that the innermost
#              open construct does not end with. The `{` of `function f {` is not read as a
#              group's.
# @arg $1 tokens_var name of the caller's token array
# @arg $2 openers_var name of the caller's array mapping the index of each token that closes a
#         region to the index of the token that opened it
# @arg $3 index index of the token to look around; one that opens or closes a construct is
#         outside it
# @arg $4 open name of the caller's variable that receives the index of the token that opens
#         the construct. Never pass a variable that shares a name with one of this function's
#         locals, here or as `close`.
# @arg $5 close name of the caller's variable that receives the index of the token that closes it
# @exitcode 0 a construct holds the token and closes after it
# @exitcode 1 none does
# shellcheck disable=SC2034 # open_ref and close_ref are the caller's variables, written through the namerefs
function consumption::construct_bounds() {
  local -n toks="$1"
  local -r tokens_var="$1" openers_var="$2" index="$3"
  local -n open_ref="$4" close_ref="$5"
  # shellcheck disable=SC2034 # written through tokens::redirection_step's nameref, which shellcheck cannot follow
  local idx token at_cmd=1 redir='' top closes pushed depth_at=-1 before=''
  # Index-aligned, innermost last: starts[i] is the index of the token that opened a construct
  # and ends[i] the word that closes it.
  local -a starts=() ends=()
  for ((idx = 0; idx < ${#toks[@]}; idx++)); do
    token="${toks[idx]}"
    if ((idx == index)); then
      ((${#ends[@]} > 0)) || return 1
      depth_at="${#ends[@]}"
    fi
    if tokens::redirection_step "${token}" redir; then
      continue
    fi
    top=''
    ((${#ends[@]} > 0)) && top="${ends[-1]}"
    closes=0
    pushed=''
    case "${token}" in
      '(') pushed=')' ;;
      '{') ((at_cmd == 1)) && pushed='}' ;;
      'if') ((at_cmd == 1)) && pushed='fi' ;;
      'case') ((at_cmd == 1)) && pushed='esac' ;;
      'while' | 'until' | 'for' | 'select') ((at_cmd == 1)) && pushed='done' ;;
      '`')
        if [[ "${top}" == '`' ]]; then
          closes=1
        else
          pushed='`'
        fi
        ;;
      ')') [[ "${top}" == ')' ]] && closes=1 ;;
      '}') [[ "${top}" == '}' ]] && ((at_cmd == 1)) && closes=1 ;;
      'fi' | 'esac' | 'done')
        # bash also reads a closing keyword directly behind another one (`fi done`).
        if [[ "${top}" == "${token}" ]] \
          && { ((at_cmd == 1)) || [[ "${before}" == 'fi' || "${before}" == 'esac' || "${before}" == 'done' ]]; }; then
          closes=1
        fi
        ;;
    esac
    if ((closes == 1)); then
      if ((idx > index && ${#ends[@]} == depth_at)); then
        open_ref="${starts[-1]}"
        close_ref="${idx}"
        return 0
      fi
      unset 'starts[-1]' 'ends[-1]'
      # The token asked about closes this construct, and so sits in the one around it.
      if ((idx == index)); then
        ((${#ends[@]} > 0)) || return 1
        depth_at="${#ends[@]}"
      fi
    elif [[ -n "${pushed}" ]]; then
      starts+=("${idx}")
      ends+=("${pushed}")
    fi
    if tokens::is_word_region_close "${tokens_var}" "${openers_var}" "${idx}"; then
      at_cmd=0
    elif [[ "${token}" == '{' || "${token}" == '}' ]] && ((at_cmd == 0)); then
      # The braces of `{}` and of a brace expansion (`f{,.bak}`) are tokens of their own, and
      # words of the command they stand in.
      at_cmd=0
    elif tokens::is_operator "${token}"; then
      at_cmd=1
    elif ((at_cmd == 1)) && { tokens::is_keyword "${token}" || [[ "${token}" == 'coproc' ]]; }; then
      at_cmd=1
    elif [[ "${token}" == 'do' ]] && ((idx >= 2)) \
      && [[ "${toks[idx - 2]}" == 'for' || "${toks[idx - 2]}" == 'select' ]]; then
      # `for x do`: bash reads the keyword behind the loop variable.
      at_cmd=1
    else
      at_cmd=0
    fi
    before="${token}"
  done
  return 1
}

# @description True when a later stage of the invocation's pipeline does what the caller asks
#              about. Asked about `kill`, this is the forward form of consumption::feeds_a_kill: the
#              invocation's output is piped into a `kill`. Asked about `count`, it is the pipeline
#              test of consumption::result_is_consumed: the output is piped into `wc` or `xargs`,
#              or into a `grep` that counts (`-c`, `--count`), or a `&&` or `||` tests the status
#              of the pipeline so far.
#
#              Asked about `kill`, a wrapper whose payload holds one counts as well
#              (`| bash -c 'xargs kill'`): classify::classify_command marks its anchor in the
#              kills array with the value `payload`. Otherwise
#              the word looked for must be the command word of a later pipeline stage, found by
#              stepping tokens::prefix_chain_step over the stage: prefix words, their options, option
#              values and operands, and assignment words may stand in front of it (`| xargs kill`,
#              `| sudo -u root xargs -n 1 kill`, `| xargs timeout 5 kill`, `| sudo wc -l`), while
#              `pgrep --full x | grep -i kill` merely searches for the word and
#              `| xargs sudo -u kill echo` names a user. A `$(...)`, `$((...))`, backtick or
#              process-substitution region is stepped over whole, as the one word it is
#              (`| xargs -P $(nproc) kill`), and a pipe inside it is not this pipeline's. One
#              that is a redirection's target (`2> >(cat)`) is no word at all. The one
#              region that is read is a `>(...)`: the command inside it reads what the stage writes
#              to it (`| tee >(wc -l)`, `| tee >(xargs kill)`), so the word looked for anywhere in it
#              counts.
#
#              A group, a subshell or a compound command (`if`, `case`, `for`, `select`, `while`,
#              `until`) that is a stage, in any position, is read inside: its stdin is the pipe,
#              and which of its commands read it is not known, so the first word of each command
#              in its list is looked at like a stage's (`| { sort; xargs kill; }`,
#              `| if a; then wc -l; fi`). A `&&` or `||` behind a later command of that list
#              tests that command and is no count (`| while read -r p; do a && b; done`).
#              Asked about `kill`, any `kill` in command position inside it counts, as
#              scanner::find_invocations recorded them (`| { read -r p; kill "$p"; }`), and a
#              `while` or `until` is also handed to loops::loop_body_has_kill. Past the word that
#              closes it the pipeline goes on (`| { cat; } | xargs kill`). A function is not
#              followed to its body (`| f`).
#
#              The scan follows the invocation's own pipeline and no further: `|` and `|&`
#              carry it into the next stage, and `;` and a newline that does not follow a pipe end
#              it. Comments and blank lines behind a trailing pipe do not, and neither does the
#              body of a heredoc that starts there (`pgrep --full x <<EOF |`, the body, then
#              `xargs kill`).
#              Asked about `count`, a `&&` or `||` is the answer. Asked about `kill`, `||`, `&&`
#              and a lone `&` end the scan, because what stands behind them reads
#              nothing the invocation wrote (`pgrep --full x || kill 1`,
#              `pgrep --full x & echo y | xargs kill`) -- unless a group, subshell or compound
#              command holds them.
#              Inside one that a stage of this pipeline opened, the command behind the operator
#              still reads the pipe (`pgrep --full x | (grep -v y || xargs kill)`). Inside one the
#              invocation itself sits in, found by consumption::construct_bounds, the output is
#              that construct's, so the scan goes on from its closer
#              (`(pgrep --full x || true) | xargs kill`, `{ pgrep --full x; } | xargs kill`,
#              `if a; then pgrep --full x; fi | xargs kill`). Behind a list operator that closer
#              is the first `)` or `}` ahead that nothing ahead opened, whatever position it
#              stands in, which fails closed. A lone `&`, a `;` and a newline go on from the
#              closer for either question, and a `&&` or `||` past one is not counted
#              (`(pgrep --full x &) && echo z`, `{ pgrep --full x; echo y; } && echo z`).
# @arg $1 tokens_var name of the caller's token array
# @arg $2 openers_var name of the caller's array mapping the index of each token that closes a
#         region to the index of the token that opened it
# @arg $3 kills_var name of the caller's array holding an entry at the index of every `kill` in
#         command position, and at the anchor of every wrapper whose payload holds one
# @arg $4 target index of the invocation token
# @arg $5 seek `kill` or `count`
# @exitcode 0 a later stage is a `kill`; or, asked about `count`, one is `wc`, `xargs` or a
#           counting `grep`, or a `&&` or `||` follows
# @exitcode 1 neither
function consumption::pipeline_feeds() {
  local -n toks="$1"
  local -n openers="$2"
  local -n kills="$3"
  local -r tokens_var="$1" openers_var="$2" kills_var="$3" target="$4" seek="$5"
  # shellcheck disable=SC2034 # redir and the chain state are written through namerefs, which shellcheck cannot follow
  local idx segment='none' token word prev='none' redir='' chain='' chain_skip=0 chain_operands=0 at_cmd=0
  local close opener operator span opened closer nest ahead detached=0 listed=0 inside target_region
  local grep_skip=0 i in_body=0 top before='' loose=0
  local -r grep_value_re='^--(regexp|file|max-count|after-context|before-context|context|include|exclude|label)$'
  # The groups, subshells and compound commands opened since the invocation, innermost last:
  # each entry is the word that closes one.
  local -a closers=() open=()
  for close in "${!openers[@]}"; do
    closers["${openers[close]}"]="${close}"
  done
  for ((idx = target + 1; idx < ${#toks[@]}; idx++)); do
    token="${toks[idx]}"
    if ((in_body == 1)); then
      # The body of a heredoc behind a trailing pipe: the array has no offsets, so the body is
      # read as far as its tokens are filler. Its text is masked to filler, a substitution in
      # it is a region, and the terminator line is filler too.
      if [[ -n "${closers[idx]:-}" ]]; then
        idx="${closers[idx]}"
        continue
      fi
      if [[ "${token}" == '<NL>' || "${token%'$'}" != *[!$'\001']* ]]; then
        continue
      fi
      in_body=0
    fi
    if [[ -n "${closers[idx]:-}" ]]; then
      # A region is one word of its simple command. The `$` word in front of a `$(` has been
      # stepped already, and an assignment word holds its backtick region; any other backtick
      # pair or process substitution is a word of its own.
      opener="${idx}"
      idx="${closers[idx]}"
      # A region right behind a redirection operator is that redirection's target
      # (`2> >(cat)`), not a word, and the `|` after it is a pipe and not the tail of `>|`.
      target_region=0
      if [[ -n "${redir}" ]]; then
        target_region=1
        redir=''
      fi
      if [[ "${token}" == '>' ]]; then
        for ((inside = opener; inside < idx; inside++)); do
          case "${seek}:${toks[inside]##*/}" in
            'count:wc' | 'count:xargs') return 0 ;;
            'kill:kill')
              if [[ -n "${kills[inside]:-}" ]]; then
                return 0
              fi
              ;;
          esac
        done
      fi
      # The closing quote of `"$(...)"` is one byte of the scanner's quote filler, and ends the
      # same word.
      if [[ "${toks[idx + 1]:-}" == $'\001' ]]; then
        idx="$((idx + 1))"
      fi
      if ((target_region == 1)) || [[ "${token}" == '(' ]] \
        || tokens::region_holds_assignment "${tokens_var}" "${openers_var}" "${opener}"; then
        continue
      fi
      token='procsub'
    elif tokens::redirection_step "${token}" redir; then
      # A redirection (`| >f xargs kill`, `xargs 2>&1 kill`) is neither a command word nor an operand.
      continue
    fi
    word="${token##*/}"
    # An option is no path: reduced, `--chdir=/tmp` would read as the word `tmp` and end the chain.
    # The one exception is the command line attached to `env -S` (see SPLIT_STRING_WORD_RE).
    [[ "${token}" == -* && ! "${token}" =~ ${SPLIT_STRING_WORD_RE} ]] && word="${token}"
    if [[ "${token}" == '|' || "${token}" == '&' ]]; then
      tokens::list_operator_at "${tokens_var}" "${idx}" operator span
      case "${operator}" in
        'pipe')
          # The `pipe` sentinel is the one tokens::prefix_chain_step leaves after a `|`: a `time`
          # there is GNU time, with options of its own.
          segment='head'
          at_cmd=1
          chain='pipe'
          chain_skip=0
          # shellcheck disable=SC2034 # read through tokens::prefix_chain_step's nameref
          chain_operands=0
          prev='|'
          idx="$((idx + span - 1))"
          continue
          ;;
        'or' | 'and')
          # Whatever stands behind it runs or not by the status of the pipeline so far. Behind
          # a later command of a stage's own list it tests that command, not the pipeline.
          if [[ "${seek}" == 'count' ]] && ((detached == 0 && listed == 0)); then
            return 0
          fi
          ;;
        'background') detached=1 ;;
      esac
      idx="$((idx + span - 1))"
      if ((${#open[@]} > 0 || loose > 0)); then
        # Inside a group or compound command a later stage opened: the next command reads the
        # same pipe. A `{` that is a word with no `}` behind it yet is read as one too
        # (`| grep -v { || kill 1`), which fails closed.
        segment='head'
        at_cmd=1
        chain=''
        chain_skip=0
        # shellcheck disable=SC2034 # read through tokens::prefix_chain_step's nameref
        chain_operands=0
        continue
      fi
      # On to the closer of the group the invocation sits in, if there is one: the first `)` or
      # `}` ahead that nothing ahead opened. That reading knows no command position, so a stray
      # closer counts (`pgrep --full x || echo } | xargs kill`), which fails closed. With none,
      # the closer of the compound command around the invocation.
      nest=0
      closer=-1
      for ((ahead = idx + 1; ahead < ${#toks[@]}; ahead++)); do
        if [[ -n "${closers[ahead]:-}" ]]; then
          ahead="${closers[ahead]}"
          continue
        fi
        case "${toks[ahead]}" in
          '(' | '{') nest="$((nest + 1))" ;;
          ')' | '}')
            if ((nest == 0)); then
              closer="${ahead}"
              break
            fi
            nest="$((nest - 1))"
            ;;
        esac
      done
      if ((closer < 0)); then
        consumption::construct_bounds "${tokens_var}" "${openers_var}" "${idx}" opened closer || break
      fi
      idx="${closer}"
      segment='other'
      continue
    fi
    case "${token}" in
      ';' | '<NL>')
        # A newline after a trailing `|` continues the pipeline -- bash does
        # not end the command there, and the next stage is usually on the next line.
        if [[ "${token}" == '<NL>' && "${prev}" == '|' ]]; then
          continue
        fi
        if ((${#open[@]} > 0)); then
          # Inside a group or compound command a later stage opened: the next command of its
          # list reads the same pipe.
          segment='head'
          at_cmd=1
          chain=''
          chain_skip=0
          # shellcheck disable=SC2034 # read through tokens::prefix_chain_step's nameref
          chain_operands=0
          prev="${token}"
          listed=1
          continue
        fi
        # Anywhere else it ends the invocation's command. Inside a group or compound command
        # the output is still that construct's, so the scan goes on from its closer; the status
        # a `&&` or `||` behind it tests is some later command's.
        consumption::construct_bounds "${tokens_var}" "${openers_var}" "${idx}" opened closer || break
        idx="${closer}"
        segment='other'
        detached=1
        continue
        ;;
      '<HD:'*'>')
        # A heredoc's body starts here. Behind a trailing pipe the next stage follows the body.
        if [[ "${prev}" == '|' ]]; then
          in_body=1
          continue
        fi
        ;;
    esac
    before="${prev}"
    prev="${word}"
    # A `kill` in command position inside a group or compound command that is a stage reads the
    # pipe, or may: which of the commands in there read their stdin is not known. Outside one
    # only a wrapper whose payload kills counts here (`| bash -c 'xargs kill'`), which
    # classify::classify_command records with the value `payload`; a stage's own `kill` is
    # found as its command word below, since a recorded one may stand behind the braces of a
    # `{}` argument (`| xargs -I{} echo {} kill`).
    if [[ "${seek}" == 'kill' && -n "${kills[idx]:-}" ]] \
      && { ((${#open[@]} > 0)) || [[ "${kills[idx]}" == 'payload' ]]; }; then
      return 0
    fi
    # The braces of an `xargs -I{}` placeholder are tokens of their own. Among xargs's own words
    # they are an option's value or an argument, not a group, and the word after them can still
    # be the command (`xargs -I{} kill {}`). Behind any other prefix `{}` is the command it runs.
    if [[ "${segment}" == 'head' && "${chain}" == 'xargs' ]] && [[ "${token}" == '{' || "${token}" == '}' ]]; then
      chain_skip=0
      at_cmd=1
      continue
    fi
    # The groups and subshells opened since the invocation. One that opens a stage is read
    # like the stage it is: its first word is in command position. A brace is a group's only
    # in command position: anywhere else it is a word (`{}`, `f{,.bak}`). A parenthesis
    # directly inside a `case` is a pattern's, `(a)` or `a)`, and the pattern's list starts
    # behind the closing one. A closer with none open closes a construct the invocation sits
    # in.
    top=''
    ((${#open[@]} > 0)) && top="${open[-1]}"
    case "${token}" in
      '(' | '{')
        if [[ "${segment}" == 'head' ]] && ((at_cmd == 1)); then
          open+=("${token}")
          chain=''
          continue
        fi
        [[ "${token}" == '(' && "${top}" != 'esac' ]] && open+=('(')
        [[ "${token}" == '{' ]] && loose="$((loose + 1))"
        ;;
      ')')
        if [[ "${top}" == 'esac' ]]; then
          segment='head'
          at_cmd=1
          chain=''
          chain_skip=0
          # shellcheck disable=SC2034 # read through tokens::prefix_chain_step's nameref
          chain_operands=0
          continue
        fi
        if [[ "${top}" == '(' ]]; then
          unset 'open[-1]'
          ((${#open[@]} > 0)) || listed=0
        fi
        ;;
      '}')
        if [[ "${top}" == '{' && "${segment}" == 'head' ]] && ((at_cmd == 1)); then
          unset 'open[-1]'
          ((${#open[@]} > 0)) || listed=0
        elif ((loose > 0)); then
          loose="$((loose - 1))"
        fi
        ;;
      'fi' | 'esac' | 'done')
        # The word that closes a compound command, in command position or, as bash also reads
        # it, directly behind another closing word (`fi done`, `) done`).
        if [[ "${top}" == "${token}" ]] \
          && { { [[ "${segment}" == 'head' ]] && ((at_cmd == 1)); } \
            || [[ "${before}" == ')' || "${before}" == '}' || "${before}" == 'fi' || "${before}" == 'esac' ||
              "${before}" == 'done' ]]; }; then
          unset 'open[-1]'
          ((${#open[@]} > 0)) || listed=0
          segment='other'
          at_cmd=0
          continue
        fi
        ;;
    esac
    # The words of a `grep` stage, asked about a count: `-c` or `--count` among its options makes
    # grep print one, up to a `--` or an operator. A cluster is read as getopt reads it, so the
    # letters behind one that takes a value are that value (`-ec` searches for `c`), and so is
    # the word after it, as it is after a long option that takes one.
    if [[ "${segment}" == 'grep' ]]; then
      if tokens::is_operator "${token}"; then
        segment='other'
      elif ((grep_skip == 1)); then
        grep_skip=0
      elif [[ "${token}" == '--' ]]; then
        segment='other'
      elif [[ "${token}" == '--count' ]]; then
        return 0
      elif [[ "${token}" =~ ${grep_value_re} ]]; then
        grep_skip=1
      elif [[ "${token}" =~ ^-[A-Za-z0-9]+$ ]]; then
        for ((i = 1; i < ${#token}; i++)); do
          case "${token:i:1}" in
            'c') return 0 ;;
            [efmABCdD])
              ((i == ${#token} - 1)) && grep_skip=1
              break
              ;;
          esac
        done
      fi
      continue
    fi
    [[ "${segment}" == 'head' ]] || continue
    if tokens::is_operator "${token}"; then
      segment='other'
      continue
    fi
    if ((at_cmd == 1)); then
      case "${seek}:${word}" in
        'kill:kill' | 'count:wc' | 'count:xargs') return 0 ;;
        'count:grep' | 'count:egrep' | 'count:fgrep')
          segment='grep'
          grep_skip=0
          continue
          ;;
      esac
      # A compound command that opens a stage, or stands in a group that does, is read up to
      # the word that closes it: every command in it may read the pipe.
      case "${token}" in
        'while' | 'until')
          if [[ "${seek}" == 'kill' ]] \
            && loops::loop_body_has_kill "${tokens_var}" "${openers_var}" "${kills_var}" "${idx}"; then
            return 0
          fi
          open+=('done')
          listed=1
          ;;
        'for' | 'select')
          open+=('done')
          listed=1
          ;;
        'if')
          open+=('fi')
          listed=1
          ;;
        'case')
          # The word and the patterns behind it are no commands; the `)` of a pattern restores
          # command position.
          open+=('esac')
          listed=1
          segment='other'
          at_cmd=0
          continue
          ;;
      esac
    fi
    if tokens::prefix_chain_step "${token}" "${word}" "${at_cmd}" chain chain_skip chain_operands; then
      at_cmd=1
    else
      at_cmd=0
      # Out of command position with no option value pending: the stage's command word has gone
      # by, and it was not the one looked for.
      if ((chain_skip == 0)); then
        segment='other'
      fi
    fi
  done
  return 1
}

# @description Backward form of consumption::feeds_a_kill: `kill $(pgrep ...)`, `kill -9 foo $(pgrep ...)`,
#              and the backtick equivalent. Here `kill` precedes the invocation, so the forward scan
#              cannot see it. Walk back to the nearest `kill` the substitution is a word of: the
#              substitution punctuation, flags and literal operands (`kill -s TERM foo $(pgrep ...)`)
#              are all arguments of that `kill` and are stepped over, and so is any earlier whole
#              `$(...)`, `$((...))`, backtick or process-substitution region (`kill $(true) $(pgrep ...)`,
#              `kill <(true) $(pgrep ...)`), which is one word of it. An operator or a keyword
#              inside the `$(...)`, `$((...))` or backtick region that holds the invocation means the
#              invocation is not that region's first word (`kill $(cd /tmp && pgrep ...)`,
#              `kill $(time pgrep ...)`, `kill $(if a; then pgrep ...; fi)`): its output is still the
#              region's, so the walk goes on from the region's opener, and from the opener of each
#              region around that one in turn. It does not once it has left a region an assignment
#              word holds (`kill $(echo 1; x=$(pgrep ...))`): the variable has the output, not the
#              `kill`. An operator or a keyword outside every such region ends the walk. The `kill`
#              must then be in command position, as scanner::find_invocations recorded it
#              (`sudo -u root kill $(...)`, `timeout 5 kill $(...)`) -- otherwise
#              `echo kill $(...)`, where `kill` is merely an argument word, would be denied -- and one
#              that is not is an argument word like any other, so the walk goes on to a real `kill`
#              before it (`kill foo kill $(...)`). A wrapper whose payload kills counts as a
#              `kill` wherever the walk meets its mark (`bash -c 'kill "$1"' _ $(...)`). A bare
#              `in` is only a for/select head -- and thus worth
#              deferring to loops::loop_body_has_kill -- when the token two back (past the loop
#              variable) is actually `for`/`select`; otherwise the forward walk in
#              loops::loop_body_has_kill could cross into an unrelated later loop's body, and the
#              walk ends. A for/select head whose body has no `kill` is a keyword like any other
#              (`kill $(for i in $(pgrep ...); do echo "$i"; done)`).
# @arg $1 tokens_var name of the caller's token array
# @arg $2 openers_var name of the caller's array mapping the index of each token that closes a
#         region to the index of the token that opened it
# @arg $3 kills_var name of the caller's array holding an entry at the index of every `kill` in
#         command position, and at the anchor of every wrapper whose payload holds one
# @arg $4 target index of the invocation token
# @exitcode 0 a kill consumes the substitution
# @exitcode 1 it does not
function consumption::feeds_a_kill_backward() {
  local -n toks="$1"
  local -n openers="$2"
  local -n kills="$3"
  local -r tokens_var="$1" openers_var="$2" kills_var="$3" target="$4"
  local word k="$((target - 1))" span close opener enclosing captured=0 stop
  while ((k >= 0)); do
    # A redirection between the substitution's opener and the invocation
    # (`kill $(>f pgrep ...)`) is skipped whole, target included.
    tokens::redirection_span_back "${tokens_var}" "${k}" span
    if ((span > 0)); then
      k="$((k - span))"
      continue
    fi
    # A region that closed before the invocation is one word of the command: step over all of it.
    if [[ -n "${openers[k]:-}" ]]; then
      k="$((openers[k] - 1))"
      continue
    fi
    # A wrapper whose payload kills, as classify::classify_command marked it: the substitution is
    # one of its operands, and so a parameter of that payload (`bash -c 'kill "$1"' _ $(...)`).
    if [[ "${kills[k]:-}" == 'payload' ]]; then
      return 0
    fi
    word="${toks[k]##*/}"
    # An option is no path: reduced, `--file=/x/in` would read as the `in` of a `for` head.
    [[ "${toks[k]}" == -* && ! "${toks[k]}" =~ ${SPLIT_STRING_WORD_RE} ]] && word="${toks[k]}"
    stop=0
    case "${word}" in
      '$') ;;
      '(' | '`')
        # A closer was stepped over above, so this one opens a region the walk is leaving.
        if tokens::region_holds_assignment "${tokens_var}" "${openers_var}" "${k}"; then
          captured=1
        fi
        ;;
      'kill')
        if [[ -n "${kills[k]:-}" ]]; then
          return 0
        fi
        ;;
      'in')
        if ((k < 2)) || [[ "${toks[k - 2]}" != 'for' && "${toks[k - 2]}" != 'select' ]]; then
          return 1
        fi
        loops::loop_body_has_kill "${tokens_var}" "${openers_var}" "${kills_var}" "${k}" && return 0
        stop=1
        ;;
      *)
        if tokens::is_operator "${toks[k]}" || tokens::is_keyword "${toks[k]}"; then
          stop=1
        fi
        ;;
    esac
    if ((stop == 1)); then
      ((captured == 0)) || return 1
      # The innermost `$(...)`, `$((...))` or backtick region that opens before this token and
      # closes after the invocation. A process substitution is not one: its opener is a `<` or `>`.
      enclosing=-1
      for close in "${!openers[@]}"; do
        opener="${openers[close]}"
        ((opener < k && opener > enclosing && close > target)) || continue
        if [[ "${toks[opener]}" == '`' ]] \
          || { [[ "${toks[opener]}" == '(' ]] && ((opener > 0)) && [[ "${toks[opener - 1]}" == *'$' ]]; }; then
          enclosing="${opener}"
        fi
      done
      ((enclosing >= 0)) || return 1
      k="${enclosing}"
      continue
    fi
    k="$((k - 1))"
  done
  return 1
}

# @description True when the invocation stands in a process substitution that is the stdin of a
#              command (`cmd < <(pgrep ...)`), and that command does what the caller asks. The
#              spelling is the pipe written the other way round, and the one to use where a pipe
#              into `while` would lose the loop's variables.
#
#              For `kill`: the substitution is redirected into a loop (`done < <(...)`) whose body
#              holds a `kill` in command position, as scanner::find_invocations recorded them.
#              A `kill` among the words of a simple command (`xargs kill < <(...)`) is not this
#              function's: it stands before the invocation, where
#              consumption::feeds_a_kill_backward looks. For `count`: the command word of the
#              simple command in front of the redirection, behind any assignments, prefix
#              commands and their flags, is `mapfile`, `readarray` or `read`, which capture the
#              output, or `wc` or `xargs`.
#
#              A group or subshell in front of the redirection (`{ xargs kill; } < <(...)`) reads
#              the substitution as it reads a pipe: for `kill`, any `kill` in command position
#              inside it counts, and for `count`, one of those readers as the first word of a
#              command inside it. consumption::construct_bounds finds where it opens.
#
#              The substitution must be the innermost region around the invocation, and the target
#              of an input redirection of any descriptor (`< <(...)`, `3< <(...)`). Redirections
#              with a plain word as their target that stand between the command and that one are
#              stepped over. A later redirection of the same descriptor is not looked at, and
#              neither is what else runs inside the substitution (`< <(pgrep ... | sort)`); both
#              fail closed.
# @arg $1 tokens_var name of the caller's token array
# @arg $2 openers_var name of the caller's array mapping the index of each token that closes a
#         region to the index of the token that opened it
# @arg $3 kills_var name of the caller's array holding an entry at the index of every `kill` in
#         command position, and at the anchor of every wrapper whose payload holds one
# @arg $4 target index of the invocation token
# @arg $5 seek `kill` or `count`
# @exitcode 0 the command the substitution feeds does what was asked
# @exitcode 1 it does not, or the invocation is in no such substitution
function consumption::substitution_feeds() {
  local -n toks="$1"
  local -n openers="$2"
  local -n kills="$3"
  local -r tokens_var="$1" openers_var="$2" target="$4" seek="$5"
  local -r input_re='^[0-9]*<$'
  local close opener enclosing=-1 k span start idx first word opened closer
  for close in "${!openers[@]}"; do
    opener="${openers[close]}"
    if ((opener < target && close > target && opener > enclosing)); then
      enclosing="${opener}"
    fi
  done
  ((enclosing >= 1)) || return 1
  [[ "${toks[enclosing]}" == '<' && "${toks[enclosing - 1]}" =~ ${input_re} ]] || return 1
  k="$((enclosing - 2))"
  while ((k >= 0)); do
    tokens::redirection_span_back "${tokens_var}" "${k}" span
    ((span > 0)) || break
    k="$((k - span))"
  done
  ((k >= 0)) || return 1
  # A `done` that closes no body is the last word of a simple command (`read -r done`).
  if [[ "${toks[k]}" == 'done' ]] \
    && start="$(loops::done_body_start "${tokens_var}" "${openers_var}" "${k}")"; then
    [[ "${seek}" == 'kill' ]] || return 1
    for ((idx = start + 1; idx < k; idx++)); do
      if [[ -n "${kills[idx]:-}" ]]; then
        return 0
      fi
    done
    return 1
  fi
  # A group or subshell reads the substitution as it reads a pipe: every command in it may.
  if [[ "${toks[k]}" == '}' || "${toks[k]}" == ')' ]] && [[ -z "${openers[k]:-}" ]] && ((k > 0)) \
    && consumption::construct_bounds "${tokens_var}" "${openers_var}" "$((k - 1))" opened closer \
    && ((closer == k)); then
    for ((idx = opened + 1; idx < k; idx++)); do
      if [[ "${seek}" == 'kill' ]]; then
        [[ -n "${kills[idx]:-}" ]] && return 0
        continue
      fi
      # A reader's name counts as the first word of a command only.
      tokens::is_operator "${toks[idx - 1]}" || tokens::is_keyword "${toks[idx - 1]}" || continue
      case "${toks[idx]##*/}" in
        'mapfile' | 'readarray' | 'read' | 'wc' | 'xargs') return 0 ;;
      esac
    done
    return 1
  fi
  [[ "${seek}" == 'count' ]] || return 1
  # Back to the operator or keyword the simple command starts behind, then forward to its
  # command word: a reader's name among the arguments (`grep read`) reads nothing.
  first="${k}"
  while ((first >= 0)); do
    if [[ -n "${openers[first]:-}" ]]; then
      first="$((openers[first] - 1))"
      continue
    fi
    if tokens::is_operator "${toks[first]}" || tokens::is_keyword "${toks[first]}"; then
      break
    fi
    first="$((first - 1))"
  done
  for ((idx = first + 1; idx <= k; idx++)); do
    word="${toks[idx]}"
    if tokens::is_assignment_word "${word}" || [[ "${word}" == -* ]]; then
      continue
    fi
    # Before the prefix test: `xargs` is a prefix command as well as a reader.
    case "${word##*/}" in
      'mapfile' | 'readarray' | 'read' | 'wc' | 'xargs') return 0 ;;
    esac
    tokens::is_prefix_command "${word##*/}" || return 1
  done
  return 1
}

# @description True when the invocation's output feeds a kill: forward (`pgrep ... | xargs
#              kill`, `... | while read p; do kill "$p"; done`), backward (`kill $(pgrep ...)`), or
#              as the stdin of a loop or group that kills (`while read p; do kill "$p"; done < <(pgrep
#              ...)`). The scans are independent; see consumption::pipeline_feeds,
#              consumption::feeds_a_kill_backward and consumption::substitution_feeds.
# @arg $1 tokens_var name of the caller's token array (built once by classify::classify_command; every
#         invocation in the same command reuses it rather than re-parsing the token stream)
# @arg $2 openers_var name of the caller's region-opener array, built alongside the token array
# @arg $3 kills_var name of the caller's array holding an entry at the index of every `kill` in
#         command position, as scanner::find_invocations reported them, and at the anchor of
#         every wrapper whose payload holds one
# @arg $4 target index of the invocation token
# @exitcode 0 output feeds a kill
# @exitcode 1 it does not
function consumption::feeds_a_kill() {
  local -r tokens_var="$1" openers_var="$2" kills_var="$3" target="$4"
  consumption::pipeline_feeds "${tokens_var}" "${openers_var}" "${kills_var}" "${target}" 'kill' \
    || consumption::feeds_a_kill_backward "${tokens_var}" "${openers_var}" "${kills_var}" "${target}" \
    || consumption::substitution_feeds "${tokens_var}" "${openers_var}" "${kills_var}" "${target}" 'kill'
}

# @description True when an invocation sits inside a command substitution, so its output is captured
#              rather than printed. Counted as a depth over the token stream: a substring test on the
#              raw command prefix cannot tell an enclosing `$(` from an unrelated one that has
#              already closed, which made `for i in $(seq 1 5); do pgrep -af java; ...; done` read as
#              a capture. `$` is not an operator token, so the opener is recognised as any token
#              ending in `$` immediately followed by `(`, which also covers `p=$(...)`.
# @arg $1 tokens_var name of the caller's token array, built once by classify::classify_command
# @arg $2 target index of the invocation token
# @exitcode 0 the invocation is inside a command substitution
# @exitcode 1 it is not
function consumption::invocation_is_captured() {
  local -n toks="$1"
  local -r target="$2"
  local -a stack=()
  local idx dollar=0 token opener
  for ((idx = 0; idx <= target; idx++)); do
    token="${toks[idx]}"
    if ((idx == target)); then
      if ((${#stack[@]} == 0)); then
        return 1
      fi
      for opener in "${stack[@]}"; do
        [[ "${opener}" == 'capture' || "${opener}" == 'backtick' ]] && return 0
      done
      return 1
    fi
    case "${token}" in
      '(')
        if ((dollar == 1)); then
          stack+=('capture')
        else
          stack+=('subshell')
        fi
        ;;
      ')')
        if ((${#stack[@]} > 0)); then
          unset 'stack[${#stack[@]}-1]'
        fi
        ;;
      '`')
        if ((${#stack[@]} > 0)) && [[ "${stack[${#stack[@]} - 1]}" == 'backtick' ]]; then
          unset 'stack[${#stack[@]}-1]'
        else
          stack+=('backtick')
        fi
        ;;
    esac
    if [[ "${token}" == *'$' ]]; then
      dollar=1
    else
      dollar=0
    fi
  done
  return 1
}

# @description True when the command immediately after an invocation, in the same list, reads `$?`
#              or `PIPESTATUS`. That is a consumption of the exit status exactly like `&&` or an
#              enclosing `if`, and consumption::pipeline_feeds cannot see it because it stops at the
#              `;` or newline that ends the invocation's pipeline.
#
#              The `$?` test runs against the RAW command text rather than the token stream, because
#              the scanner masks a double-quoted `$?` (`echo "exit=$?"`) down to filler -- a shape real
#              commands use -- and the tokens would show nothing. What the tokens do supply,
#              and a raw substring search could not, are mask-aware separator offsets: only a `;` or
#              newline the scanner saw as real code delimits the segment, so a `;` inside a quoted
#              pattern cannot split it.
#
#              Scope is deliberately one command, not the rest of the list: in `pgrep --full x; echo
#              hi; rc=$?` the status belongs to `echo`, and warning there would be wrong. That command
#              is the first one with a word in it: a blank line or a comment line between the two
#              holds no command and changes no status. The cost of
#              reading raw text is a single-quoted literal `$?` counting as a read, and any text
#              that spells `PIPESTATUS`; that direction only over-warns, and no realistic command
#              writes either right after a pgrep without reading it.
# @arg $1 command the raw command string
# @arg $2 tokens the token stream from scanner::scan_command
# @arg $3 target index of the invocation token
# @exitcode 0 the following command reads the exit status
# @exitcode 1 it does not
function consumption::next_command_reads_status() {
  local -r command="$1" tokens="$2" target="$3"
  local idx=0 offset token start=-1 end=-1 has_word=0
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    if ((idx > target)) && { [[ "${token}" == ';' ]] || [[ "${token}" == '<NL>' ]]; }; then
      # A separator with no word behind the last one ends nothing: a blank line, a comment line
      # or `; # note` holds no command, and the next command is the one after it.
      if ((start < 0 || has_word == 0)); then
        start="$((offset + 1))"
      else
        end="${offset}"
        break
      fi
    elif ((start >= 0)); then
      has_word=1
    fi
    idx="$((idx + 1))"
  done <<< "${tokens}"
  ((start < 0)) && return 1
  ((end < 0)) && end="${#command}"
  ((end <= start)) && return 1
  [[ "${command:start:end-start}" == *'$?'* || "${command:start:end-start}" == *'PIPESTATUS'* ]]
}

# @description True when an invocation's result is read as a boolean, a count, or captured into a
#              variable, rather than merely displayed. Only then can the silent off-by-one produce a
#              wrong conclusion. These shapes count: pgrep's own `--count` / `-c`; an enclosing `if`
#              or `elif`, or a leading `!`, which read the exit status as a boolean; `wc`, `xargs`
#              or a counting `grep` (`-c`, `--count`) as the command of a later stage of the
#              invocation's pipeline, or a `&&` or `||` behind
#              that pipeline, which consumption::pipeline_feeds finds; standing in a process
#              substitution that is the stdin of `mapfile`, `readarray`, `read`, `wc` or `xargs`,
#              or of a group that holds one, which consumption::substitution_feeds finds; sitting
#              inside a command substitution; and the next command in the list reading `$?`, which
#              consumption::next_command_reads_status handles. A pipeline that only passes the output
#              on (`| sort | head`) displays it, and a `&&` or `||` behind a lone `&` tests some
#              other command's status.
# @arg $1 tokens_var name of the caller's token array, built once by classify::classify_command
# @arg $2 openers_var name of the caller's region-opener array, built alongside the token array
# @arg $3 kills_var name of the caller's array holding an entry at the index of every `kill` in
#         command position, and at the anchor of every wrapper whose payload holds one
# @arg $4 target index of the invocation token
# @arg $5 args the invocation's argument lines
# @arg $6 command the raw command string, for the `$?` check
# @arg $7 tokens the token stream from scanner::scan_command, for the `$?` check
# @exitcode 0 the result is consumed
# @exitcode 1 the result is only displayed
function consumption::result_is_consumed() {
  local -n toks="$1"
  local -r tokens_var="$1" openers_var="$2" kills_var="$3" target="$4" args="$5" command="$6" tokens="$7"
  local offset token
  while IFS=$'\t' read -r offset token; do
    [[ -z "${token}" ]] && continue
    case "${token}" in
      '--count') return 0 ;;
      --*) ;;
      -[a-zA-Z]*)
        if [[ "${token}" == *c* ]]; then
          return 0
        fi
        ;;
    esac
  done <<< "${args}"

  # An enclosing `if` / `elif`, or a negation, reads the exit status as a boolean.
  # Walk back over prefix words so `if sudo pgrep --full x` still counts.
  #
  # Anything between the invocation and the operator or keyword that opened its
  # command is prefix material by construction: scanner::find_invocations only reports an
  # invocation in command position, so a word reached here is a prefix command,
  # one of its flags, that flag's value, an assignment word, or part of a
  # redirection. Testing for a
  # prefix COMMAND alone stopped at the value word and hid the enclosing `if` of
  # `if sudo -u bob pgrep --full x`, `if timeout 5 pgrep --full x` and every
  # other prefix carrying an option or an operand (#132). The prefix-command test
  # stays ahead of the stop test because `time` is both a prefix and a keyword.
  local k="$((target - 1))" word
  while ((k >= 0)); do
    word="${toks[k]##*/}"
    # An option is no path: reduced, `--file=/x/if` would read as the keyword.
    [[ "${toks[k]}" == -* && ! "${toks[k]}" =~ ${SPLIT_STRING_WORD_RE} ]] && word="${toks[k]}"
    case "${word}" in
      'if' | 'elif' | '!') return 0 ;;
      *)
        if ! tokens::is_prefix_command "${word}" \
          && { tokens::is_operator "${toks[k]}" || tokens::is_keyword "${toks[k]}"; }; then
          break
        fi
        ;;
    esac
    k="$((k - 1))"
  done

  consumption::pipeline_feeds "${tokens_var}" "${openers_var}" "${kills_var}" "${target}" 'count' && return 0

  # `mapfile -t pids < <(pgrep ...)`: the same reading with the substitution as the command's stdin.
  consumption::substitution_feeds "${tokens_var}" "${openers_var}" "${kills_var}" "${target}" 'count' && return 0

  # `p=$(pgrep ...)`: the output is captured rather than printed.
  consumption::invocation_is_captured "${tokens_var}" "${target}" && return 0

  # `pgrep --full x; rc=$?`: the status is read by the next command in the list.
  consumption::next_command_reads_status "${command}" "${tokens}" "${target}" && return 0
  return 1
}
