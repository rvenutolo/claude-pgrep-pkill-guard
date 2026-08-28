# Why

<!--
What problem does this solve, and why this way? If it changes a verdict or a
reason text, say what an agent will see differently after the change. Link the
issue this closes.
-->

## Checklist

- [ ] `just check` is green locally
- [ ] If a verdict changed, `tests/cases/verdicts.tsv` has the row (and `tests/cases/messages.tsv` if the reason text changed)
- [ ] The commit subject follows the conventional format (`type: subject`)
- [ ] No test uses a real destructive command as payload
