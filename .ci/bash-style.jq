# Rule queries for .ci/check-bash-style, loaded as a jq module. This file is
# data: no shebang, no executable bit.
#
# Input is one `shfmt --to-json` tree. Each rule is a function that emits zero
# or more {line, rule, message} objects. `report` runs every rule, drops the
# hits an exception marker covers, and prints one line per remaining hit.
#
# Adding a rule: write the function, add its id to `rule_ids`, add it to
# `hits`. tests/bash-style.bats names every id, so an id is never renamed.

def rule_ids: ["function-keyword", "no-raw-tab", "quote-expansions", "single-quote-literals", "quote-literal-path", "quote-subst-in-assign", "unquoted-numeric-opt", "no-braces-in-arith", "quote-heredoc-terminator"];

def nodes: .. | objects;
def args: (.Args // []);
# The literal first word of a command, or "" when it is not a plain word.
def cmdname: (args[0].Parts[0].Value // "");
# Every line that carries a comment.
def comment_lines: [nodes | select(has("Hash")) | .Hash.Line] | unique;

# A function defined as `name() { ...; }`, without the `function` keyword.
def function_keyword:
  nodes
  | select(.Type == "FuncDecl" and .RsrvWord != true)
  | {
      line: .Pos.Line,
      rule: "function-keyword",
      message: ("define " + .Name.Value + " with the function keyword")
    };

# A raw tab anywhere in the source text, strings and heredoc bodies included.
def no_raw_tab($src):
  $src | split("\n") | to_entries[]
  | select(.value | contains("\t"))
  | {
      line: (.key + 1),
      rule: "no-raw-tab",
      message: "raw tab character; write $'\\t' or indent with spaces"
    };

# An expansion outside double quotes. Arithmetic, a C-style for header
# included, is exempt (the shell does no splitting there), as are the integer
# specials, a subscript inside another expansion, a heredoc body, and the
# right-hand side of =~, == and != in [[ ]], where quoting would turn a regex
# or a glob into a literal. A command or process substitution starts a fresh
# context: only the ancestors nearer than the nearest one count.
def quote_expansions:
  [
    paths(objects) as $p
    | getpath($p) as $n
    | select($n.Type == "ParamExp")
    | select(($n.Param.Value // "") | test("^[?#$!]$") | not)
    | [
        range(0; $p | length) as $i
        | getpath($p[:$i]) as $ancestor
        | select($ancestor | type == "object")
        | {type: ($ancestor.Type // ""), op: ($ancestor.Op // ""), key: $p[$i]}
      ] as $all
    | ($all | map(.type | IN("CmdSubst", "ProcSubst")) | rindex(true) // -1) as $reset
    | $all[($reset + 1):] as $up
    | select($up | any(.type | IN("DblQuoted", "ArithmExp", "ArithmCmd", "CStyleLoop", "ParamExp")) | not)
    | select($up | any(.key == "Hdoc") | not)
    | select($up | any(.type == "BinaryTest" and .key == "Y" and (.op | IN("=~", "==", "!="))) | not)
    | {
        line: $n.Pos.Line,
        rule: "quote-expansions",
        message: ("quote the expansion of " + ($n.Param.Value // "?"))
      }
  ]
  | .[];


# A double-quoted string holding only literal text. One that contains an
# apostrophe or a backslash is left alone: single quotes cannot hold the first
# and change the meaning of the second. A bats test name is not an argument.
def single_quote_literals:
  [nodes | select(.Type == "TestDecl") | .Description.Pos.Line] as $test_lines
  | nodes
  | select(.Type == "DblQuoted")
  | select((.Parts // []) | all(.Type == "Lit"))
  | ([.Parts[]?.Value] | join("")) as $text
  | select($text | test("['\\\\]") | not)
  | select(.Pos.Line as $l | $test_lines | index($l) | not)
  | {line: .Pos.Line, rule: "single-quote-literals", message: ("single-quote the literal " + ($text | tojson))};

# A bare word that is plainly a path, passed as a command argument. A redirect
# target is shell syntax and lives in Redirs, so it never reaches this rule. A
# path holding a glob character is left alone: quoting it would break the glob.
def quote_literal_path:
  nodes
  | select(.Type == "CallExpr")
  | args[1:][]
  | select((.Parts | length) == 1 and .Parts[0].Type == "Lit")
  | select(.Parts[0].Value | test("^(/|\\./|\\.\\./)"))
  | select(.Parts[0].Value | test("[*?\\[]") | not)
  | {line: .Pos.Line, rule: "quote-literal-path", message: ("single-quote the path " + .Parts[0].Value)};

# name=$(...) or name=$((...)) with no quotes around the substitution.
def quote_subst_in_assign:
  nodes
  | select(.Type == "CallExpr" or .Type == "DeclClause")
  | ((.Assigns // []) + (.Args // []))[]
  | objects
  | select(has("Name") and .Value != null)
  | select((.Value.Parts | length) == 1 and (.Value.Parts[0].Type | IN("ArithmExp", "CmdSubst")))
  | {line: .Pos.Line, rule: "quote-subst-in-assign", message: ("quote the substitution assigned to " + (.Name.Value // "?"))};

# --option='123': a numeric option value needs no quotes.
def unquoted_numeric_opt:
  nodes
  | select(.Type == "CallExpr")
  | args[]
  | select((.Parts | length) == 2 and .Parts[0].Type == "Lit" and .Parts[1].Type == "SglQuoted")
  | select((.Parts[0].Value | test("^--[a-z-]+=$")) and (.Parts[1].Value | test("^[0-9]+$")))
  | {line: .Pos.Line, rule: "unquoted-numeric-opt", message: ("drop the quotes in " + .Parts[0].Value + "'" + .Parts[1].Value + "'")};

# Names this file declares as associative arrays: their subscripts are strings.
def assoc_names:
  [
    nodes
    | select(.Type == "DeclClause")
    | select(any(args[]; (.Value.Parts[0].Value? // "") | test("^-[a-zA-Z]*A")))
    | args[]
    | .Name.Value? // empty
  ];

# A plain ${name} with nothing but the name inside it.
def plain_braced:
  .Type == "ParamExp" and has("Rbrace")
  and (has("Exp") or has("Repl") or has("Slice") or has("Index") or has("Length") or has("Excl") | not);

# ${name} inside $(( )), (( )) or an indexed-array subscript, where the bare
# name is enough. A command substitution in between resets to string context. A
# name right after a base prefix (10#${count}) keeps its braces: 10#count is not
# the base-10 value of $count.
def no_braces_in_arith:
  assoc_names as $assoc
  | [
      paths(objects) as $p
      | getpath($p) as $n
      | select($n | plain_braced)
      | select(
          ($p[-1] | type == "number" and . > 0)
          and (getpath($p[:-1])[$p[-1] - 1].Value? // "" | endswith("#"))
          | not
        )
      | [
          range(0; $p | length) as $i
          | getpath($p[:$i]) as $ancestor
          | select($ancestor | type == "object")
          | {type: ($ancestor.Type // ""), name: ($ancestor.Param.Value? // $ancestor.Name.Value? // ""), key: $p[$i]}
        ] as $up
      | ($up | map(.type) | rindex("CmdSubst") // -1) as $subst
      | (
          [
            $up | to_entries[]
            | select(
                (.value.type | IN("ArithmExp", "ArithmCmd", "CStyleLoop"))
                or (.value.key == "Index" and (.value.name as $name | $assoc | index($name) | not))
              )
            | .key
          ]
          | max // -1
        ) as $arith
      | select($arith > $subst)
      | {line: $n.Pos.Line, rule: "no-braces-in-arith", message: ("write " + ($n.Param.Value // "?") + " without ${} in arithmetic")}
    ]
  | .[];

# <<EOF over a body that expands nothing: quote the terminator. A terminator
# already quoted with a backslash is left alone, as is a body holding a
# backslash escape: quoting the terminator would change what the body prints.
def quote_heredoc_terminator:
  nodes
  | select(has("Redirs"))
  | .Redirs[]
  | select(.Op == "<<" or .Op == "<<-")
  | select((.Word.Parts | length) == 1 and .Word.Parts[0].Type == "Lit")
  | select(.Word.Parts[0].Value | contains("\\") | not)
  | select((.Hdoc.Parts // []) | all(.Type == "Lit"))
  | select([.Hdoc.Parts[]?.Value] | join("") | contains("\\") | not)
  | {line: .Pos.Line, rule: "quote-heredoc-terminator", message: ("quote the terminator: <<'" + .Word.Parts[0].Value + "'")};

def hits($src): function_keyword, no_raw_tab($src), quote_expansions, single_quote_literals, quote_literal_path, quote_subst_in_assign, unquoted_numeric_opt, no_braces_in_arith, quote_heredoc_terminator;

# Every comment that starts with `bash-style`, as a marker. A marker well formed
# as `# bash-style allow=<rule-id>: <reason>` carries its rule and reason; any
# other `bash-style` comment has `malformed: true`. A comment shfmt attached to
# a statement covers that statement's line span; a marker alone on the line
# above a statement is attached to that statement, so the span starts at the
# marker. A comment attached to nothing (after the last statement of a file or
# of a block) covers only its own line.
def markers:
  ([
    .. | objects
    | select(has("Comments") and has("End"))
    | .End.Line as $to
    | .Comments[]
    | {key: (.Hash.Line | tostring), value: $to}
  ] | from_entries) as $spans
  | [
    .. | objects
    | select(has("Hash") and has("Text"))
    | select(.Text | test("^ ?bash-style\\b"))
    | .Hash.Line as $line
    | ((.Text | capture("^ ?bash-style allow=(?<rule>[a-z0-9-]+): *(?<reason>.*)$")) // null) as $m
    | {
        line: $line,
        rule: ($m.rule // ""),
        reason: ($m.reason // ""),
        malformed: ($m == null),
        from: $line,
        to: ([($spans[$line | tostring] // $line), $line] | max)
      }
  ];

def report($path; $src):
  if .Type != "File" then error("not a shfmt syntax tree") else . end
  | markers as $markers
  | [hits($src)] as $hits
  | (
      $hits[]
      | . as $hit
      | select(
          [$markers[] | select(.rule == $hit.rule and .from <= $hit.line and $hit.line <= .to)]
          | length == 0
        )
    ),
    (
      $markers[]
      | . as $marker
      | if .malformed then
          {line, rule: "marker-malformed", message: "write # bash-style allow=<rule-id>: <reason>"}
        elif (.rule as $rule | rule_ids | index($rule)) == null then
          {line, rule: "marker-unknown-rule", message: ("no rule is named \"" + .rule + "\"")}
        elif .reason == "" then
          {line, rule: "marker-no-reason", message: "an exception marker must say why"}
        elif ([$hits[] | select(.rule == $marker.rule and $marker.from <= .line and .line <= $marker.to)] | length) == 0 then
          {line, rule: "marker-unused", message: ("nothing here violates " + .rule + "; remove the marker")}
        else
          empty
        end
    )
  | "FAIL: \($path):\(.line): [\(.rule)] \(.message)";
