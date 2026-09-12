# Git commands hang or produce garbled tool output

## Symptom

Running `git diff`, `git log`, `git show`, etc. inside an agent's terminal
tool can hang waiting for pager input, or interleave escape codes / partial
pages into the captured output - especially when the terminal isn't a real
TTY (common for tool-invoked shells).

## Cause

Git defaults to piping diff/log/show output through a pager (`less` by
default, or whatever `core.pager` / `$PAGER` / `$GIT_PAGER` resolves to).
Non-interactive/tool shells often still get a pager invoked, which then
waits for input that never comes, or writes control sequences that corrupt
captured output.

## Fix

Always disable the pager before running git commands that might page,
either per-invocation or for the whole session:

```bash
# Per-command (safest, no lingering env state):
GIT_PAGER=cat git diff
GIT_PAGER=cat git log --oneline -20
GIT_PAGER=cat git show HEAD

# Or export once at the start of a session:
export GIT_PAGER=cat
```

`--no-pager` also works and is arguably clearer intent:

```bash
git --no-pager diff
git --no-pager log --oneline -20
```

## Rule of thumb

Before running any `git diff`, `git log`, `git show`, `git blame`, or similar
potentially-paged command in an agent terminal, prefix it with `GIT_PAGER=cat`
(or use `git --no-pager <cmd>`). Do this by default, don't wait for it to hang first.

