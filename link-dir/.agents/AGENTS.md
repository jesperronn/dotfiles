# Agent Instructions (Always-On)

Read this first. Keep this file short - it's loaded every session. Detail
lives in linked files; open them only when the situation actually applies.

## Memory Bank

- Per-project, not global: look for `./memory-bank/` in the current repo root.
- Missing + task non-trivial? Copy `~/.agents/templates/memory-bank/` in as
  `./memory-bank/`.
- Read `activeContext.md` + `progress.md` at task start / after a context
  reset. Update at milestones instead of restating the whole chat.
- Keep memory-bank files small; link out to separate docs for long detail.

## Gotchas index

- Terminal background jobs die unexpectedly across tool calls ->
  `~/.agents/notes/terminal-background-jobs.md`
- `git diff`/`log`/`show` can hang or garble output via the pager -> always
  use `GIT_PAGER=cat git ...` or `git --no-pager ...` ->
  `~/.agents/notes/git-pager.md`



