# Rule queries for .ci/check-bash-style, loaded as a jq module. This file is
# data: no shebang, no executable bit.
#
# Input is one `shfmt --to-json` tree. Each rule is a function that emits zero
# or more {line, rule, message} objects. `report` runs every rule, drops the
# hits an exception marker covers, and prints one line per remaining hit.
#
# Adding a rule: write the function, add its id to `rule_ids`, add it to
# `hits`. tests/bash-style.bats names every id, so an id is never renamed.

def rule_ids: ["function-keyword", "no-raw-tab", "quote-expansions"];

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
# or a glob into a literal.
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
      ] as $up
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


def hits($src): function_keyword, no_raw_tab($src), quote_expansions;

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
