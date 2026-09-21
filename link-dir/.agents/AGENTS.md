# Agent Instructions (Always-On)

Read this first. Keep this file short - it's loaded every session. Detail
lives in linked files; open them only when the situation actually applies.

## Memory Bank

-> `~/.agents/notes/memory-bank.md`

## Gotchas index

- Terminal background jobs die unexpectedly across tool calls ->
  `~/.agents/notes/terminal-background-jobs.md`
- `git diff`/`log`/`show` can hang or garble output via the pager -> always
  use `GIT_PAGER=cat git ...` or `git --no-pager ...` ->
  `~/.agents/notes/git-pager.md`