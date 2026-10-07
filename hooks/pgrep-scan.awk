# Mask quoted regions and emit tokens with byte offsets, in one linear pass.
# A command substitution re-enters an unquoted context even inside double
# quotes, because the shell expands it there -- that is what makes
# `until [ -z "$(pgrep --full x)" ]` visible to the scanner.
#
# An unquoted `#` that starts a word opens a comment, which the shell ignores to
# end of line. Masking it matters in both directions: a single apostrophe in
# prose ("it's", "don't") otherwise inverts quote parity for the whole rest of
# the command, which has been observed both exposing a quoted string as if it
# were code and hiding a real poll loop inside a quoted region.
#
# A heredoc body is text the shell feeds to a command, not code. Its
# bytes are masked from the newline after the `<<` line to the terminator
# line, which is masked too. A quoted delimiter (`<<'EOF'`, `<<"EOF"`,
# `<<\EOF`) masks everything; an unquoted one masks like a double-quoted
# string, so `$(` and backticks still re-enter code context. One body is
# emitted to the tokenizer as a `<HD:len>` marker at its first byte, which is
# how the hook slices a body fed to a local shell wrapper.
#
# Input handling deliberately depends on nothing about RS. The command is read
# line by line with getline under the default RS and reassembled with "\n", so
# the scanner behaves identically on gawk, mawk and one-true-awk (BWK, the stock
# awk on macOS). BWK truncates RS="\0" to RS="" -- paragraph mode -- which
# splits records on blank lines and strips leading/trailing newlines; the
# previous RS="\0" design tripped the integrity trailer there for every heredoc
# payload (#7). POSIX awk cannot tell `foo` from `foo\n` at end of input (there
# is no RT), so the CALLER TERMINATES THE INPUT WITH EXACTLY ONE NEWLINE and the
# code below drops exactly one: a command's own trailing newline survives,
# which is what a heredoc body's byte count depends on.
BEGIN {
  ORS = ""
  cmd = ""
  while ((getline line) > 0) cmd = cmd line "\n"
  # Drop the one newline the loop above appended. The guard is not paranoia
  # about the value: on EMPTY stdin the loop never runs, the length is 0, and
  # the bare form becomes `substr(cmd, 1, -1)`, which every awk in scope
  # already answers with "" -- POSIX says a non-positive length yields the
  # empty string, so the result was always right. What the bare form was is
  # UNLINTABLE. `gawk --lint` calls it out as
  # `warning: substr: length -1 is not >= 1`, and the static lint step that
  # runs this file under `gawk --lint=fatal --posix` has to feed it something:
  # a lint pass wants no input, so it feeds /dev/null and lands on exactly this
  # call. Spelling the empty case out is what lets that gate exist at all.
  cmd = (length(cmd) > 1) ? substr(cmd, 1, length(cmd) - 1) : ""
  n = length(cmd)
  masked = ""
  depth = 0
  ctx[0] = "N"          # N unquoted, S single-quoted, D double-quoted, H heredoc body
  # Heredocs opened on a line but not yet begun, in operator order. One queue
  # for every depth: a heredoc opened before a `$(` that opens its own on a
  # later line would pop in the wrong order, which is rare enough to note and
  # not handle.
  pq_head = 0; pq_tail = 0
  hb_n = 0              # body spans, for the tokenizer's <HD:len> marker
  i = 1
  while (i <= n) {
    ch = substr(cmd, i, 1)
    prev = (i > 1) ? substr(cmd, i - 1, 1) : ""
    cur = ctx[depth]
    out = ch
    if (cur == "S") {
      out = "\001"
      if (ch == "'") ctx[depth] = "N_END"
    } else if (cur == "D") {
      if (ch == "$" && substr(cmd, i + 1, 1) == "(") {
        masked = masked "$("; i += 2; depth++; ctx[depth] = "N"
        opener[depth] = (substr(cmd, i, 1) == "(") ? "A" : "P"
        continue
      }
      if (ch == "`") {
        masked = masked "`"; i++
        if (depth > 0 && opener[depth] == "B") { depth-- } else { depth++; ctx[depth] = "N"; opener[depth] = "B" }
        continue
      }
      out = "\001"
      if (ch == "\\") { masked = masked "\001\001"; i += 2; continue }
      if (ch == "\"") ctx[depth] = "N_END"
    } else if (cur == "H") {
      # At a line start, a line equal to the delimiter (after leading tabs,
      # for `<<-`) is the terminator: mask it and return to code. The newline
      # after it is the unquoted branch's, which starts the next queued body.
      if (hd_bol[depth]) {
        j = i
        if (hd_strip[depth]) while (substr(cmd, j, 1) == "\t") j++
        d = length(hd_delim[depth])
        if (substr(cmd, j, d) == hd_delim[depth] && (j + d > n || substr(cmd, j + d, 1) == "\n")) {
          hb_len[hb_id[depth]] = i - hb_start[hb_id[depth]]
          while (i < j + d) { masked = masked "\001"; i++ }
          ctx[depth] = "N"
          continue
        }
        hd_bol[depth] = 0
      }
      if (ch == "\n") { masked = masked "\n"; i++; hd_bol[depth] = 1; continue }
      if (!hd_quoted[depth]) {
        if (ch == "$" && substr(cmd, i + 1, 1) == "(") {
          masked = masked "$("; i += 2; depth++; ctx[depth] = "N"
          opener[depth] = (substr(cmd, i, 1) == "(") ? "A" : "P"
          continue
        }
        if (ch == "`") {
          masked = masked "`"; i++
          if (depth > 0 && opener[depth] == "B") { depth-- } else { depth++; ctx[depth] = "N"; opener[depth] = "B" }
          continue
        }
        # bash joins a body line ending in a backslash to the next line, so a
        # delimiter there does not end the heredoc. The escaped newline is
        # emitted without setting hd_bol, which is what starts the terminator
        # check, so the next line is not tested. Ending the body there would
        # read body text as code, and an apostrophe in it would open a quote
        # that masks a real command after the terminator. An escaped backslash
        # is consumed as a pair, so a newline after it takes the ch == "\n"
        # branch above.
        if (ch == "\\") { masked = masked ((substr(cmd, i + 1, 1) == "\n") ? "\001\n" : "\001\001"); i += 2; continue }
      }
      masked = masked "\001"; i++
      continue
    } else {
      # A newline begins the next queued heredoc body. A backslash-newline
      # never reaches here (it is consumed as a continuation below), which
      # matches bash: the body starts after the logical line.
      if (ch == "\n" && pq_head < pq_tail) {
        masked = masked "\n"; i++
        hd_delim[depth] = pq_delim[pq_head]; hd_quoted[depth] = pq_quoted[pq_head]
        hd_strip[depth] = pq_strip[pq_head]; pq_head++
        ctx[depth] = "H"; hd_bol[depth] = 1
        # The span defaults to end of input: an unterminated heredoc masks
        # everything after it (fail-open) and the terminator, when found,
        # shortens it.
        hb_id[depth] = hb_n; hb_start[hb_n] = i; hb_len[hb_n] = n + 1 - i; hb_n++
        continue
      }
      # A `#` opens a comment only at the start of a WORD. The precondition is
      # load-bearing: without it the `#` of `${#arr[@]}` would open a comment and
      # mask the rest of the line. A word also starts after a command separator,
      # so `cmd ;# note` is a comment to bash and has to be masked as one --
      # left unmasked, a substitution in the commented text restores command
      # position and the guard denies a command bash never runs.
      # `(` is deliberately not a starter here: `$(#` would swallow the closing
      # paren this scanner counts depth with. Nor are `<` and `>`, where a `#`
      # is part of a filename far more often than it opens a comment.
      if (ch == "#" && (i == 1 || prev == " " || prev == "\t" || prev == "\n" \
          || prev == ";" || prev == "&" || prev == "|")) {
        while (i <= n && substr(cmd, i, 1) != "\n") { masked = masked "\001"; i++ }
        continue
      }
      if (ch == "$" && substr(cmd, i + 1, 1) == "(") {
        masked = masked "$("; i += 2; depth++; ctx[depth] = "N"
        # `((` and `$((` are both arithmetic, where `<<` is a shift and not a
        # heredoc -- and is masked outright, so no `<<` reaches the token stream
        # for the hook's heredoc counter to trip over.
        opener[depth] = (substr(cmd, i, 1) == "(") ? "A" : "P"
        continue
      }
      if (ch == ")" && depth > 0 && (opener[depth] == "P" || opener[depth] == "A")) {
        masked = masked ")"; i++; depth--; continue
      }
      # A bare `(` nests one more arithmetic level whenever it is the first
      # paren of a `((` open (the arithmetic command form) or it appears
      # anywhere inside an already-open arithmetic level: the second paren of
      # `((`, the inner one of `$((`, and an explicit grouping paren like `(1)`
      # inside `$(( (1)<<2 ))`, which must push and pop in step with the
      # surrounding `))`, or its `)` closes the outer level early and strands
      # the rest of the arithmetic at depth 0, where a `<<` in it reads as a
      # heredoc operator.
      if (ch == "(" && (substr(cmd, i + 1, 1) == "(" || (depth > 0 && opener[depth] == "A"))) {
        masked = masked "("; i++; depth++; ctx[depth] = "N"; opener[depth] = "A"; continue
      }
      if (ch == "`") {
        masked = masked "`"; i++
        if (depth > 0 && opener[depth] == "B") { depth-- } else { depth++; ctx[depth] = "N"; opener[depth] = "B" }
        continue
      }
      if (ch == "<") {
        # A here-string is not a heredoc.
        if (substr(cmd, i + 1, 2) == "<<") { masked = masked "<<<"; i += 3; continue }
        # Inside arithmetic a `<<` is a left shift. Mask both bytes rather than
        # emitting them: the hook counts `<<` tokens to pick a wrapper's body
        # out of the marker sequence, and no marker is emitted for a shift, so
        # a `<<` left in the stream desyncs every later heredoc's ordinal. Two
        # `\001` keep the byte offsets aligned and match neither the hook's
        # heredoc regex nor its redirection one.
        if (substr(cmd, i + 1, 1) == "<" && depth > 0 && opener[depth] == "A") {
          masked = masked "\001\001"; i += 2; continue
        }
        if (substr(cmd, i + 1, 1) == "<") {
          # Read the delimiter word ahead of the cursor, applying quote
          # removal; any quoting makes the body literal. The cursor itself
          # only moves past `<<`, so the delimiter's own bytes are masked by
          # the ordinary rules below and every byte is read at most twice.
          j = i + 2
          strip = 0; quoted = 0; delim = ""
          if (substr(cmd, j, 1) == "-") { strip = 1; j++ }
          while (substr(cmd, j, 1) == " " || substr(cmd, j, 1) == "\t") j++
          while (j <= n) {
            c = substr(cmd, j, 1)
            if (c == "'") {
              quoted = 1; j++
              while (j <= n && substr(cmd, j, 1) != "'" && substr(cmd, j, 1) != "\n") { delim = delim substr(cmd, j, 1); j++ }
              # An unterminated quote ends the delimiter word at the end of its
              # line, or at end of input. Without the break the word loop runs
              # on past the newline and glues the next line's bytes onto the
              # delimiter, so `cat <<E'` would look for a terminator named `Ex`
              # rather than `E`.
              if (j > n || substr(cmd, j, 1) == "\n") break
              j++
            } else if (c == "\"") {
              quoted = 1; j++
              while (j <= n && substr(cmd, j, 1) != "\"" && substr(cmd, j, 1) != "\n") { delim = delim substr(cmd, j, 1); j++ }
              if (j > n || substr(cmd, j, 1) == "\n") break
              j++
            } else if (c == "\\") {
              quoted = 1; delim = delim substr(cmd, j + 1, 1); j += 2
            } else if (index(" \t\n;&|<>()", c) > 0) {
              break
            } else {
              delim = delim c; j++
            }
          }
          # A quoted empty delimiter (`<<''`, `<<""`) is legal bash: the body
          # runs to the first blank line. It is enqueued like any other, and
          # the terminator check in the heredoc-body branch above handles a
          # zero-length delimiter on its own -- `substr(cmd, j, 0)` is "", so
          # the suffix clause is what decides, and it demands a newline or end
          # of input right there. Left unqueued the body is scanned as code,
          # and an apostrophe in it ("it's") flips quote parity for everything
          # after, hiding a real command.
          # No delimiter word at all (`cat <<`, `cat <<;`) is a bash syntax
          # error, so nothing is enqueued for it and the rest stays code.
          if (delim != "" || quoted) {
            pq_delim[pq_tail] = delim; pq_quoted[pq_tail] = quoted; pq_strip[pq_tail] = strip; pq_tail++
          }
          masked = masked "<<"; i += 2
          continue
        }
      }

      # A lone `<` or `>` inside arithmetic is a comparison, not a redirection:
      # masked like the shift above, so the word it sits in stays whole.
      if ((ch == "<" || ch == ">") && depth > 0 && opener[depth] == "A") out = "\001"
      else if (ch == "'") { ctx[depth] = "S"; out = "\001" }
      else if (ch == "\"") { ctx[depth] = "D"; out = "\001" }
      else if (ch == "\\") {
        # A backslash-newline is a line continuation: bash removes it outright
        # and joins the text on either side. Masked as filler it would fuse
        # onto the word after it (`sudo \`, then `pkill` on the next line) and
        # hide that command name, so it becomes two spaces instead: they keep
        # the byte offsets aligned -- the bracket mitigation slices the raw
        # command by them -- and are a real token delimiter, which filler is
        # not. The price is that a word split across a continuation reads as
        # two tokens.
        # Every other escaped character keeps its masking, so an escaped quote
        # still cannot flip parity for the rest of the command.
        if (substr(cmd, i + 1, 1) == "\n") { masked = masked "  " }
        else { masked = masked "\001\001" }
        i += 2; continue
      }
    }
    if (ctx[depth] == "N_END") ctx[depth] = "N"
    masked = masked out
    i++
  }

  # Tokenize the masked string. Newline is emitted as the literal token <NL>
  # so it survives a line-oriented reader. A heredoc body's marker is emitted
  # at the body's first byte, right after the <NL> that opened it.
  word = ""; start = 0; m = 0; op_end = 0; dup_at = 0
  for (i = 1; i <= n; i++) {
    if (m < hb_n && i == hb_start[m]) {
      if (word != "") { print (start - 1) "\t" word "\n"; word = "" }
      print (i - 1) "\t<HD:" hb_len[m] ">\n"; m++
    }
    ch = substr(masked, i, 1)
    if (ch == " " || ch == "\t" || ch == "\n") {
      if (word != "") { print (start - 1) "\t" word "\n"; word = "" }
      if (ch == "\n") print (i - 1) "\t<NL>\n"
    } else if (index(";&|(){}`", ch) > 0) {
      if (word != "") { print (start - 1) "\t" word "\n"; word = "" }
      print (i - 1) "\t" ch "\n"
      # The `&` of `>&` and `<&` is followed by the duplication's target, whose
      # digits are not a file descriptor even when an operator follows them
      # (`2>&1<<EOF`).
      if (ch == "&" && i == op_end) dup_at = i + 1
    } else if (ch == "<" || ch == ">") {
      # A redirection operator ends the word before it and is a token of its
      # own, as bash reads it; its target is the next token, never part of it.
      # The digits of a word that is nothing but digits are the operator's file
      # descriptor (`2>`, `10<`) and stay with it. So do digits glued to a
      # quoted region (`'x'2>`): bash reads those as part of the word, but a
      # payload is then still the quoted text, and splitting them off is the
      # reading that keeps it visible. A run of `<` and `>` is one token (`>>`,
      # `<>`, `<<<`), and `<<` takes a directly following `-`.
      if (word != "" && start == dup_at) { print (start - 1) "\t" word "\n"; word = "" }
      else if (word != "" && word !~ /^[0-9]+$/) {
        k = length(word)
        while (k > 0 && substr(word, k, 1) ~ /[0-9]/) k--
        if (k > 0 && k < length(word) && substr(word, k, 1) == "\001") {
          print (start - 1) "\t" substr(word, 1, k) "\n"
          start += k; word = substr(word, k + 1)
        } else { print (start - 1) "\t" word "\n"; word = "" }
      }
      if (word == "") start = i
      word = word ch
      while (substr(masked, i + 1, 1) == "<" || substr(masked, i + 1, 1) == ">") { i++; word = word substr(masked, i, 1) }
      if (word ~ /<<$/ && word !~ /<<</ && substr(masked, i + 1, 1) == "-") { i++; word = word "-" }
      print (start - 1) "\t" word "\n"; word = ""
      op_end = i + 1
    } else {
      if (word == "") start = i
      word = word ch
    }
  }
  if (word != "") print (start - 1) "\t" word "\n"
  # A body that starts at end of input (`cat <<EOF` with a trailing newline
  # and nothing after) has no byte for the loop to reach.
  while (m < hb_n) { print (hb_start[m] - 1) "\t<HD:" hb_len[m] ">\n"; m++ }

  # Integrity trailer. The hook checks this before trusting the stream: the
  # reassembled byte count must equal the length of the command it sent, which
  # catches any awk that strips, splits or reshapes bytes on the way through
  # and would otherwise desync every offset while still producing plausible
  # output. An exit status cannot stand in for it: an awk that reshapes bytes
  # still exits 0, and only a count carried in-band gives the hook something
  # to compare. `n+0` forces the numeric form of the count.
  print "\t<SCAN:" n+0 ">"
}
