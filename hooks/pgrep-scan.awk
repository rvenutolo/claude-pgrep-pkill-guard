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
# A heredoc body is text the shell feeds to a command, not code (#184). Its
# bytes are masked from the newline after the `<<` line to the terminator
# line, which is masked too. A quoted delimiter (`<<'EOF'`, `<<"EOF"`,
# `<<\EOF`) masks everything; an unquoted one masks like a double-quoted
# string, so `$(` and backticks still re-enter code context. One body is
# emitted to the tokenizer as a `<HD:len>` marker at its first byte, which is
# how the hook slices a body fed to a local shell wrapper.
BEGIN { RS = "\0"; ORS = "" }
{
  cmd = $0
  n = length(cmd)
  total += n          # accumulated for the integrity trailer emitted in END
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
        # A body line ending in a backslash is not a continuation here -- the
        # heredoc body is literal text, so the backslash is an ordinary byte.
        # Masking it together with a following newline would swallow that
        # newline, which is what starts the terminator check on the next
        # line; leave the newline for the ch == "\n" branch above to see.
        if (ch == "\\" && substr(cmd, i + 1, 1) != "\n") { masked = masked "\001\001"; i += 2; continue }
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
      # position and the guard denies a command bash never runs (#155 entry 7).
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
      # A bare `(` nests one more arithmetic level whenever it is the second
      # paren of a `((` open (the arithmetic command form, or the inner one
      # of `$((`) or it appears anywhere inside an already-open arithmetic
      # level -- an explicit grouping paren like `(1)` inside `$(( (1)<<2 ))`
      # must push and pop in step with the surrounding `))`, or its `)`
      # closes the outer level early and strands the rest of the arithmetic
      # at depth 0, where a `<<` in it reads as a heredoc operator.
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
              # An unterminated quote ends the delimiter word at end of input.
              # Without the break the word loop runs on past the newline and
              # glues the next line's bytes onto the delimiter, so `cat <<E'`
              # would look for a terminator named `Ex` rather than `E`.
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
          # the terminator check below handles a zero-length delimiter on its
          # own -- `substr(cmd, j, 0)` is "", so the suffix clause is what
          # decides, and it demands a newline right there. Left unqueued the
          # body was scanned as code, and an apostrophe in it ("it's") flipped
          # quote parity for everything after, hiding a real command.
          # No delimiter word at all (`cat <<`, `cat <<;`) is a bash syntax
          # error, so nothing is enqueued for it and the rest stays code.
          if (delim != "" || quoted) {
            pq_delim[pq_tail] = delim; pq_quoted[pq_tail] = quoted; pq_strip[pq_tail] = strip; pq_tail++
          }
          masked = masked "<<"; i += 2
          continue
        }
      }

      if (ch == "'") { ctx[depth] = "S"; out = "\001" }
      else if (ch == "\"") { ctx[depth] = "D"; out = "\001" }
      else if (ch == "\\") {
        # A backslash-newline is a line continuation: bash removes it outright,
        # so the words on either side are separate. Two spaces keep the byte
        # offsets aligned -- the bracket mitigation slices the raw command by
        # them -- while making it a real token delimiter, which filler is not.
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
  word = ""; start = 0; m = 0
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
    } else {
      if (word == "") start = i
      word = word ch
    }
  }
  if (word != "") print (start - 1) "\t" word "\n"
  # A body that starts at end of input (`cat <<EOF` with a trailing newline
  # and nothing after) has no byte for the loop to reach.
  while (m < hb_n) { print (hb_start[m] - 1) "\t<HD:" hb_len[m] ">\n"; m++ }
}

# Integrity trailer. The hook checks this before trusting the stream. It catches
# an awk whose RS handling differs from ours -- notably BWK awk on macOS, whose
# C-string semantics truncate RS="\0" to RS="" and silently switch the program
# into paragraph mode, which desyncs every byte offset while still producing
# plausible-looking output. NR proves we saw exactly one record; total proves no
# bytes were stripped. Do NOT replace this with `exit 1`: the hook calls the
# scanner inside a command substitution, so a non-zero exit is swallowed by the
# ERR trap and turns into a silent allow. `total+0` is not decoration either --
# an unset awk variable concatenates as the empty string, so a bare `total`
# would emit `<SCAN:0:>` for empty input and never match the expected trailer.
END { print "\t<SCAN:" NR ":" total+0 ">" }
