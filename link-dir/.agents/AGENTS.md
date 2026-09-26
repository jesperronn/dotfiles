# Agent Instructions (Always-On)

Detail lives in `~/.agents/notes/` — open a linked note only when it applies.

## Git & commits

- Conventional commits: `type(scope): subject`.
- Do not add `Co-authored-by:` trailers.
- `git diff`/`log`/`show` → always `git --no-pager …` or `GIT_PAGER= git …` to avoid hanging output → `~/.agents/notes/git-pager.md`


## Memory Bank

- Per-project memory lives in `./memory-bank/` (per-project, never global). Read `activeContext.md` + `progress.md` at task start and update them at milestones. Template: `~/.agents/templates/memory-bank/`; details: `~/.agents/notes/memory-bank.md`.

## Gotchas

- Background jobs started in one tool call die before the next → `~/.agents/notes/terminal-background-jobs.md`

