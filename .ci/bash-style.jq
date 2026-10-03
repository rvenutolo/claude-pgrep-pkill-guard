# Rule queries for .ci/check-bash-style, loaded as a jq module. This file is
# data: no shebang, no executable bit.
#
# Input is one `shfmt --to-json` tree. Each rule is a function that emits zero
# or more {line, rule, message} objects. `report` runs every rule, drops the
# hits an exception marker covers, and prints one line per remaining hit.
#
# Adding a rule: write the function, add its id to `rule_ids`, add it to
# `hits`. tests/bash-style.bats names every id, so an id is never renamed.

def rule_ids: ["function-keyword", "no-raw-tab"];

# A function defined as `name() { ...; }`, without the `function` keyword.
def function_keyword:
  .. | objects
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

def hits($src): function_keyword, no_raw_tab($src);

# Every `# bash-style allow=<rule-id>: <reason>` comment, with the line span of
# the statement shfmt attached it to. A marker alone on the line above a
# statement is attached to that statement, so the span starts at the marker.
def markers:
  [
    .. | objects
    | select(has("Comments") and has("Pos") and has("End"))
    | .End.Line as $to
    | .Comments[]
    | select((.Text // "") | test("^ ?bash-style "))
    | ((.Text | capture("^ ?bash-style allow=(?<rule>[a-z0-9-]*):? *(?<reason>.*)$"))
        // {rule: "", reason: ""}) as $m
    | {line: .Hash.Line, rule: $m.rule, reason: $m.reason, from: .Hash.Line, to: ([$to, .Hash.Line] | max)}
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
      | if (.rule as $rule | rule_ids | index($rule)) == null then
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
