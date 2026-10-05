# Rule queries for .ci/check-bash-style, loaded as a jq module. This file is
# data: no shebang, no executable bit.
#
# Input is one `shfmt --to-json` tree. Each rule is a function that emits zero
# or more {line, rule, message} objects. Besides the tree, `report` and `hits`
# receive the file's display path, its source text, whether the file is
# sourced or executed, the repository's tracked paths, the namespaced function
# names defined anywhere and the function names the test helpers define; a rule
# takes the ones it needs as parameters. `report` runs every rule, drops the
# hits an exception marker covers, and prints one line per remaining hit.
#
# Adding a rule: write the function, add its id to `rule_ids`, add it to
# `hits`. tests/bash-style.bats names every id, so an id is never renamed.

def rule_ids: ["function-keyword", "no-raw-tab", "quote-expansions", "single-quote-literals", "quote-literal-path", "quote-subst-in-assign", "unquoted-numeric-opt", "no-braces-in-arith", "quote-heredoc-terminator", "long-options", "double-dash-before-paths", "xargs-flags", "no-echo-e", "fetch-flags", "test-double-equals", "empty-string-test", "no-lexical-compare", "no-one-line-case", "no-fallthrough", "explicit-for-in", "no-for-in-subst", "no-pipe-while", "source-not-dot", "no-let-expr", "no-alias", "bare-arith-stmt", "blank-fallback-comment", "shellcheck-disable-justified", "no-subst-or-exit", "eval-comment", "main-last", "functions-grouped", "strict-prologue", "no-default-wellknown-env", "max-line-length", "shdoc-present", "shdoc-arg-positions", "shdoc-arg-name", "shdoc-set", "shdoc-stderr", "comment-line-ref", "comment-untracked-ref", "comment-missing-path", "comment-missing-function", "comment-commit-relative", "todo-form", "mktemp-exit-trap"];

def nodes: .. | objects;
def args: (.Args // []);
# The leading literal text of a command's first word, or "" when the word
# starts with an expansion or a double-quoted string.
def cmdname: (args[0].Parts[0].Value // "");
# Every line that carries a comment.
def comment_lines: [nodes | select(has("Hash")) | .Hash.Line] | unique;
# Every comment as {line, text}; the text starts after the `#`.
def comments: nodes | select(has("Hash")) | {line: .Hash.Line, text: (.Text // "")};

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

# Commands that run another command: the flags after them belong to that one.
def wrappers: ["run", "env", "command", "builtin", "timeout", "nice", "sudo", "exec"];

# Short flags that take the next word as their value, per wrapper. A flag a
# wrapper does not list takes none (sudo -n, command -p, bats run -N).
def wrapper_value_flags: {
  "nice": ["-n"],
  "env": ["-u", "-C", "-S"],
  "timeout": ["-k", "-s"],
  "sudo": ["-u", "-g", "-C", "-D", "-h", "-p", "-R", "-T", "-U"],
  "exec": ["-a"]
};

# A command's words with leading wrappers removed, along with the wrappers'
# own options, the values those options take, VAR=value words and durations, so
# the first word left is the tool that reads the flags. A first word that
# starts with an expansion (a variable holding a path) is kept and reads as "".
def real_words:
  args as $w
  | {i: 0, wrapper: "", done: false}
  | until(
      .done or .i >= ($w | length);
      .wrapper as $wrapper
      | ($w[.i].Parts[0].Value // "") as $v
      | (if .i > 0 then $w[.i - 1].Parts[0].Value // "" else "" end) as $prev
      | (((wrapper_value_flags[$wrapper] // []) | index($prev)) != null) as $is_value
      | (
          $w[.i].Parts[0].Type == "Lit" and (wrappers | index($v)) != null
        ) as $is_wrapper
      | if $is_value or $is_wrapper
          or ($w[.i].Parts[0].Type == "Lit" and ($v | test("^-|=|^[0-9]+[smhd]?$")))
        then .i += 1 | (if $is_wrapper and ($is_value | not) then .wrapper = $v else . end)
        else .done = true
        end
    )
  | $w[.i:];

# A bare word that is plainly a path, passed as a command argument. A redirect
# target is shell syntax and lives in Redirs, so it never reaches this rule. A
# path holding a glob character is left alone: quoting it would break the glob.
# The command word is not an argument, wherever it sits: in `run timeout 5
# ./tool`, the path is the command the wrappers run.
def quote_literal_path:
  nodes
  | select(.Type == "CallExpr")
  | real_words[0] as $command
  | args[1:][]
  | select(. != $command)
  | select((.Parts | length) == 1 and .Parts[0].Type == "Lit")
  | select(.Parts[0].Value | test("^(/|\\./|\\.\\./)"))
  | select(.Parts[0].Value | test("[*?\\[]") | not)
  | {line: .Pos.Line, rule: "quote-literal-path", message: ("single-quote the path " + .Parts[0].Value)};

# Short flags allowed in every file: the tool has no long form, or none that
# every platform's build accepts. "*" allows every flag: shell builtins, and
# tools whose whole option syntax is single-dash.
def no_long_form: {
  "set": "*", "shopt": "*", "read": "*", "mapfile": "*", "printf": "*",
  "unset": "*", "type": "*", "export": "*", "cd": "*", "pwd": "*", "kill": "*",
  "wait": "*", "echo": "*", "trap": "*", "return": "*", "exit": "*",
  "find": "*", "magick": "*", "test": "*", "[": "*", "hash": "*", "alias": "*",
  "unalias": "*", "getopts": "*", "let": "*", "source": "*", "eval": "*",
  "umask": "*", "ulimit": "*", "pushd": "*", "popd": "*", "readarray": "*",
  "compgen": "*", "complete": "*", "compopt": "*", "jobs": "*", "bind": "*",
  "enable": "*", "disown": "*", "fg": "*", "bg": "*", "history": "*",
  "caller": "*", "dirs": "*", "fc": "*", "help": "*", "logout": "*",
  "suspend": "*", "times": "*", "typeset": "*", "shift": "*", "break": "*",
  "continue": "*", "true": "*", "false": "*", ":": "*", ".": "*", "time": "*",
  "bash": ["-c"], "sh": ["-c"],
  "git": ["-C", "-c", "-I", "-z", "-e"],
  "awk": ["-f", "-v"],
  "sysctl": ["-n"],
  "chmod": ["-x", "-w", "-r"],
  "sed": ["-i.bak"]
};

# Whether the gate treats a file as running against ambient tools, which on
# macOS are the BSD ones: everything under hooks/ and tests/. A line elsewhere
# that runs on the ambient legs takes an exception marker.
def is_ambient($path): $path | test("(^|/)(hooks|tests)/");

# Short flags the macOS (BSD) tool has no long form for. Allowed only where
# is_ambient holds.
def macos_short: {
  "mkdir": ["-p", "-m"], "rm": ["-f"], "mv": ["-f"], "cp": ["-R"],
  "ln": ["-s"], "wc": ["-l", "-c"], "tr": ["-d", "-s"], "uname": ["-s"],
  "sed": ["-e"], "head": ["-n"], "mktemp": ["-u"],
  "xargs": ["-0", "-n", "-r", "-I"]
};

# A short flag on a tool that has a long form. Flags after a -- are data, as
# are flags given to a function the file defines, to a function the test
# helpers define ($helpers) or to a command held in a variable: each is input
# for the thing under test. A negative number is an argument, except to head
# and tail, where -5 is a legacy spelling of --lines=5.
def long_options($path; $helpers):
  ([nodes | select(.Type == "FuncDecl") | .Name.Value] + $helpers) as $functions
  | is_ambient($path) as $ambient
  | nodes
  | select(.Type == "CallExpr")
  | real_words as $w
  | ($w[0].Parts[0].Value // "") as $cmd
  | select($cmd != "" and ($functions | index($cmd) | not))
  | (no_long_form[$cmd] // []) as $always
  | select($always != "*")
  | (if $ambient then (macos_short[$cmd] // []) else [] end) as $scoped
  | ($w[1:] | (map(.Parts[0].Value // "") | index("--")) as $end | if $end == null then . else .[:$end] end)[]
  | select((.Parts | length) == 1 and .Parts[0].Type == "Lit")
  | .Parts[0].Value as $flag
  | select($flag | test("^-[A-Za-z0-9]"))
  | select(($flag | test("^-[0-9]+(\\.[0-9]+)?$") | not) or ($cmd | IN("head", "tail")))
  | select(($always + $scoped) | index($flag) | not)
  | {line: .Pos.Line, rule: "long-options", message: ("use the long form of " + $cmd + " " + $flag)};

# rm, mv and cp take -- before their paths, every time.
def double_dash_before_paths:
  nodes
  | select(.Type == "CallExpr")
  | real_words as $w
  | ($w[0].Parts[0].Value // "") as $cmd
  | select($cmd | IN("rm", "mv", "cp"))
  | select([$w[1:][] | .Parts[0].Value // ""] | index("--") | not)
  | {line: .Pos.Line, rule: "double-dash-before-paths", message: ("put -- before the paths given to " + $cmd)};

# xargs always carries --no-run-if-empty and an explicit --max-args. Not where
# is_ambient holds: BSD xargs has neither long option, so demanding them there
# would demand a line that fails on macOS.
def xargs_flags($path):
  select(is_ambient($path) | not)
  | nodes
  | select(.Type == "CallExpr")
  | real_words as $w
  | select(($w[0].Parts[0].Value // "") == "xargs")
  | [$w[1:][] | .Parts[0].Value // ""] as $flags
  | select((($flags | index("--no-run-if-empty")) == null) or ($flags | any(test("^--max-args=")) | not))
  | {line: .Pos.Line, rule: "xargs-flags", message: "xargs needs --no-run-if-empty and --max-args=N"};

# echo -e is never portable; printf does the job. Every leading option word
# counts, so echo -n -e is caught as well as echo -ne.
def no_echo_e:
  nodes
  | select(.Type == "CallExpr" and cmdname == "echo")
  | select(
      [
        foreach (args[1:][] | .Parts[0].Value // "") as $word (
          true;
          . and ($word | test("^-[a-zA-Z]+$"));
          if . then $word else empty end
        )
      ]
      | any(test("e"))
    )
  | {line: .Pos.Line, rule: "no-echo-e", message: "use printf with a format string, not echo -e"};

# Non-interactive curl and wget ignore the invoking user's config files. A
# `command -v curl` lookup fetches nothing and is left alone.
def fetch_flags:
  nodes
  | select(.Type == "CallExpr")
  | select(([args[1:][] | .Parts[0].Value // ""] | any(IN("-v", "-V"))) and cmdname == "command" | not)
  | real_words as $w
  | ($w[0].Parts[0].Value // "") as $cmd
  | [$w[1:][] | .Parts[0].Value // ""] as $flags
  | (
      if $cmd == "curl" then ["--disable", "--fail", "--silent", "--location", "--show-error"]
      elif $cmd == "wget" then ["--no-config"]
      else []
      end
    ) as $need
  | ($need - $flags) as $missing
  | select(($missing | length) > 0)
  | {line: .Pos.Line, rule: "fetch-flags", message: ($cmd + " is missing " + ($missing | join(" ")))};

# [[ a = b ]]: write ==.
def test_double_equals:
  nodes
  | select(.Type == "BinaryTest" and .Op == "=")
  | {line: .Pos.Line, rule: "test-double-equals", message: "use == for equality inside [[ ]]"};

# A word that is exactly '' or "".
def is_empty_word:
  (.Parts // []) as $parts
  | ($parts | length) == 1
    and ($parts[0].Type | IN("SglQuoted", "DblQuoted"))
    and (($parts[0].Value // "") == "")
    and (($parts[0].Parts // []) | length) == 0;

# [[ "${x}" == '' ]], on either side: write -z or -n.
def empty_string_test:
  nodes
  | select(.Type == "BinaryTest" and (.Op | IN("==", "!=", "=")))
  | select((.X | is_empty_word) or (.Y | is_empty_word))
  | {line: .Pos.Line, rule: "empty-string-test", message: "test emptiness with -z or -n"};

# < and > inside [[ ]] compare strings, not numbers.
def no_lexical_compare:
  nodes
  | select(.Type == "BinaryTest" and (.Op == "<" or .Op == ">"))
  | {line: .Pos.Line, rule: "no-lexical-compare", message: ("use (( )) for a numeric comparison, not " + .Op + " in [[ ]]")};

# case ... esac squeezed onto one line.
def no_one_line_case:
  nodes
  | select(.Type == "CaseClause" and .Pos.Line == .End.Line)
  | {line: .Pos.Line, rule: "no-one-line-case", message: "expand the case, or write the single test as [[ ]]"};

# ;& and ;;& fall through.
def no_fallthrough:
  nodes
  | select(.Type == "CaseClause")
  | (.Items // [])[]
  | select(.Op != ";;")
  | {line: .Pos.Line, rule: "no-fallthrough", message: ("write explicit cases, not " + .Op)};

# for x; do: say what is iterated.
def explicit_for_in:
  nodes
  | select(.Type == "ForClause")
  | .Loop
  | select(.Type == "WordIter" and (has("InPos") | not))
  | {line: .Pos.Line, rule: "explicit-for-in", message: "write for x in \"$@\""};

# for x in $(cmd), alone or among other words: the output is word-split. Read
# it into an array with mapfile. A quoted "$(cmd)" is one word and is left
# alone.
def no_for_in_subst:
  nodes
  | select(.Type == "ForClause")
  | .Loop
  | select(.Type == "WordIter")
  | (.Items // [])[]
  | select((.Parts // []) | any(.Type == "CmdSubst"))
  | {line: .Pos.Line, rule: "no-for-in-subst", message: "iterate command output with mapfile -t, not for x in $(...)"};

# cmd | while ...: the loop runs in a subshell and loses its assignments. A
# loop wrapped in { } or ( ) on the right of the pipe is the same loop.
def no_pipe_while:
  nodes
  | select(.Type == "BinaryCmd" and (.Op == "|" or .Op == "|&"))
  | select(
      .Y.Cmd.Type == "WhileClause"
      or (.Y.Cmd.Type | IN("Block", "Subshell")) and any(.Y.Cmd.Stmts[]?; .Cmd.Type == "WhileClause")
    )
  | {line: .Y.Pos.Line, rule: "no-pipe-while", message: "feed the loop with < <(cmd), not a pipe"};

# The leading literal text of a command's first word once leading wrappers are
# removed, or "" when the word starts with an expansion or a double-quoted
# string, or the command only looks the name up (`command -v name` runs
# nothing).
def real_cmdname:
  if cmdname == "command" and ([args[1:][] | .Parts[0].Value // ""] | any(IN("-v", "-V")))
  then ""
  else (real_words[0].Parts[0].Value // "")
  end;

# `. file`: write source.
def source_not_dot:
  nodes
  | select(.Type == "CallExpr" and real_cmdname == ".")
  | {line: .Pos.Line, rule: "source-not-dot", message: "use source, not ."};

# let and expr: write (( )).
def no_let_expr:
  nodes
  | select(.Type == "LetClause" or (.Type == "CallExpr" and (real_cmdname | IN("let", "expr"))))
  | {line: .Pos.Line, rule: "no-let-expr", message: "use (( )) for arithmetic"};

# alias: write a function.
def no_alias:
  nodes
  | select(.Type == "CallExpr" and real_cmdname == "alias")
  | {line: .Pos.Line, rule: "no-alias", message: "define a function, not an alias"};

# (( expr )) as a whole statement, in any body: exit status 1 when the value is
# zero. A condition (if, elif, while, until) is left alone, and so is the left
# side of && and ||: neither trips errexit, and neither does a negated or a
# background statement.
def bare_arith_stmt:
  nodes
  | [.Stmts?, .Then?, .Do?][]
  | arrays
  | .[]
  | select(.Cmd.Type == "ArithmCmd" and ((.Negated // false) | not) and ((.Background // false) | not))
  | {line: .Pos.Line, rule: "bare-arith-stmt", message: "a bare (( )) fails under set -e when it evaluates to zero"};

# An assignment of nothing: `name=`, `name=''`, `name=""` or `name=()`.
def is_empty_assign:
  if has("Array") then ((.Array.Elems // []) | length) == 0
  else (.Value // {}) | (has("Parts") | not) or is_empty_word
  end;

# || true, || :, || var=, || var='' and || printf '' swallow a failure without
# naming it: they need a reason on the same line. A fallback that substitutes a
# named sentinel is its own explanation.
def blank_fallback_comment:
  comment_lines as $commented
  | nodes
  | select(.Type == "BinaryCmd" and .Op == "||")
  | select(.Y.Cmd.Type == "CallExpr")
  | (.Y.Cmd | real_words) as $w
  | (.Y.Cmd.Assigns // []) as $assigns
  | ($w[0].Parts[0].Value // "") as $cmd
  | select(
      ($cmd | IN("true", ":"))
      or ($cmd == "" and ($w | length) == 0 and ($assigns | length) == 1 and ($assigns[0] | is_empty_assign))
      or ($cmd == "printf" and ($w[1] | is_empty_word))
    )
  | select(.Y.Pos.Line as $l | $commented | index($l) | not)
  | {line: .Y.Pos.Line, rule: "blank-fallback-comment", message: "say on this line why the failure is ignored"};

# A shellcheck directive that disables a check, alone or combined with others
# (`source=... disable=...`), needs `# reason` after it.
def shellcheck_disable_justified:
  nodes
  | select(has("Hash") and has("Text"))
  | select(.Text | test("^ *shellcheck +([^# ]+ +)*disable="))
  | select(.Text | test("^ *shellcheck [^#]*# *\\S") | not)
  | {line: .Hash.Line, rule: "shellcheck-disable-justified", message: "add `# reason` after the disable directive"};

# var="$(cmd)" || exit N: strict mode already stops, and the ERR trap says where.
def no_subst_or_exit:
  nodes
  | select(.Type == "BinaryCmd" and .Op == "||")
  | select(
      .X.Cmd.Type == "CallExpr"
      and ((.X.Cmd | args) | length) == 0
      and any(.X.Cmd.Assigns[]?; any(.Value | nodes; .Type == "CmdSubst"))
    )
  | select(.Y.Cmd.Type == "CallExpr" and (.Y.Cmd | real_cmdname) == "exit")
  | {line: .Pos.Line, rule: "no-subst-or-exit", message: "drop || exit; strict mode and the ERR trap handle the failure"};

# eval with no comment on its line or the line above.
def eval_comment:
  comment_lines as $commented
  | nodes
  | select(.Type == "CallExpr" and real_cmdname == "eval")
  | .Pos.Line as $l
  | select((($commented | index($l)) == null) and (($commented | index($l - 1)) == null))
  | {line: $l, rule: "eval-comment", message: "justify the eval in a comment"};

# The top-level statements of the file, in order.
def top: (.Stmts // []);

# `@` expanded whole: no default, replacement, slice, length or indirection.
def plain_all_args:
  .Type == "ParamExp" and .Param.Value == "@"
  and (has("Exp") or has("Repl") or has("Slice") or has("Index") or has("Length") or has("Excl") | not);

# A statement that is exactly `main "$@"`. A negated or backgrounded call does
# not leave main's status as the script's, so neither is that statement.
def is_main_call:
  ((.Negated // false) | not)
  and ((.Background // false) | not)
  and .Cmd.Type == "CallExpr"
  and (.Cmd | cmdname) == "main"
  and ((.Cmd | args) | length) == 2
  and (.Cmd.Args[1].Parts | length) == 1
  and .Cmd.Args[1].Parts[0].Type == "DblQuoted"
  and ((.Cmd.Args[1].Parts[0].Parts // []) | length) == 1
  and (.Cmd.Args[1].Parts[0].Parts[0] | plain_all_args);

# An executed script that defines a function at top level: main is the last
# function, and `main "$@"` is the last statement.
def main_last($sourced):
  select($sourced | not)
  | [top[] | select(.Cmd.Type == "FuncDecl")] as $functions
  | select(($functions | length) > 0)
  | (top | last) as $last
  | (
      select($functions | last | .Cmd.Name.Value != "main")
      | {line: ($functions | last | .Pos.Line), rule: "main-last", message: "main is the last function defined"}
    ),
    (
      select($last | is_main_call | not)
      | {line: $last.Pos.Line, rule: "main-last", message: "the last statement is main \"$@\""}
    );

# Between the first function and the last, an executed script holds nothing
# but function definitions.
def functions_grouped($sourced):
  select($sourced | not)
  | [top | to_entries[] | select(.value.Cmd.Type == "FuncDecl") | .key] as $at
  | select(($at | length) > 1)
  | top[($at | first):($at | last)][]
  | select(.Cmd.Type != "FuncDecl")
  | {line: .Pos.Line, rule: "functions-grouped", message: "move this statement above the first function or below the last"};

# `set -Eeuo pipefail`, whole.
def is_strict_pragma:
  .Type == "CallExpr"
  and cmdname == "set"
  and ([args[1:][] | .Parts[0].Value // ""] == ["-Eeuo", "pipefail"]);

# A command that only assigns IFS: `IFS=...`, or `readonly IFS=...` and the
# like. `IFS=... read` sets it for one command and does not count.
def is_ifs_assignment:
  (.Type == "CallExpr" and (args | length) == 0 and any(.Assigns[]?; .Name.Value == "IFS"))
  or (.Type == "DeclClause" and any(args[]; .Name.Value? == "IFS"));

# An executed script sets strict mode and then assigns IFS, to any value, both
# before its first function.
def strict_prologue($sourced):
  select($sourced | not)
  | top as $stmts
  | select(($stmts | length) > 0)
  | ([$stmts | to_entries[] | select(.value.Cmd.Type == "FuncDecl") | .key] | first // ($stmts | length)) as $first_function
  | [$stmts[:$first_function][] | .Cmd] as $head
  | ([$head | to_entries[] | select(.value | is_strict_pragma) | .key] | first) as $set
  | ([$head | to_entries[] | select(.value | is_ifs_assignment) | .key] | first) as $ifs
  | if $set == null then
      {line: 1, rule: "strict-prologue", message: "set -Eeuo pipefail before the first function"}
    elif $ifs == null or $ifs < $set then
      {line: $stmts[$set].Pos.Line, rule: "strict-prologue", message: "IFS=$'\\n\\t' after set -Eeuo pipefail, before the first function"}
    else
      empty
    end;

# ${HOME:-...}: a well-known environment variable gets no default, however the
# default is spelled.
def no_default_wellknown_env:
  nodes
  | select(.Type == "ParamExp" and ((.Exp.Op // "") | IN(":-", "-", ":=", "=")))
  | select((.Param.Value // "") | IN("HOME", "USER", "PATH", "SHELL", "PWD", "SDKMAN_DIR"))
  | {line: .Pos.Line, rule: "no-default-wellknown-env", message: ("no default for " + .Param.Value + "; let set -u catch it")};

# A line over 120 characters. A line is excused when exactly one quoted string
# or unbroken word on it is 100 characters or more: that literal nearly fills a
# continuation line by itself, so wrapping gains little. A quoted string
# counts wherever it starts in a word, so name='...' and --opt='...' are one
# literal. Two such literals can each take a line, so those lines are reported.
# A comment line has no quoted strings, only words: one URL it cannot wrap
# excuses it, a long comment of ordinary words does not. Marker text does not
# count.
def max_line_length($src):
  $src | split("\n") | to_entries[]
  | (.value | sub(" ?# bash-style allow=.*$"; "")) as $text
  | ($text | length) as $len
  | select($len > 120)
  | ($text | test("^\\s*#")) as $comment
  | (if $comment then "[^ ]+" else "(?:'[^']*'|\"[^\"]*\"|[^ '\"]|['\"])+" end) as $token
  | ([$text | match($token; "g") | .string | length | select(. >= 100)] | length) as $literals
  | select($literals != 1)
  | {line: (.key + 1), rule: "max-line-length", message: ("\($len) characters; the limit is 120")};

# The functions bats itself calls, with no arguments. The shdoc rules do not
# require a block above them.
def bats_hooks: ["setup", "teardown", "setup_file", "teardown_file"];

# The comment lines that end on the line directly above $line, each directly
# above the next. shfmt attaches every comment since the previous statement to
# the next one, so a file header separated from a function by a blank line
# arrives in the same list and must not count as that function's shdoc.
def contiguous_comments($line):
  [
    foreach (reverse | .[]) as $comment (
      {want: ($line - 1), keep: true};
      if .keep and $comment.Hash.Line == .want then
        {want: (.want - 1), keep: true, comment: $comment}
      else
        {keep: false}
      end;
      select(.keep) | .comment
    )
  ]
  | reverse;

# Every function with the comment block directly above it:
# {name, line, doc: [comment texts], body}. main and the bats hooks are left
# out: a script's contract is its file header, not a block above main.
def documented_functions:
  nodes
  | select(has("Cmd") and .Cmd.Type == "FuncDecl")
  | select(.Cmd.Name.Value as $name | (["main"] + bats_hooks) | index($name) | not)
  | .Cmd.Pos.Line as $line
  | {
      name: .Cmd.Name.Value,
      line: $line,
      doc: [((.Comments // []) | contiguous_comments($line))[] | .Text // ""],
      body: .Cmd.Body
    };

# A function other than main and the bats hooks carries @description, and @arg
# or @noargs.
def shdoc_present:
  documented_functions
  | (.doc | any(test("^ *@description\\b"))) as $described
  | (.doc | any(test("^ *@(arg|noargs)\\b"))) as $argued
  | select(($described and $argued) | not)
  | {
      line,
      rule: "shdoc-present",
      message: (.name + " needs " + (if $described then "@arg or @noargs" else "@description" end))
    };

# The positional numbers a doc block documents with `@arg $N`, as strings,
# plus "@" when it has `@arg $@`.
def doc_positions: [.doc[] | capture("^ *@arg \\$(?<n>[0-9]+|@)") | .n] | unique;

# Every object under a node, without descending into a node whose Type is in
# $skip.
def scoped_nodes($skip):
  if type == "object" then
    ., (if (.Type // "") | IN($skip[]) then empty else .[] | scoped_nodes($skip) end)
  elif type == "array" then
    .[] | scoped_nodes($skip)
  else
    empty
  end;

# Every object under a node, leaving out the bodies of nested functions: their
# positionals are their own.
def own_nodes: scoped_nodes(["FuncDecl"]);

# Like own_nodes, and also leaving out subshells and substitutions: they run in
# a child process, so what they assign never reaches the caller's globals.
def global_nodes: scoped_nodes(["FuncDecl", "Subshell", "CmdSubst", "ProcSubst"]);

# The positionals a body reads, as strings: the numbers, "@" for $@ and $*, and
# "#" for $#.
def body_positions:
  [
    .body | own_nodes
    | select(.Type == "ParamExp")
    | (.Param.Value // "")
    | select(test("^([1-9][0-9]*|[@*#])$"))
    | if . == "*" then "@" else . end
  ]
  | unique;

# The @arg lines name exactly the positionals the body reads. `$@` documents a
# variadic function, which walks its arguments with `$1` and `shift` or only
# counts them with `$#`; such a block is wrong only when the body reads no
# positional at all. `$#` alone never names a numbered `@arg`.
def shdoc_arg_positions:
  documented_functions
  | select(.doc | any(test("^ *@(arg|noargs)\\b")))
  | doc_positions as $doc
  | body_positions as $read
  | ($read - ["#"]) as $body
  | select(
      if ($doc | index("@")) != null then
        ($read | length) == 0
      else
        $doc != $body
      end
    )
  | {
      line,
      rule: "shdoc-arg-positions",
      message: (.name + " documents [" + ($doc | join(" ")) + "] and reads [" + ($body | join(" ")) + "]")
    };

# The number N when a word is exactly "$N", "${N}", "${N:-default}" or
# "${N-default}": a positional bound whole, not transformed.
def bound_positional:
  ((.Parts // []) | select(length == 1) | .[0]) as $part
  | ($part | if .Type == "DblQuoted" then ((.Parts // []) | select(length == 1) | .[0]) else . end) as $value
  | select($value.Type == "ParamExp")
  | select(($value | has("Index") or has("Slice") or has("Repl") or has("Length") or has("Excl")) | not)
  | select(($value.Exp.Op // ":-") | IN(":-", "-"))
  | ($value.Param.Value // "")
  | select(test("^[1-9][0-9]*$"));

# A local is named for the `@arg $N name` line that documents its position. A
# nameref (`local -n`) may differ, wherever the function assigns it.
def shdoc_arg_name:
  documented_functions
  | . as $fn
  | ([.doc[] | capture("^ *@arg \\$(?<n>[0-9]+) +(?<name>[A-Za-z_][A-Za-z0-9_]*)")] | map({(.n): .name}) | add // {}) as $names
  | .body as $body
  | [
      $body | own_nodes
      | select(.Type == "DeclClause" and any(args[]; (.Value.Parts[0].Value? // "") | test("^-[a-zA-Z]*n")))
      | args[] | .Name.Value? // empty
    ] as $namerefs
  | $body | own_nodes
  | (
      select(.Type == "DeclClause")
      | select(any(args[]; (.Value.Parts[0].Value? // "") | test("^-[a-zA-Z]*n")) | not)
      | args[]
      | select(has("Name") and .Value != null)
    ),
    (
      select(.Type == "CallExpr" and (args | length) == 0)
      | (.Assigns // [])[]
      | select(has("Name") and .Value != null)
    )
  | . as $bind
  | (.Value | bound_positional) as $n
  | select($names[$n] != null and $names[$n] != $bind.Name.Value and ($namerefs | index($bind.Name.Value) | not))
  | {
      line: $bind.Pos.Line,
      rule: "shdoc-arg-name",
      message: ($fn.name + " binds $" + $n + " to " + $bind.Name.Value + " but documents it as " + $names[$n])
    };

# A DeclClause that sets a global: readonly, export, or declare/typeset -g.
def declares_global:
  .Variant.Value as $variant
  | ($variant | IN("readonly", "export"))
    or (
      ($variant | IN("declare", "typeset"))
      and any(args[]; (.Value.Parts[0].Value? // "") | test("^-[a-zA-Z]*g"))
    );

# The names a function's own body declares with local or declare/typeset.
def declared_names:
  [
    own_nodes
    | select(.Type == "DeclClause" and (declares_global | not))
    | args[] | .Name.Value? // empty
  ];

# Names the shell owns and a function sets as part of a builtin protocol
# (completion, getopts, read, prompts): a caller never reads them as the
# function's output. PATH is not here: a caller reads the new value.
def shell_owned_names:
  ["IFS", "RANDOM", "SECONDS", "OPTIND", "OPTARG", "OPTERR", "COMPREPLY", "REPLY", "BASH_REMATCH", "PIPESTATUS",
   "LINENO", "FUNCNAME", "EPOCHSECONDS", "PS1", "PS2", "PS3", "PS4", "PROMPT_COMMAND"];

# A function that assigns an upper-case global documents it with @set. Names
# the function, or a function around it, declares itself (local, declare) are
# not globals. The names in shell_owned_names are skipped.
def shdoc_set:
  . as $root
  | documented_functions
  | . as $fn
  | (
      [.body | declared_names]
      + [$root | nodes | select(.Type == "FuncDecl" and .Pos.Line < $fn.line and .End.Line >= $fn.line) | .Body | declared_names]
      | add
    ) as $declared
  | [.doc[] | capture("^ *@set +(?<name>[A-Za-z_][A-Za-z0-9_]*)") | .name] as $documented
  | [
      $fn.body | global_nodes
      | (
          select(.Type == "CallExpr" and (args | length) == 0) | (.Assigns // [])[]
        ),
        (
          select(.Type == "DeclClause" and declares_global) | args[] | select(has("Name") and .Value != null)
        )
      | {name: (.Name.Value // ""), line: .Pos.Line}
      | select(.name | test("^[A-Z][A-Z0-9_]*$"))
      | select(.name | IN(shell_owned_names[]) | not)
      | select(.name as $n | ($declared + $documented) | index($n) | not)
    ]
  | unique_by(.name)[]
  | {line, rule: "shdoc-set", message: ($fn.name + " assigns " + .name + " without an @set line")};

# A function whose own body writes to fd 2 (>&2, 1>&2, > /dev/stderr) says so
# with @stderr. Only a redirect whose source is fd 1 writes there: 3>&2 copies
# the descriptor and writes nothing, and a bare `exec` only rearranges
# descriptors. Calling a logger that writes to fd 2 is not the function's own
# write, and neither is the body of a nested function.
def shdoc_stderr:
  documented_functions
  | select(.doc | any(test("^ *@stderr\\b")) | not)
  | . as $fn
  | select(
      any(
        .body | own_nodes | select(has("Redirs"))
        | (((.Cmd.Args // []) | length == 1 and (.[0].Parts[0].Value // "") == "exec") | not) as $writes
        | .Redirs[]
        | $writes
          and ((.N.Value // "1") == "1")
          and (
            (.Op == ">&" and ((.Word.Parts[0].Value // "") == "2"))
            or (.Op == ">" and ((.Word.Parts[0].Value // "") == "/dev/stderr"))
          );
        .
      )
    )
  | {line: $fn.line, rule: "shdoc-stderr", message: ($fn.name + " writes to stderr without an @stderr line")};

# A comment that cites code by line number: file.sh:123. Line numbers drift
# with every edit; cite a function or a heading.
def comment_line_ref:
  comments
  | (.text | match("[A-Za-z0-9_./-]+\\.(sh|bash|bats|awk|jq|md|nix|yml|yaml|json|toml):[0-9]+") | .string) as $ref
  | {line, rule: "comment-line-ref", message: ("cite a function or heading, not a line number: " + $ref)};

# A comment that points at a file a clone does not contain. Naming the
# untracked directory itself (to say it is excluded) is fine.
def comment_untracked_ref:
  comments
  | (.text | match("\\.claude/[A-Za-z0-9_.-]+[A-Za-z0-9_./-]*|docs/superpowers/[A-Za-z0-9_.-]+[A-Za-z0-9_./-]*") | .string) as $ref
  | {line, rule: "comment-untracked-ref", message: ("this path is not tracked: " + $ref)};

# A comment that names a repo path no tracked file has. A path with a glob, a
# placeholder or an ellipsis in it is not checked, and the untracked planning
# directory is comment_untracked_ref's business. A path preceded by a slash
# belongs to a URL or another repository.
def comment_missing_path($tracked):
  comments
  | .line as $line
  | [.text | match("(?<![A-Za-z0-9_./*<{$-])(hooks|tests|bench|assets|docs|\\.ci|\\.githooks|\\.github)/[A-Za-z0-9_./*<>{}$-]*[A-Za-z0-9_*>}]"; "g") | .string]
  | unique[]
  | select(test("[*<>{}$]|\\.\\.") | not)
  | select(startswith("docs/superpowers") | not)
  | . as $ref
  | select(($tracked | index($ref)) == null)
  | select(($tracked | any(startswith($ref + "/"))) | not)
  | {line: $line, rule: "comment-missing-path", message: ("no tracked file or directory is named " + $ref)};

# A comment that names a function in a namespace some defined function uses,
# where nothing defines that name. The list covers every file in the
# repository and every file scanned, so the definition may be anywhere,
# including later in the same file. A `word::word` whose namespace no function
# uses (`std::string`, a jq module call) is not a bash function name, so it is
# not checked; a misspelt name inside a used namespace still is.
def comment_missing_function($functions):
  ($functions | map(select(contains("::")) | split("::")[0]) | unique) as $namespaces
  | comments
  | .line as $line
  | [.text | match("[a-z_][a-z0-9_]*::[a-z_][a-z0-9_]*"; "g") | .string]
  | unique[]
  | . as $ref
  | select($namespaces | index($ref | split("::")[0]))
  | select(($functions | index($ref)) == null)
  | {line: $line, rule: "comment-missing-function", message: ("no function is named " + $ref)};

# Wording that only makes sense next to the commit that added it. An issue
# reference on the same line anchors it and is allowed. `before this
# gate|change|commit` is ordinary present-tense ordering ("lint runs before
# this gate") unless a past-tense verb follows in the same sentence, which
# makes the commit the referent; the other phrases have no present-tense use.
def comment_commit_relative:
  comments
  | select(.text | test("#[0-9]+") | not)
  | (
      .text
      | match(
          "\\b(until now|when this was written|the commit before this one|as of this commit)\\b|\\bbefore this (gate|change|commit)\\b[^.]*\\b(was|were|had|did|used to|could|would)\\b";
          "i"
        )
      | .string
    ) as $phrase
  | {line, rule: "comment-commit-relative", message: ("state it in the present tense, or anchor it to an issue: \"" + $phrase + "\"")};

# Deferred work is marked TODO:, upper-case with a colon. Only a marker shape
# is a finding: an upper-case TODO, FIXME or XXX word not followed directly by
# a colon (FIXME: and XXX: included, since the form is TODO:), or a lower or
# mixed case todo: or fixme:. Prose such as "a todo item" or "xxx" as filler
# is not a marker.
def todo_form:
  comments
  | select(
      (.text | test("\\bTODO\\b(?!:)|\\b(FIXME|XXX)\\b"))
      or ([.text | match("\\b(todo|fixme):"; "gi") | .string] | any(. != "TODO:"))
    )
  | {line, rule: "todo-form", message: "mark deferred work as TODO:"};

# An executed script that calls mktemp arms an EXIT trap somewhere, so the
# temporary file or directory does not outlive it. A trap that only clears
# (`trap - EXIT`) arms nothing. A sourced file is exempt: it must not install a
# trap into its caller's shell. A dry run (--dry-run, or -u, the spelling BSD
# mktemp has) creates nothing. The command is found behind wrappers, so
# `command mktemp` and `env VAR=x mktemp` count.
def mktemp_exit_trap($sourced):
  select($sourced | not)
  | ([nodes | select(.Type == "CallExpr" and cmdname == "trap") | [args[] | (.Parts[0].Value // "")] | select(.[1] != "-" and any(. == "EXIT" or . == "0"))] | length > 0) as $armed
  | nodes
  | select(.Type == "CallExpr")
  | . as $call
  | real_words as $w
  | select(($w[0].Parts[0].Value // "") == "mktemp")
  | select([$w[1:][] | (.Parts[0].Value // "") | select(. == "--dry-run" or test("^-[A-Za-z]*u[A-Za-z]*$"))] | length == 0)
  | select($armed | not)
  | {line: $call.Pos.Line, rule: "mktemp-exit-trap", message: "arm an EXIT trap that removes what mktemp creates"};

def hits($path; $src; $sourced; $tracked; $functions; $helpers): function_keyword, no_raw_tab($src), quote_expansions, single_quote_literals, quote_literal_path, quote_subst_in_assign, unquoted_numeric_opt, no_braces_in_arith, quote_heredoc_terminator, long_options($path; $helpers), double_dash_before_paths, xargs_flags($path), no_echo_e, fetch_flags, test_double_equals, empty_string_test, no_lexical_compare, no_one_line_case, no_fallthrough, explicit_for_in, no_for_in_subst, no_pipe_while, source_not_dot, no_let_expr, no_alias, bare_arith_stmt, blank_fallback_comment, shellcheck_disable_justified, no_subst_or_exit, eval_comment, main_last($sourced), functions_grouped($sourced), strict_prologue($sourced), no_default_wellknown_env, max_line_length($src), shdoc_present, shdoc_arg_positions, shdoc_arg_name, shdoc_set, shdoc_stderr, comment_line_ref, comment_untracked_ref, comment_missing_path($tracked), comment_missing_function($functions), comment_commit_relative, todo_form, mktemp_exit_trap($sourced);

# The last line a marker attached to this node reaches. A simple command or a
# pipeline is reached whole, continuation lines included. A compound statement
# is reached through its header only, so a marker above a function, a test, a
# block or a subshell stops at the opening line, one above a `case` at the line
# of its word, one above an `if` or a loop at the line of its `then` or `do`
# (the condition is covered), and one above a case arm at the line of its
# pattern. Reaching the body as well would excuse every hit inside it.
def marker_reach:
  if has("Cmd") then
    (.Cmd.Type // "") as $type
    | if $type | IN("FuncDecl", "TestDecl", "Block", "Subshell") then .Pos.Line
      elif $type == "CaseClause" then .Cmd.Word.End.Line
      elif $type == "IfClause" then .Cmd.ThenPos.Line
      elif $type | IN("WhileClause", "ForClause") then .Cmd.DoPos.Line
      else .End.Line
      end
  elif has("Patterns") then
    (.Patterns | last | .End.Line)
  else
    .End.Line
  end;

# Every marker in every comment that starts with `bash-style`. One comment may
# hold several, each introduced by its own `# bash-style` and each with its own
# reason, so one statement can be excused from more than one rule. A marker
# well formed as `# bash-style allow=<rule-id>: <reason>` carries its rule and
# reason; any other `bash-style` text has `malformed: true`. A comment shfmt
# attached to a statement covers that statement's lines as far as marker_reach
# says; a marker alone on the line above a statement is attached to that
# statement, so the span starts at the marker. A comment attached to nothing
# (after the last statement of a file or of a block) covers only its own line.
def markers:
  ([
    .. | objects
    | select(has("Comments") and has("End"))
    | marker_reach as $to
    | .Comments[]
    | {key: (.Hash.Line | tostring), value: $to}
  ] | from_entries) as $spans
  | [
    .. | objects
    | select(has("Hash") and has("Text"))
    | select(.Text | test("^ ?bash-style\\b"))
    | .Hash.Line as $line
    | (.Text | sub("^ ?bash-style"; "") | split(" # bash-style") | if length == 0 then [""] else . end | .[])
    | ((capture("^ allow=(?<rule>[a-z0-9-]+): *(?<reason>.*)$")) // null) as $m
    | {
        line: $line,
        rule: ($m.rule // ""),
        reason: ($m.reason // ""),
        malformed: ($m == null),
        from: $line,
        to: ([($spans[$line | tostring] // $line), $line] | max)
      }
  ];

def report($path; $src; $sourced; $tracked; $functions; $helpers):
  if .Type != "File" then error("not a shfmt syntax tree") else . end
  | markers as $markers
  | [hits($path; $src; $sourced; $tracked; $functions; $helpers)] as $hits
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
