# Probe mapping — where every scanner assertion went

`run_scanner_tests` in the pre-port `hooks/pgrep-pkill-guard.sh` (lines 2670–2949)
held **64 `assert_equals` calls**. They were not uniform: roughly half drove the
awk scanner's token stream, and the rest reached into bash internals
(`has_flag`, `pattern_operand`, `bracket_mitigation_holds`, `loop_context`,
`body_has_terminator`, `main`'s private jq decode) through probe helpers that no
subprocess-only test can call.

This table records the disposition of every one of the 64, per spec amendment
**A1**. It is the audit trail that makes "we did not silently drop assertions"
checkable. Source lines refer to the hook **as of commit `0a7c542`**, before the
embedded test code was deleted.

## Buckets

| Bucket | Count | Disposition |
| --- | --- | --- |
| Token stream | 31 | `tests/scanner.bats`, driving `printf '%s' cmd \| LC_ALL=C awk -f hooks/pgrep-scan.awk` directly |
| Bash internals (`flag_probe`, `pattern_probe`, `bracket_probe`, `context_probe`, `terminator_probe`) | 30 | Re-encoded as end-to-end rows in `tests/cases/verdicts.tsv`, consumed by `classify.bats` and `deny-sweep.bats` |
| `tsv_roundtrip_probe` | 1 | One end-to-end `@test` in `tests/scanner.bats` |
| `inactive_probe` | 2 | `tests/scanner.bats`, PATH stub dir rebuilt in bats |
| **Total** | **64** | |

## Discriminating power

An end-to-end re-encoding is **discriminating** when breaking the property the
original probe asserted changes the hook's JSON verdict, so the row fails. It is
a **pin** when the property is real at the function level but two or more
distinct internal answers collapse to the same JSON output; the row still locks
the observable behaviour of that exact command shape, but it would not catch a
regression confined to the internal function. Pins are called out explicitly
below — that granularity loss is the cost A1 accepted.

## Token-stream assertions → `tests/scanner.bats`

| # | Hook line | Original label | Landed in |
| --- | --- | --- | --- |
| 1 | 2673 | quoted mention yields no pgrep token | `scanner: a quoted mention yields no pgrep token` |
| 2 | 2677 | bare pgrep is tokenized | `scanner: a bare pgrep is tokenized` |
| 3 | 2682 | command substitution inside double quotes is visible | `scanner: a command substitution inside double quotes is visible` |
| 4 | 2687 | newline survives as a literal token | `scanner: a newline survives as a literal token` |
| 5 | 2694 | line continuation separates the words it joins | `scanner: a line continuation separates the words it joins` |
| 6 | 2790 | quoted heredoc body is masked | `scanner: a quoted heredoc body is masked` |
| 7 | 2796 | heredoc body marker carries the body offset and length | `scanner: a heredoc body marker carries the body offset and length` |
| 8 | 2802 | command substitution inside an unquoted heredoc body is visible | `scanner: a command substitution inside an unquoted heredoc body is visible` |
| 9 | 2806 | plain text in an unquoted heredoc body is masked | `scanner: plain text in an unquoted heredoc body is masked` |
| 10 | 2811 | a double-quoted delimiter masks the body | `scanner: a double-quoted delimiter masks the body` |
| 11 | 2817 | a line merely starting with the delimiter is not a terminator | `scanner: a line merely starting with the delimiter is not a terminator` |
| 12 | 2824 | a body at end of input still emits a zero-length marker | `scanner: a body at end of input still emits a zero-length marker` |
| 13 | 2831 | a quoted empty delimiter ends its body at a blank line | `scanner: a quoted empty delimiter ends its body at a blank line` (skipped under paragraph-mode awk) |
| 14 | 2834 | a quoted empty delimiter masks its body until that blank line | `scanner: a quoted empty delimiter masks its body until that blank line` (skipped under paragraph-mode awk) |
| 15 | 2841 | an unterminated quote ends the delimiter word at the newline | `scanner: an unterminated quote ends the delimiter word at the newline` |
| 16 | 2845 | backslash-escaped delimiter is a quoted delimiter | `scanner: a backslash-escaped delimiter is a quoted delimiter` |
| 17 | 2850 | tab-indented terminator closes a `<<-` body | `scanner: a tab-indented terminator closes a <<- body` |
| 18 | 2853 | code after a `<<-` body is tokenized | `scanner: code after a <<- body is tokenized` |
| 19 | 2858 | two heredocs on one line yield two bodies | `scanner: two heredocs on one line yield two bodies` |
| 20 | 2861 | the first of two bodies is masked | `scanner: the first of two bodies is masked` |
| 21 | 2864 | the second of two bodies is masked | `scanner: the second of two bodies is masked` |
| 22 | 2867 | code after two bodies is tokenized | `scanner: code after two bodies is tokenized` |
| 23 | 2872 | a quoted `<<` is not a heredoc | `scanner: a quoted << is not a heredoc` |
| 24 | 2875 | a here-string is not a heredoc | `scanner: a here-string is not a heredoc` |
| 25 | 2879 | a shift inside arithmetic is not a heredoc | `scanner: a shift inside arithmetic is not a heredoc` |
| 26 | 2887 | an arithmetic shift leaves no `<<` token to count | `scanner: an arithmetic shift leaves no << token to count` |
| 27 | 2893 | unterminated heredoc masks to end of input | `scanner: an unterminated heredoc masks to end of input` |
| 28 | 2898 | heredoc inside a command substitution is masked | `scanner: a heredoc inside a command substitution is masked` |
| 29 | 2909 | a body line ending in a backslash does not swallow the terminator | `scanner: a body line ending in a backslash does not swallow the terminator` |
| 30 | 2916 | a parenthesised shift inside arithmetic is not a heredoc | `scanner: a parenthesised shift inside arithmetic is not a heredoc` |
| 31 | 2919 | a shift inside an arithmetic command is not a heredoc | `scanner: a shift inside an arithmetic command is not a heredoc` |

Every one of these greps for a token anchored on a literal tab
(`grep -c "$(tab)pkill\$"`) rather than `\b`, because `\b` is a GNU extension and
the compat CI legs run BSD grep.

Assertion 8 asserts that the pkill inside `$( )` in an **unquoted** heredoc body
**is** seen (offset 12) — re-entering code context means the invocation is
visible. The masking case is the **quoted** delimiter, assertion 6.

## `flag_probe` → `has_flag` (5) → `tests/cases/verdicts.tsv`

The end-to-end lever is that `classify_command` `continue`s past any invocation
without `--full`, and that `--ignore-ancestors` clears a kill.

| # | Hook line | Original label | Appended verdict row | Verdict | Kind |
| --- | --- | --- | --- | --- | --- |
| 32 | 2707 | long full flag | `until ! pgrep --full zzflagfull; do sleep 5; done` | `deny:loop` | discriminating (vs #34) |
| 33 | 2709 | short cluster `-af` is full | `until ! pgrep -af zzflagcluster; do sleep 5; done` | `deny:loop` | discriminating |
| 34 | 2711 | plain `-a` is not full | `until ! pgrep -a zzflagnotfull; do sleep 5; done` | `allow` | discriminating |
| 35 | 2713 | long ignore-ancestors | `pkill --ignore-ancestors --full zzflaglongia` | `allow` | discriminating (vs the existing `pkill --full java` deny rows) |
| 36 | 2716 | short `-A` | `pkill -Af zzflagshortia` | `allow` | discriminating |

## `pattern_probe` → `pattern_operand` (6) → `tests/cases/verdicts.tsv`

The end-to-end lever is `bracket_mitigation_holds`, the only consumer of the
operand: a correctly extracted `[x]`-class operand clears a `pkill` to `allow`,
while any wrong slice leaves the mitigation unproven and the command denies.

| # | Hook line | Original label | Appended verdict row | Verdict | Kind |
| --- | --- | --- | --- | --- | --- |
| 37 | 2703 | line continuation keeps later byte offsets aligned | a `pkill --full` whose `"[u]nittest discover"` operand sits on the next line, after a backslash line continuation | `allow` | discriminating — a one-byte offset shift slices a different operand and denies |
| 38 | 2718 | operand is last non-flag arg | `pkill --full "[z]zoperandlast discover"` | `allow` | discriminating |
| 39 | 2720 | operand skips a flag value | `pkill --full "[z]zoperandskip" --delimiter ,` | `allow` | discriminating — the value option is placed **last** on purpose; with the original's `--delimiter , java` ordering the trailing operand wins either way and the skip is untested |
| 40 | 2722 | operand ignores a redirection target | `pkill --full "[z]zoperandredir" > /tmp/out` | `allow` | discriminating — `>` is not an operator, so the target really is inside `invocation_args` |
| 41 | 2724 | operand after `--` is not swallowed as a flag | `pkill --full -- "-[z]zoperandterm"` | `allow` | discriminating — the operand starts with a dash, so only the past-terminator arm can pick it |
| 42 | 2902 | byte offsets stay aligned across a heredoc body | `cat <<'EOF'`…`EOF`<newline>`pkill --full "[a] b"` | `allow` | discriminating |

## `bracket_probe` → `bracket_mitigation_holds` (7) → `tests/cases/verdicts.tsv`

| # | Hook line | Original label | Verdict row | Verdict | Kind |
| --- | --- | --- | --- | --- | --- |
| 43 | 2727 | bracket alone holds | `pkill --full "[z]zbracketalone"` (appended) | `allow` | discriminating |
| 44 | 2729 | bracket voided by a bare copy | `echo "unittest discover"; pkill --full "[u]nittest discover"` (appended) | `deny:kill` | discriminating |
| 45 | 2732 | no bracket, no mitigation | `pkill --full "unittest discover"` — **already row 15** of `verdicts.tsv`; not duplicated | `deny:kill` | discriminating |
| 46 | 2734 | bracket later in the pattern holds | `pkill --full "probe[.]py"` (appended) | `allow` | discriminating |
| 47 | 2737 | multi-char class is not the idiom | `pkill --full "[abc]needle[d]"` (appended) | `deny:kill` | discriminating |
| 48 | 2739 | single then multi-char class | `pkill --full "[d]needle[abc]"` (appended) | `deny:kill` | discriminating |
| 49 | 2742 | stray class opener is unreconstructable | `pkill --full "abc[def[g]hij"` (appended) | `deny:kill` | discriminating |

## `context_probe` → `loop_context` (9) → `tests/cases/verdicts.tsv`

The end-to-end lever is the `case "${context}"` switch in `classify_command`:
`cond` denies outright, `body` denies when the result is consumed **and** the
body carries a terminator, and `none` can only ever reach `warn`.

| # | Hook line | Original label | Appended verdict row | Verdict | Kind |
| --- | --- | --- | --- | --- | --- |
| 50 | 2745 | condition span | `until ! pgrep --full zzctxcond; do sleep 5; done` | `deny:loop` | discriminating — any non-`cond` answer gives `warn` |
| 51 | 2747 | body span | `while true; do pgrep --full zzctxbody \|\| break; sleep 5; done` | `deny:loop` | discriminating — `none` gives `warn` |
| 52 | 2750 | outside every loop | `while read -r line; do :; done < f; pgrep -af zzctxnone` | `allow` | **pin** — see "Pins", below |
| 53 | 2754 | for head is not a condition | `for f in $(pgrep --full zzctxforhead); do :; done` | `warn` | discriminating — a `cond` answer would deny |
| 54 | 2756 | nested loop attributes to inner body | `while true; do for f in *; do pgrep --full zzctxnested \|\| break; done; done` | `deny:loop` | discriminating for `body` vs `none`; **pin** for inner-vs-outer body |
| 55 | 2759 | `done` as an argument does not close a span | `while true; do echo done; pgrep --full zzctxdonearg \|\| break; done` | `deny:loop` | discriminating — a popped span gives `warn` |
| 56 | 2765 | a case pattern does not close the enclosing body span | `while true; do case x in y) :; esac; pgrep --full zzctxcase \|\| break; done` | `deny:loop` | discriminating — a popped span gives `warn` |
| 57 | 2769 | a subshell close still pops | `while true; do (echo hi); pgrep --full zzctxsubshell \|\| break; done` | `deny:loop` | **pin** — see "Pins", below |
| 58 | 2777 | a `done` inside a substitution cannot pop the enclosing body span | `while true; do echo "$(: ; done)"; pgrep --full zzctxsubdone \|\| break; sleep 5; done` | `warn` | **pin; discriminating power DROPPED** — see "Pins", below |

## `terminator_probe` → `body_has_terminator` (3) → `tests/cases/verdicts.tsv`

| # | Hook line | Original label | Appended verdict row | Verdict | Kind |
| --- | --- | --- | --- | --- | --- |
| 59 | 2780 | body terminator found | `while true; do pgrep --full zztermyes \|\| break; done` | `deny:loop` | discriminating (vs #60) |
| 60 | 2782 | no terminator in body | `while true; do pgrep --full zztermno \|\| sleep 5; done` | `warn` | discriminating — the original's `pgrep --full x; sleep 5` is not result-consuming, so it cannot separate "no terminator" from "no consumption"; `\|\| sleep 5` isolates the terminator |
| 61 | 2784 | terminator in an outer body only | `while true; do for f in *; do pgrep --full zztermouter \|\| sleep 5; done; break; done` | `warn` | discriminating — reading the outer `break` would deny |

## `inactive_probe` (2) → `tests/scanner.bats`

| # | Hook line | Original label | Landed in |
| --- | --- | --- | --- |
| 62 | 2936 | missing awk announces the guard inactive | `scanner: a missing awk announces the guard inactive` |
| 63 | 2939 | missing scanner announces the guard inactive | `scanner: a missing scanner announces the guard inactive` |

Ported as-is: a throwaway hook copy plus a stub PATH holding only `bash`, `jq`,
`dirname` and `cat`, and the child run under `env -i` so an inherited `BASH_ENV`
cannot re-source the user's profile and restore the removed binary. Per spec
amendment A12 the copy is now invoked **directly**, matching the `hooks.json`
contract, rather than as `bash <script>`. `mktemp --directory`, `ln --symbolic`
and `env --ignore-environment` became `BATS_TEST_TMPDIR`, `ln -s` and `env -i`
per amendment A11.

## `tsv_roundtrip_probe` (1) → `tests/scanner.bats`

| # | Hook line | Original label | Landed in |
| --- | --- | --- | --- |
| 64 | 2943 | tsv round-trip preserves a literal tab and newline | `scanner: a command with literal tabs and newlines survives the tsv decode` |

Re-encoded end to end rather than as a decode probe: the command
`echo<tab>one<newline>pkill --full java` must still deny. If the `@tsv` /
`printf %b` round-trip breaks, the embedded newline splits the record, the
`pkill` is no longer in command position, and the verdict flips to `allow`.

## Pins — assertions whose discriminating power did not survive

Three rows are pins rather than discriminators. All three were checked against
the real code rather than assumed.

- **#52 (2750), "outside every loop".** `while read -r line; do :; done < f; pgrep -af zzctxnone`.
  The plausible failure here is the trailing `done` failing to pop, which yields
  `body`, not `cond`. `body` only denies when the result is consumed **and** the
  body has a terminator; this invocation is neither. `none` and `body` therefore
  produce the same `allow`. The row still pins that verdict.
- **#57 (2769), "a subshell close still pops".** In `loop_context` the context
  lookup walks **down** the stack past barrier markers, so a `subshell` marker
  left un-popped on top of the enclosing `body` is skipped and the answer is
  `body` either way. There is no command shape where the missing pop changes the
  JSON verdict.
- **#58 (2777), "a `done` inside a substitution cannot pop the enclosing body
  span".** This is the one assertion whose discriminating power is genuinely
  **dropped**. Removing `loop_context`'s scope barrier turns `body` into `none`,
  and `body` denies only when `body_has_terminator` also agrees — but
  `body_has_terminator` has **no** scope barrier of its own, so the same stray
  `done` decrements its depth counter to zero and it reports "no terminator"
  regardless. `body`-without-terminator and `none` both fall through to the
  `result_is_consumed` arm and both emit `warn`. The two internal answers are
  indistinguishable through the JSON contract for every command shape tried,
  including nested-loop variants that restore `body_has_terminator`'s depth —
  those restore `loop_context`'s `body` answer too, via the inner `do`.

  `body_has_terminator`'s missing barrier is an asymmetry with `loop_context`,
  not something this port introduced. Phase 3 must not change hook behaviour, so
  it is left alone and recorded here.
  Filed as issue #8 under the pin-then-fix policy: giving
  `body_has_terminator` the same substitution scope barrier `loop_context`
  already has would restore assertion #58's discriminating power.

## Nothing else was dropped

61 of the 64 assertions are re-encoded with their discriminating power intact.
Two (#52, #57) are pins for reasons intrinsic to the hook's own control flow.
One (#58) loses its discriminating power for the reason above. **No assertion
was removed without a row or a test.**
